import Foundation

struct NexusChangelog: Identifiable, Equatable {
    let version: String
    let entries: [String]
    var id: String { version }
}

enum NexusAPIError: LocalizedError {
    case notAuthenticated
    case invalidResponse
    case http(Int, String)
    case graphQL(String)
    case invalidCollection
    case untrustedLink

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Connect your Nexus Mods account first."
        case .invalidResponse: return "Nexus Mods returned an invalid response."
        case .http(let code, let detail):
            return "Nexus Mods returned HTTP \(code)" + (detail.isEmpty ? "." : ": \(detail)")
        case .graphQL(let message): return message
        case .invalidCollection: return "Nexus Mods did not return a valid collection revision."
        case .untrustedLink: return "Nexus Mods returned an unexpected download service URL."
        }
    }
}
