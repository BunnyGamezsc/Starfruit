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

class NexusClient: ObservableObject {
    private let baseURL = URL(string: "https://api.nexusmods.com/v1/")!
    private var apiKey: String?
    
    @Published var currentUser: NexusUserResponse?
    @Published var isValidating = false
    
    init() {
        self.apiKey = KeychainHelper.load()
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
    
    func getFileDownloadLink(modID: Int, fileID: Int) async -> URL? {
        guard let key = apiKey else { return nil }
        var request = URLRequest(url: baseURL.appendingPathComponent("games/stardewvalley/mods/\(modID)/files/\(fileID)/download_link.json"))
        request.addValue(key, forHTTPHeaderField: "apiKey")
        
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            struct DownloadLink: Codable { let URI: String }
            let links = try JSONDecoder().decode([DownloadLink].self, from: data)
            return URL(string: links.first?.URI ?? "")
        } catch {
            print("Error fetching download link: \(error)")
            return nil
        }
    }

    func logout() {
        KeychainHelper.delete()
        self.apiKey = nil
        self.currentUser = nil
    }
}
