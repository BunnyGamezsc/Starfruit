import Foundation
import AppKit

struct ModProfile: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var enabledModIDs: Set<String>
}

struct ModDependency: Decodable {
    var UniqueID: String
    var MinimumVersion: String?
    var IsRequired: Bool?
    
    enum CodingKeys: String, CodingKey {
        case UniqueID, UniqueId, MinimumVersion, IsRequired
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        UniqueID = try container.decodeIfPresent(String.self, forKey: .UniqueID) ?? 
                   container.decodeIfPresent(String.self, forKey: .UniqueId) ?? ""
        MinimumVersion = try container.decodeIfPresent(String.self, forKey: .MinimumVersion)
        IsRequired = try container.decodeIfPresent(Bool.self, forKey: .IsRequired)
    }
}

struct ModManifest: Decodable {
    var Name: String
    var Author: String
    var Version: String
    var Description: String?
    var UniqueID: String
    var UpdateKeys: [String]?
    var Dependencies: [ModDependency]?
    
    enum CodingKeys: String, CodingKey {
        case Name, Author, Version, Description, UniqueID, UniqueId, UpdateKeys, Dependencies
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        Name = try container.decodeIfPresent(String.self, forKey: .Name) ?? "Unknown Mod"
        Author = try container.decodeIfPresent(String.self, forKey: .Author) ?? "Unknown Author"
        Description = try container.decodeIfPresent(String.self, forKey: .Description)
        
        // Handle UniqueID vs UniqueId
        if let id = try container.decodeIfPresent(String.self, forKey: .UniqueID) {
            UniqueID = id
        } else if let id = try container.decodeIfPresent(String.self, forKey: .UniqueId) {
            UniqueID = id
        } else {
            UniqueID = UUID().uuidString
        }
        
        UpdateKeys = try container.decodeIfPresent([String].self, forKey: .UpdateKeys)
        Dependencies = try container.decodeIfPresent([ModDependency].self, forKey: .Dependencies)
        
        // Version can be a string "1.0.0" or an object {"MajorVersion": 1, "MinorVersion": 0}
        if let vString = try? container.decode(String.self, forKey: .Version) {
            Version = vString
        } else {
            Version = "Unknown"
        }
    }
}

struct ModEntry: Identifiable {
    var id: String { manifest.UniqueID }
    var manifest: ModManifest
    var folderPath: String
    var hasUpdate: Bool = false
}

class ModManager: ObservableObject {
    @Published var mods: [ModEntry] = []
    @Published var profiles: [ModProfile] = []
    @Published var selectedProfileID: UUID?
    @Published var searchText: String = ""
    @Published var isGameRunning: Bool = false
    private var statusTimer: Timer?
    
    var filteredMods: [ModEntry] {
        if searchText.isEmpty {
            return mods
        } else {
            return mods.filter { $0.manifest.Name.localizedCaseInsensitiveContains(searchText) || $0.manifest.Author.localizedCaseInsensitiveContains(searchText) }
        }
    }
    
    init() {
        loadProfiles()
        if profiles.isEmpty {
            let defaultProfile = ModProfile(name: "Default", enabledModIDs: [])
            profiles.append(defaultProfile)
            selectedProfileID = defaultProfile.id
            saveProfiles()
        } else if selectedProfileID == nil {
            selectedProfileID = profiles.first?.id
        }
        
        // Polling timer to check if SMAPI is running
        statusTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkGameStatus()
        }
    }
    
    func checkGameStatus() {
        let runningApps = NSWorkspace.shared.runningApplications
        var isRunning = false
        for app in runningApps {
            if app.bundleIdentifier == "com.starfruit.smapi-wine-wrapper" || 
               app.localizedName == "SMAPI Wine" ||
               app.localizedName == "SMAPI" {
                isRunning = true
                break
            }
        }
        
        DispatchQueue.main.async {
            if self.isGameRunning != isRunning {
                self.isGameRunning = isRunning
            }
        }
    }
    
    func stopGame() {
        let runningApps = NSWorkspace.shared.runningApplications
        for app in runningApps {
            if app.bundleIdentifier == "com.starfruit.smapi-wine-wrapper" || 
               app.localizedName == "SMAPI Wine" ||
               app.localizedName == "SMAPI" {
                app.terminate()
            }
        }
    }
    
    func addProfile(name: String) {
        let newProfile = ModProfile(name: name, enabledModIDs: [])
        profiles.append(newProfile)
        selectedProfileID = newProfile.id
        saveProfiles()
    }
    
    func deleteProfile(id: UUID) {
        profiles.removeAll { $0.id == id }
        if selectedProfileID == id {
            selectedProfileID = profiles.first?.id
        }
        saveProfiles()
    }
    
    func renameProfile(id: UUID, newName: String) {
        if let index = profiles.firstIndex(where: { $0.id == id }) {
            profiles[index].name = newName
            saveProfiles()
        }
    }
    
    private var profilesFileURL: URL {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let appSupport = paths[0].appendingPathComponent("StarfruitNative", isDirectory: true)
        if !FileManager.default.fileExists(atPath: appSupport.path) {
            try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        }
        return appSupport.appendingPathComponent("profiles.json")
    }
    
    func saveProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            try? data.write(to: profilesFileURL)
        }
        UserDefaults.standard.set(selectedProfileID?.uuidString, forKey: "selectedProfileID")
    }
    
    func loadProfiles() {
        if let data = try? Data(contentsOf: profilesFileURL),
           let loadedProfiles = try? JSONDecoder().decode([ModProfile].self, from: data) {
            self.profiles = loadedProfiles
        }
        if let idString = UserDefaults.standard.string(forKey: "selectedProfileID"),
           let uuid = UUID(uuidString: idString) {
            self.selectedProfileID = uuid
        }
    }
    
    func importOriginalProfiles() {
        let fileManager = FileManager.default
        let homeDir = fileManager.homeDirectoryForCurrentUser
        let originalProfilesPath = homeDir.appendingPathComponent("Library/Application Support/Starfruit/Data/Profiles")
        
        guard let files = try? fileManager.contentsOfDirectory(at: originalProfilesPath, includingPropertiesForKeys: nil) else { return }
        
        struct OriginalProfile: Codable {
            let Name: String
            let EnabledModIds: [String]
        }
        
        for fileURL in files where fileURL.pathExtension == "json" {
            if let data = try? Data(contentsOf: fileURL),
               let original = try? JSONDecoder().decode(OriginalProfile.self, from: data) {
                // Check if profile already exists
                if !profiles.contains(where: { $0.name == original.Name }) {
                    let newProfile = ModProfile(name: original.Name, enabledModIDs: Set(original.EnabledModIds))
                    profiles.append(newProfile)
                }
            }
        }
        saveProfiles()
    }
    
    func toggleMod(modID: String) {
        guard let index = profiles.firstIndex(where: { $0.id == selectedProfileID }) else { return }
        if profiles[index].enabledModIDs.contains(modID) {
            profiles[index].enabledModIDs.remove(modID)
        } else {
            enableModWithDependencies(modID, profileIndex: index)
        }
        saveProfiles()
    }
    
    private func enableModWithDependencies(_ modID: String, profileIndex: Int) {
        // Avoid infinite recursion
        if profiles[profileIndex].enabledModIDs.contains(modID) { return }
        
        profiles[profileIndex].enabledModIDs.insert(modID)
        
        // Find the mod manifest to check for dependencies
        if let mod = mods.first(where: { $0.id == modID }),
           let dependencies = mod.manifest.Dependencies {
            for dep in dependencies {
                // Only auto-enable if it's required (default is true in SMAPI if not specified)
                if dep.IsRequired ?? true {
                    enableModWithDependencies(dep.UniqueID, profileIndex: profileIndex)
                }
            }
        }
    }
    
    func isModEnabled(modID: String) -> Bool {
        // SMAPI core mods are always enabled
        if modID == "SMAPI.ConsoleCommands" || modID == "SMAPI.SaveBackup" {
            return true
        }
        guard let profile = profiles.first(where: { $0.id == selectedProfileID }) else { return false }
        return profile.enabledModIDs.contains(modID)
    }

    func getMissingDependencies(for mod: ModEntry) -> [String] {
        guard let deps = mod.manifest.Dependencies else { return [] }
        var missing: [String] = []
        for dep in deps {
            if dep.IsRequired ?? true {
                if !mods.contains(where: { $0.id == dep.UniqueID }) {
                    missing.append(dep.UniqueID)
                }
            }
        }
        return missing
    }
    
    func getDisabledDependencies(for mod: ModEntry) -> [String] {
        guard isModEnabled(modID: mod.id), let deps = mod.manifest.Dependencies else { return [] }
        var disabled: [String] = []
        for dep in deps {
            if dep.IsRequired ?? true {
                if mods.contains(where: { $0.id == dep.UniqueID }) && !isModEnabled(modID: dep.UniqueID) {
                    disabled.append(dep.UniqueID)
                }
            }
        }
        return disabled
    }

    private func getModDirectory(smapiDir: String, customModsDir: String) -> URL {
        if !customModsDir.isEmpty {
            return URL(fileURLWithPath: SMAPILauncher.resolvePath(customModsDir))
        }
        return URL(fileURLWithPath: SMAPILauncher.resolvePath(smapiDir)).appendingPathComponent("Mods")
    }

    func prepareProfileForLaunch(smapiDir: String, customModsDir: String) -> String? {
        guard let profileID = selectedProfileID, 
              let profile = profiles.first(where: { $0.id == profileID }) else { return nil }
        
        let paths = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        let stagingDir = paths[0].appendingPathComponent("StarfruitNativeStagingMods", isDirectory: true)
        let fileManager = FileManager.default
        
        // Clean existing staging dir
        if fileManager.fileExists(atPath: stagingDir.path) {
            try? fileManager.removeItem(at: stagingDir)
        }
        try? fileManager.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        
        // Symlink enabled mods
        for mod in mods {
            if isModEnabled(modID: mod.id) {
                let sourceURL = URL(fileURLWithPath: mod.folderPath)
                let destURL = stagingDir.appendingPathComponent(sourceURL.lastPathComponent)
                do {
                    try fileManager.createSymbolicLink(at: destURL, withDestinationURL: sourceURL)
                } catch {
                    print("Failed to symlink \(mod.id): \(error)")
                }
            }
        }
        
        return stagingDir.path
    }
    
    func loadMods(smapiDir: String, customModsDir: String) {
        let modsPath = getModDirectory(smapiDir: smapiDir, customModsDir: customModsDir)
        let fileManager = FileManager.default
        
        var loadedMods: [ModEntry] = []
        
        let enumerator = fileManager.enumerator(at: modsPath, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) { (url, error) -> Bool in
            return true
        }
        
        while let fileURL = enumerator?.nextObject() as? URL {
            if fileURL.lastPathComponent.lowercased() == "manifest.json" {
                if let rawData = try? Data(contentsOf: fileURL) {
                    var jsonString = String(data: rawData, encoding: .utf8) ?? String(data: rawData, encoding: .isoLatin1) ?? ""
                    guard !jsonString.isEmpty else { continue }
                    // Normalize Windows CRLF to Unix LF
                    jsonString = jsonString.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                    
                    // Strip block comments /* ... */
                    let blockCommentPattern = "/\\*[\\s\\S]*?\\*/"
                    if let blockRegex = try? NSRegularExpression(pattern: blockCommentPattern) {
                        let range = NSRange(jsonString.startIndex..., in: jsonString)
                        jsonString = blockRegex.stringByReplacingMatches(in: jsonString, range: range, withTemplate: "")
                    }
                    
                    // Strip line comments // (Robust way: filter lines)
                    let lines = jsonString.components(separatedBy: .newlines)
                    jsonString = lines.filter { line in
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        return !trimmed.hasPrefix("//")
                    }.joined(separator: "\n")
                    
                    // Rename $schema to _schema to avoid Swift decoding issues with $
                    jsonString = jsonString.replacingOccurrences(of: "\"$schema\"", with: "\"_schema\"")
                    
                    if let strippedData = jsonString.data(using: .utf8),
                       let manifest = try? JSONDecoder().decode(ModManifest.self, from: strippedData) {
                        let folderPath = fileURL.deletingLastPathComponent().path
                        loadedMods.append(ModEntry(manifest: manifest, folderPath: folderPath))
                    } else {
                        print("[ModManager] Failed to parse manifest at: \(fileURL.path)")
                    }
                }
            }
        }
        
        DispatchQueue.main.async {
            self.mods = loadedMods.sorted { $0.manifest.Name < $1.manifest.Name }
        }
    }
    func deleteMod(modID: String, smapiDir: String, customModsDir: String) {
        guard let mod = mods.first(where: { $0.id == modID }) else { return }
        let fileManager = FileManager.default
        do {
            try fileManager.removeItem(atPath: mod.folderPath)
            loadMods(smapiDir: smapiDir, customModsDir: customModsDir)
        } catch {
            print("Failed to delete mod: \(error)")
        }
    }

    func installMod(zipURL: URL, smapiDir: String, customModsDir: String) {
        let modsPath = getModDirectory(smapiDir: smapiDir, customModsDir: customModsDir)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        task.arguments = ["-o", "-q", zipURL.path, "-d", modsPath.path]

        do {
            try task.run()
            task.waitUntilExit()
            loadMods(smapiDir: smapiDir, customModsDir: customModsDir)
        } catch {
            print("Failed to extract zip: \(error)")
        }
    }
    func checkAllUpdates(nexusClient: NexusClient) async {
        for i in 0..<mods.count {
            let mod = mods[i]
            if let nexusKey = mod.manifest.UpdateKeys?.first(where: { $0.starts(with: "Nexus:") }),
               let modID = Int(nexusKey.replacingOccurrences(of: "Nexus:", with: "")) {
                let hasUpdate = await nexusClient.checkForUpdates(modID: modID, currentVersion: mod.manifest.Version)
                DispatchQueue.main.async {
                    self.mods[i].hasUpdate = hasUpdate
                }
            }
        }
    }
}
