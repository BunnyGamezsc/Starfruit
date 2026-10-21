import Foundation

// Offline fixtures run with the suite; --live additionally checks public Nexus search.
private let matchingMods = Data(#"{"data":{"mods":{"nodes":[{"name":"Bigger Backpack","mod_id":1845,"game_id":1303,"author":"spacechase0","downloads":123456,"endorsements":1200}]}}}"#.utf8)

final class SearchFixtureState: @unchecked Sendable {
    private let lock = NSLock()
    private var code = 200
    private var data = matchingMods
    private var hold = false
    private var requests: [URLRequest] = []

    func configure(code: Int = 200, data: Data = matchingMods, hold: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        self.code = code
        self.data = data
        self.hold = hold
    }

    func receive(_ request: URLRequest) -> (Int, Data, Bool) {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        return (code, data, hold)
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }

    var lastRequest: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return requests.last
    }
}

final class SearchFixtureProtocol: URLProtocol {
    static let state = SearchFixtureState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        // The old host no longer resolves (also reproduced in the browser).
        guard request.url?.host == "api.nexusmods.com" else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let (code, data, hold) = Self.state.receive(request)
        guard !hold else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct SearchRegression {
    @MainActor static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            guard Date() < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    @MainActor static func main() async {
        do {
            if CommandLine.arguments.contains("--live") {
                for (query, expected) in [("Bigger Backpacks", "Bigger Backpack"), ("SMAPI", "SMAPI"), ("Content Patcher", "Content Patcher")] {
                    let results = try await NexusModSearchClient().search(query)
                    precondition(results.contains { $0.name.localizedCaseInsensitiveContains(expected) }, "Live search did not return \(expected)")
                    precondition(results.allSatisfy { $0.game_id == 1303 }, "Search escaped Stardew Valley")
                    print("PASS: live public search for '\(query)' (\(results.count) results, no API key)")
                }
                return
            }
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [SearchFixtureProtocol.self]
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            let client = NexusModSearchClient(session: session)
            let state = SearchFixtureProtocol.state
            let results = try await client.search(" \nBigger Backpacks\t ")
            precondition(results.first?.name == "Bigger Backpack")
            precondition(results.first?.pageURL.absoluteString == "https://www.nexusmods.com/stardewvalley/mods/1845")
            let request = state.lastRequest!
            precondition(request.httpMethod == "POST" && request.url?.path == "/v2/graphql")
            precondition(request.value(forHTTPHeaderField: "apiKey") == nil, "Search must work without a key")
            precondition(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            var body = request.httpBody
            if body == nil, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 4096)
                var value = Data()
                while stream.hasBytesAvailable {
                    let count = stream.read(&bytes, maxLength: bytes.count)
                    guard count > 0 else { break }
                    value.append(contentsOf: bytes.prefix(count))
                }
                body = value
            }
            let json = try JSONSerialization.jsonObject(with: body!) as! [String: Any]
            let variables = json["variables"] as! [String: Any]
            let filter = variables["filter"] as! [String: Any]
            let names = filter["nameStemmed"] as! [[String: String]]
            precondition(names == [["value": "Bigger Backpacks", "op": "MATCHES"]])
            precondition((filter["gameId"] as! [[String: String]]).first?["value"] == "1303")
            precondition((filter["adultContent"] as! [[String: Any]]).first?["value"] as? Bool == false)
            let count = state.count
            let empty = try await client.search(" \n\t ")
            precondition(empty.isEmpty && state.count == count, "Blank searches must not use the network")

            state.configure(data: Data(#"{"data":{"mods":{"nodes":[]}}}"#.utf8))
            let noMatches = try await client.search("not-a-mod")
            precondition(noMatches.isEmpty)
            state.configure(code: 429)
            do { _ = try await client.search("SMAPI"); preconditionFailure("HTTP error ignored") }
            catch NexusSearchError.http(let code) { precondition(code == 429) }
            state.configure(data: Data(#"{"data":{"mods":null},"errors":[{"message":"Search unavailable"}]}"#.utf8))
            do { _ = try await client.search("SMAPI"); preconditionFailure("GraphQL error ignored") }
            catch NexusSearchError.graphQL(let message) { precondition(message == "Search unavailable") }
            state.configure(data: Data(#"{"data":{}}"#.utf8))
            do { _ = try await client.search("SMAPI"); preconditionFailure("Missing data treated as no matches") }
            catch NexusSearchError.invalidResponse {}
            state.configure(data: Data("not JSON".utf8))
            do { _ = try await client.search("SMAPI"); preconditionFailure("Malformed data accepted") }
            catch is DecodingError {}

            let model = NexusModSearchModel(client: client)
            state.configure(hold: true)
            model.query = "old request"
            let previousCount = state.count
            model.submit()
            try await waitUntil { state.count > previousCount }
            precondition(model.isSearching)
            model.query = "Bigger Backpacks"
            precondition(!model.isSearching && !model.hasSearched && model.results.isEmpty)
            state.configure()
            model.submit()
            try await waitUntil { !model.isSearching }
            precondition(model.results.first?.name == "Bigger Backpack" && model.hasSearched && model.error == nil)
            model.query = ""
            precondition(model.results.isEmpty && model.error == nil && !model.hasSearched)

            state.configure(hold: true)
            model.query = "pending"
            let pendingCount = state.count
            model.submit()
            try await waitUntil { state.count > pendingCount }
            model.query = ""
            // Give the cancelled request's completion a chance to report its error.
            for _ in 0..<20 { await Task.yield() }
            precondition(!model.isSearching && !model.hasSearched && model.error == nil && model.results.isEmpty)
            state.configure(code: 503)
            model.query = "SMAPI"
            model.submit()
            try await waitUntil { !model.isSearching }
            precondition(model.hasSearched && model.error?.contains("503") == true)
            model.query = "new search"
            precondition(model.error == nil && !model.hasSearched)
            state.configure()
            model.submit()
            model.cancel()
            for _ in 0..<20 { await Task.yield() }
            precondition(!model.isSearching && !model.hasSearched && model.error == nil)
            print("PASS: public GraphQL request, Stardew/name/adult filters, result links, blank/no matches, HTTP/GraphQL/malformed errors, replacement/clear/cancel state")
        } catch {
            print("FAIL: Downloads search: \(error.localizedDescription)")
            exit(1)
        }
    }
}
