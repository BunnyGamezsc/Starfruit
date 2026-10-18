import Foundation

final class FixtureProtocol: URLProtocol {
    static var responder: (URLRequest) -> (Int, Data) = { _ in (500, Data()) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (code, data) = Self.responder(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct NexusChecks {
    @MainActor static func main() async throws {
        let suiteName = "starfruit-test-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suiteName)!
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        preferences.set("fixture-legacy-key", forKey: "nexus-api-key-fallback")
        let client = NexusClient(session: URLSession(configuration: config), preferences: preferences)
        precondition(preferences.string(forKey: "nexus-api-key-fallback") == "fixture-legacy-key", "temporary Keychain failure must not destroy the only older credential")
        FixtureProtocol.responder = { request in
            precondition(request.value(forHTTPHeaderField: "apiKey") == "fixture-key")
            return (200, Data(#"{"name":"Fixture","is_premium":true}"#.utf8))
        }
        let validated = await client.validate(key: "fixture-key")
        precondition(validated)
        FixtureProtocol.responder = { _ in (200, Data(#"{"v1.9.0":["old"],"1.10.0":["new"]}"#.utf8)) }
        let changes = try await client.fetchChangelogs(modID: 1)
        precondition(changes.map(\.version) == ["1.10.0", "v1.9.0"])
        FixtureProtocol.responder = { request in
            return (200, Data(#"{"data":{"collectionRevision":{"revisionNumber":"7","downloadLink":"https://api.nexusmods.com/download.json","collection":{"name":"Test","summary":"Summary","user":{"name":"Curator"}}}}}"#.utf8))
        }
        let metadata = try await client.fetchCollectionRevision(slug: "abc123")
        precondition(metadata.revisionNumber == 7 && metadata.curator == "Curator")
        FixtureProtocol.responder = { _ in (200, Data(#"{"download_links":[{"URI":"https://cdn.example.test/collection.7z"}]}"#.utf8)) }
        let mirror = try await client.resolveCollectionArchiveLink(metadata.downloadLink)
        precondition(mirror.host == "cdn.example.test")
        do {
            _ = try await client.resolveCollectionArchiveLink(URL(string: "https://attacker.invalid/api")!)
            fatalError("Untrusted credential destination accepted")
        } catch NexusAPIError.untrustedLink {}
        FixtureProtocol.responder = { _ in (403, Data("premium needed".utf8)) }
        do { _ = try await client.fetchChangelogs(modID: 1); fatalError("HTTP failure accepted") }
        catch NexusAPIError.http(let code, _) { precondition(code == 403) }
        FixtureProtocol.responder = { _ in (200, Data(#"{"errors":[{"message":"missing revision"}]}"#.utf8)) }
        do { _ = try await client.fetchCollectionRevision(slug: "abc123"); fatalError("GraphQL failure accepted") }
        catch NexusAPIError.graphQL(let message) { precondition(message == "missing revision") }
        client.logout()
        precondition(preferences.object(forKey: "nexus-api-key-fallback") == nil, "explicit logout clears the old fallback")
        print("PASS: changelog numeric ordering, latest/string revision, mirror resolution, credential URL boundary, HTTP/GraphQL failures")
    }
}
