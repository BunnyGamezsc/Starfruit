import Foundation
import Combine

struct NexusUserResponse: Codable {
    let name: String
    let is_premium: Bool
}

struct NexusModDetails: Codable {
    let mod_id: Int
    let name: String
    let summary: String?
    let version: String
    let author: String
    let picture_url: String?
}

struct NexusFile: Codable {
    let file_id: Int
    let name: String
    let version: String
    let category_name: String
}

struct NexusFilesResponse: Codable {
    let files: [NexusFile]
}

@MainActor
class NexusClient: ObservableObject {
    private let baseURL = URL(string: "https://api.nexusmods.com/v1/")!
    private var apiKey: String?
    private let session: URLSession
    private let preferences: UserDefaults
    private var authenticationGeneration = 0

    var hasApiKey: Bool {
        return apiKey != nil && !apiKey!.isEmpty
    }

    func getApiKey() -> String? {
        return apiKey
    }

    @Published var currentUser: NexusUserResponse?
    @Published var isValidating = false

    init(session: URLSession = .shared, preferences: UserDefaults = .standard) {
        self.session = session
        self.preferences = preferences
        self.apiKey = KeychainHelper.load()
        // Do not destroy the only older credential while Keychain migration is
        // temporarily blocked. It is removed once a secure copy is available.
        if self.apiKey != nil { preferences.removeObject(forKey: "nexus-api-key-fallback") }
        if hasApiKey, let data = preferences.data(forKey: "nexusCurrentUser"),
           let user = try? JSONDecoder().decode(NexusUserResponse.self, from: data) {
            self.currentUser = user
        }

        if let key = self.apiKey {
            Task {
                _ = await validate(key: key)
            }
        }
    }

    func validate(key: String) async -> Bool {
        authenticationGeneration += 1
        let generation = authenticationGeneration
        var request = URLRequest(url: baseURL.appendingPathComponent("users/validate.json"))
        request.addValue(key, forHTTPHeaderField: "apiKey")

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                if generation == authenticationGeneration, self.apiKey == key,
                   let code = (response as? HTTPURLResponse)?.statusCode, code == 401 || code == 403 {
                    self.currentUser = nil
                    preferences.removeObject(forKey: "nexusCurrentUser")
                }
                return false
            }

            let user = try JSONDecoder().decode(NexusUserResponse.self, from: data)
            guard generation == authenticationGeneration else { return false }
            self.currentUser = user
            self.apiKey = key
            KeychainHelper.save(key)
            if let encoded = try? JSONEncoder().encode(user) {
                preferences.set(encoded, forKey: "nexusCurrentUser")
            }
            return true
        } catch {
            print("Nexus validation error: \(error)")
            return false
        }
    }

    func fetchModDetails(modID: Int) async -> NexusModDetails? {
        guard let key = apiKey else { return nil }
        var request = URLRequest(url: baseURL.appendingPathComponent("games/stardewvalley/mods/\(modID).json"))
        request.addValue(key, forHTTPHeaderField: "apiKey")

        do {
            let (data, _) = try await session.data(for: request)
            return try JSONDecoder().decode(NexusModDetails.self, from: data)
        } catch {
            print("Error fetching mod details: \(error)")
            return nil
        }
    }

    func checkForUpdates(modID: Int, currentVersion: String) async -> Bool {
        guard let key = apiKey else { return false }

        if let details = await fetchModDetails(modID: modID) {
            return normalizedVersion(details.version) != normalizedVersion(currentVersion)
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("games/stardewvalley/mods/\(modID)/files.json"))
        request.addValue(key, forHTTPHeaderField: "apiKey")

        do {
            let (data, _) = try await session.data(for: request)
            let response = try JSONDecoder().decode(NexusFilesResponse.self, from: data)

            // Find main files and compare versions
            if let latestMainFile = response.files.first(where: { $0.category_name == "MAIN" }) {
                return latestMainFile.version != currentVersion
            }
            return false
        } catch {
            print("Error checking for updates: \(error)")
            return false
        }
    }

    private func normalizedVersion(_ version: String) -> String {
        let trimmed = version
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
    }

    func getFileDownloadLink(modID: Int, fileID: Int, nxmKey: String? = nil, nxmExpires: String? = nil) async -> (URL?, String?) {
        guard let key = apiKey else { return (nil, "No API key found") }

        let path = "games/stardewvalley/mods/\(modID)/files/\(fileID)/download_link.json"
        var url = baseURL.appendingPathComponent(path)

        var queryItems: [URLQueryItem] = []
        if let nxmKey = nxmKey {
            queryItems.append(URLQueryItem(name: "key", value: nxmKey))
        }
        if let nxmExpires = nxmExpires {
            queryItems.append(URLQueryItem(name: "expires", value: nxmExpires))
        }

        if !queryItems.isEmpty {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.queryItems = queryItems
            if let resolvedURL = components?.url {
                url = resolvedURL
            }
        }

        var request = URLRequest(url: url)
        request.addValue(key, forHTTPHeaderField: "apiKey")

        do {
            let (data, response) = try await session.data(for: request)
            let httpResponse = response as? HTTPURLResponse
            let statusCode = httpResponse?.statusCode ?? 0

            if statusCode != 200 {
                let body = String(data: data, encoding: .utf8) ?? "No body"
                return (nil, "HTTP \(statusCode): \(body)")
            }

            struct DownloadLink: Codable { let URI: String }
            let links = try JSONDecoder().decode([DownloadLink].self, from: data)
            guard let firstURI = links.first?.URI, let finalURL = URL(string: firstURI) else {
                return (nil, "Empty or invalid download links array")
            }
            return (finalURL, nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    /// Returns versioned Nexus changelogs, newest version first.
    func fetchChangelogs(modID: Int) async throws -> [NexusChangelog] {
        guard modID > 0 else { throw NexusAPIError.invalidResponse }
        let request = try authenticatedRequest(url: baseURL.appendingPathComponent("games/stardewvalley/mods/\(modID)/changelogs.json"))
        let data = try await checkedData(for: request)
        let entries = try JSONDecoder().decode([String: [String]].self, from: data)
        return entries.map { NexusChangelog(version: $0.key, entries: $0.value) }
            .sorted {
                let left = $0.version.lowercased().hasPrefix("v") ? String($0.version.dropFirst()) : $0.version
                let right = $1.version.lowercased().hasPrefix("v") ? String($1.version.dropFirst()) : $1.version
                let order = left.compare(right, options: [.numeric, .caseInsensitive])
                return order == .orderedSame ? $0.version > $1.version : order == .orderedDescending
            }
    }

    func fetchCollectionRevision(slug: String, revision: Int? = nil) async throws -> CollectionRevisionMetadata {
        guard !slug.isEmpty, slug.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
              revision == nil || revision! > 0 else { throw NexusAPIError.invalidCollection }
        var request = try authenticatedRequest(url: URL(string: "https://api.nexusmods.com/v2/graphql")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let query = """
        query GetCollectionRevision($slug: String, $domainName: String, $revision: Int) {
            collectionRevision(slug: $slug, domainName: $domainName, revision: $revision, viewAdultContent: true) {
                revisionNumber downloadLink
                collection { slug name summary user { name } }
            }
        }
        """
        var variables: [String: Any] = ["slug": slug, "domainName": "stardewvalley"]
        if let revision { variables["revision"] = revision }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let data = try await checkedData(for: request)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NexusAPIError.invalidResponse
        }
        if let errors = root["errors"] as? [[String: Any]], !errors.isEmpty {
            throw NexusAPIError.graphQL(errors.compactMap { $0["message"] as? String }.joined(separator: "; "))
        }
        guard let payload = root["data"] as? [String: Any],
              let value = payload["collectionRevision"] as? [String: Any],
              let revisionNumber = integer(value["revisionNumber"]), revisionNumber > 0,
              let downloadString = value["downloadLink"] as? String,
              let downloadLink = URL(string: downloadString),
              let collection = value["collection"] as? [String: Any],
              let name = collection["name"] as? String else { throw NexusAPIError.invalidCollection }
        guard isNexusServiceURL(downloadLink) else { throw NexusAPIError.untrustedLink }
        if let revision, revision != revisionNumber { throw NexusAPIError.invalidCollection }
        let curator = (collection["user"] as? [String: Any])?["name"] as? String
        return CollectionRevisionMetadata(slug: slug, revisionNumber: revisionNumber, name: name,
                                          summary: collection["summary"] as? String,
                                          curator: curator, downloadLink: downloadLink)
    }

    func resolveCollectionArchiveLink(_ link: URL) async throws -> URL {
        // API credentials must never follow a collection-provided arbitrary URL.
        guard isNexusServiceURL(link) else { throw NexusAPIError.untrustedLink }
        let data = try await checkedData(for: authenticatedRequest(url: link))
        struct Mirror: Decodable { let URI: String }
        struct Mirrors: Decodable { let download_links: [Mirror] }
        let mirrors = try JSONDecoder().decode(Mirrors.self, from: data)
        guard let value = mirrors.download_links.first?.URI,
              let url = URL(string: value), url.scheme?.lowercased() == "https", url.host != nil else {
            throw NexusAPIError.invalidResponse
        }
        return url
    }

    private func authenticatedRequest(url: URL) throws -> URLRequest {
        guard let apiKey, !apiKey.isEmpty else { throw NexusAPIError.notAuthenticated }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "apiKey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Starfruit", forHTTPHeaderField: "Application-Name")
        return request
    }

    private func checkedData(for request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw NexusAPIError.invalidResponse }
        guard (200...299).contains(response.statusCode) else {
            let message = String(data: data.prefix(512), encoding: .utf8) ?? ""
            throw NexusAPIError.http(response.statusCode, message)
        }
        return data
    }

    private func isNexusServiceURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host == "nexusmods.com" || host.hasSuffix(".nexusmods.com")
    }

    private func integer(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let string = value as? String { return Int(string) }
        return nil
    }

    func logout() {
        authenticationGeneration += 1
        KeychainHelper.delete()
        preferences.removeObject(forKey: "nexus-api-key-fallback")
        preferences.removeObject(forKey: "nexusCurrentUser")
        self.apiKey = nil
        self.currentUser = nil
    }
}
