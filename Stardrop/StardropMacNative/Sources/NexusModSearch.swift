import Foundation
import Combine

struct NexusSearchResult: Decodable, Identifiable {
    var id: Int { mod_id }
    let name: String
    let mod_id: Int
    let game_id: Int?
    let author: String?
    let downloads: Int?
    let endorsements: Int?
    let summary: String?

    var pageURL: URL {
        URL(string: "https://www.nexusmods.com/stardewvalley/mods/\(mod_id)")!
    }
}

enum NexusSearchError: LocalizedError {
    case http(Int)
    case graphQL(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .http(429): return "Nexus Mods is receiving too many requests. Please try again shortly."
        case .http(let status): return "Nexus Mods search returned HTTP \(status). Please try again later."
        case .graphQL(let message): return message
        case .invalidResponse: return "Nexus Mods returned an invalid search response."
        }
    }
}

struct NexusModSearchClient {
    var session: URLSession = .shared

    func search(_ text: String) async throws -> [NexusSearchResult] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        // Public GraphQL search replaces the unreachable search.nexusmods.com host.
        // Aliases keep the result fields used by the Downloads rows stable.
        let query = """
        query SearchStardewMods($filter: ModsFilter!) {
            mods(filter: $filter, count: 50, sort: [{downloads: {direction: DESC}}]) {
                nodes {
                    name mod_id: modId game_id: gameId author downloads endorsements summary
                }
            }
        }
        """
        // Stemmed matching also finds "Bigger Backpack" for "Bigger Backpacks".
        let filter: [String: Any] = [
            "gameId": [["value": "1303", "op": "EQUALS"]],
            "nameStemmed": [["value": text, "op": "MATCHES"]],
            "adultContent": [["value": false, "op": "EQUALS"]]
        ]
        var request = URLRequest(url: URL(string: "https://api.nexusmods.com/v2/graphql")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Starfruit", forHTTPHeaderField: "Application-Name")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": query, "variables": ["filter": filter]
        ])
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw NexusSearchError.invalidResponse }
        guard (200...299).contains(response.statusCode) else { throw NexusSearchError.http(response.statusCode) }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        if let errors = decoded.errors, !errors.isEmpty {
            throw NexusSearchError.graphQL(errors.map(\.message).joined(separator: "; "))
        }
        guard let nodes = decoded.data?.mods?.nodes else { throw NexusSearchError.invalidResponse }
        return nodes
    }

    private struct Response: Decodable {
        struct Payload: Decodable {
            struct Mods: Decodable { let nodes: [NexusSearchResult] }
            let mods: Mods?
        }
        struct Failure: Decodable { let message: String }
        let data: Payload?
        let errors: [Failure]?
    }
}

@MainActor
final class NexusModSearchModel: ObservableObject {
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            cancel()
            results = []
            error = nil
            hasSearched = false
        }
    }
    @Published private(set) var results: [NexusSearchResult] = []
    @Published private(set) var isSearching = false
    @Published private(set) var error: String?
    @Published private(set) var hasSearched = false

    private let client: NexusModSearchClient
    private var task: Task<Void, Never>?
    private var generation = 0

    init(client: NexusModSearchClient = NexusModSearchClient()) {
        self.client = client
    }

    func submit() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        cancel()
        let generation = generation
        let client = client
        results = []
        error = nil
        hasSearched = false
        isSearching = true
        task = Task { [weak self] in
            do {
                let results = try await client.search(text)
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                self.results = results
                self.finish()
            } catch {
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                self.error = "Search failed: \(error.localizedDescription)"
                self.finish()
            }
        }
    }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        isSearching = false
    }

    private func finish() {
        hasSearched = true
        isSearching = false
        task = nil
    }
}
