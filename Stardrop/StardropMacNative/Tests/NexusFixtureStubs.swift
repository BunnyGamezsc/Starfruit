// Test-only collaborators. Production NexusClient and models are compiled unchanged.
// Credentials never touch Keychain; CollectionRevisionMetadata mirrors the backend contract.
import Foundation
struct CollectionRevisionMetadata: Codable {
    var slug: String; var revisionNumber: Int; var name: String
    var summary: String?; var curator: String?; var downloadLink: URL
}
struct KeychainHelper {
    static func load() -> String? { nil }
    static func save(_ value: String) {}
    static func delete() {}
}
