import Foundation

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
    
    var hasApiKey: Bool {
        return apiKey != nil && !apiKey!.isEmpty
    }
    
    func getApiKey() -> String? {
        return apiKey
    }
    
    @Published var currentUser: NexusUserResponse?
    @Published var isValidating = false
    
    init() {
        // Clean up legacy fallback key if it exists in UserDefaults
        UserDefaults.standard.removeObject(forKey: "nexus-api-key-fallback")
        
        self.apiKey = KeychainHelper.load()
        if let data = UserDefaults.standard.data(forKey: "nexusCurrentUser"),
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
        var request = URLRequest(url: baseURL.appendingPathComponent("users/validate.json"))
        request.addValue(key, forHTTPHeaderField: "apiKey")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return false
            }
            
            let user = try JSONDecoder().decode(NexusUserResponse.self, from: data)
            DispatchQueue.main.async {
                self.currentUser = user
                self.apiKey = key
                KeychainHelper.save(key)
                if let encoded = try? JSONEncoder().encode(user) {
                    UserDefaults.standard.set(encoded, forKey: "nexusCurrentUser")
                }
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
            let (data, _) = try await URLSession.shared.data(for: request)
            return try JSONDecoder().decode(NexusModDetails.self, from: data)
        } catch {
            print("Error fetching mod details: \(error)")
            return nil
        }
    }
    
    func checkForUpdates(modID: Int, currentVersion: String) async -> Bool {
        guard let key = apiKey else { return false }
        var request = URLRequest(url: baseURL.appendingPathComponent("games/stardewvalley/mods/\(modID)/files.json"))
        request.addValue(key, forHTTPHeaderField: "apiKey")
        
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
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
            let (data, response) = try await URLSession.shared.data(for: request)
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

    func logout() {
        KeychainHelper.delete()
        UserDefaults.standard.removeObject(forKey: "nexusCurrentUser")
        self.apiKey = nil
        self.currentUser = nil
    }
}
