import Foundation
import AppKit

struct ModProfile: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var enabledModIDs: Set<String>
    var isCollectionProfile: Bool = false
    
    enum CodingKeys: String, CodingKey {
        case id, name, enabledModIDs, isCollectionProfile
    }
    
    init(id: UUID = UUID(), name: String, enabledModIDs: Set<String>, isCollectionProfile: Bool = false) {
        self.id = id
        self.name = name
        self.enabledModIDs = enabledModIDs
        self.isCollectionProfile = isCollectionProfile
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        enabledModIDs = try container.decode(Set<String>.self, forKey: .enabledModIDs)
        isCollectionProfile = try container.decodeIfPresent(Bool.self, forKey: .isCollectionProfile) ?? false
    }
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

@MainActor
class ModManager: ObservableObject {
    @Published var mods: [ModEntry] = []
    @Published var profiles: [ModProfile] = []
    @Published var selectedProfileID: UUID?
    @Published var searchText: String = ""
    @Published var isGameRunning: Bool = false
    private var statusTimer: Timer?
    
    var currentProfile: ModProfile? {
        profiles.first(where: { $0.id == selectedProfileID })
    }
    
    var filteredMods: [ModEntry] {
        let current = currentProfile
        let showCollectionMods = current?.isCollectionProfile ?? false
        
        let baseMods: [ModEntry]
        if showCollectionMods {
            baseMods = mods
        } else {
            // Exclude collection mods (mods inside a "Collections/" folder)
            baseMods = mods.filter { !$0.folderPath.localizedCaseInsensitiveContains("/Collections/") }
        }
        
        if searchText.isEmpty {
            return baseMods
        } else {
            return baseMods.filter { $0.manifest.Name.localizedCaseInsensitiveContains(searchText) || $0.manifest.Author.localizedCaseInsensitiveContains(searchText) }
        }
    }
    
    init() {
        loadProfiles()
        loadDeepLinkLogs()
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
    
    nonisolated func checkGameStatus() {
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
        
        Task { @MainActor in
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

    @Published var deepLinkLogs: [String] = []

    private var deepLinkLogsFileURL: URL {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let appSupport = paths[0].appendingPathComponent("StarfruitNative", isDirectory: true)
        if !FileManager.default.fileExists(atPath: appSupport.path) {
            try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        }
        return appSupport.appendingPathComponent("deeplinks.log")
    }

    func logDeepLink(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium)
        let logLine = "[\(timestamp)] \(message)"
        print("[DeepLinkLog] \(logLine)")
        
        DispatchQueue.main.async {
            self.deepLinkLogs.insert(logLine, at: 0)
        }
        
        // Write to log file
        if let data = (logLine + "\n").data(using: .utf8) {
            if let fileHandle = try? FileHandle(forWritingTo: deepLinkLogsFileURL) {
                fileHandle.seekToEndOfFile()
                fileHandle.write(data)
                fileHandle.closeFile()
            } else {
                try? data.write(to: deepLinkLogsFileURL)
            }
        }
    }

    func loadDeepLinkLogs() {
        if let content = try? String(contentsOf: deepLinkLogsFileURL, encoding: .utf8) {
            let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }.reversed()
            DispatchQueue.main.async {
                self.deepLinkLogs = Array(lines)
            }
        }
    }

    func clearDeepLinkLogs() {
        try? "".write(to: deepLinkLogsFileURL, atomically: true, encoding: .utf8)
        DispatchQueue.main.async {
            self.deepLinkLogs = []
        }
    }

    func handleNXMURL(_ url: URL, nexusClient: NexusClient, downloadManager: DownloadManager, completion: (() -> Void)? = nil) {
        logDeepLink("Processing deep link: \(url.absoluteString)")
        
        var nxmKey: String? = nil
        var nxmExpires: String? = nil
        
        // Log query parameters for debugging
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            let queryItems = components.queryItems ?? []
            nxmKey = queryItems.first(where: { $0.name == "key" })?.value
            nxmExpires = queryItems.first(where: { $0.name == "expires" })?.value
            
            let queryMap = queryItems.reduce(into: [String: String]()) { $0[$1.name] = $1.value }
            logDeepLink("Query parameters: \(queryMap.description)")
        }
        
        let pathComponents = url.pathComponents
        logDeepLink("Path components: \(pathComponents.description)")
        
        if pathComponents.contains("collections") || pathComponents.contains("collection") {
            handleNXMCollectionURL(url, nexusClient: nexusClient, downloadManager: downloadManager, completion: completion)
            return
        }
        
        // Check if user is logged in / has API key
        guard nexusClient.hasApiKey else {
            logDeepLink("Error: No Nexus API key found. Please connect your Nexus Mods account in Settings first.")
            return
        }
        
        guard let modsIndex = pathComponents.firstIndex(of: "mods"),
              modsIndex + 1 < pathComponents.count,
              let modID = Int(pathComponents[modsIndex + 1]) else {
            logDeepLink("Error: Could not parse Mod ID from path components: \(pathComponents.description)")
            return
        }
        
        guard let filesIndex = pathComponents.firstIndex(of: "files"),
              filesIndex + 1 < pathComponents.count,
              let fileID = Int(pathComponents[filesIndex + 1]) else {
            logDeepLink("Error: Could not parse File ID from path components: \(pathComponents.description)")
            return
        }
        
        logDeepLink("Successfully parsed Mod ID: \(modID), File ID: \(fileID)")
        
        Task {
            logDeepLink("Requesting download link from Nexus API (with key & expires tokens)...")
            let (downloadURL, errorMsg) = await nexusClient.getFileDownloadLink(modID: modID, fileID: fileID, nxmKey: nxmKey, nxmExpires: nxmExpires)
            if let downloadURL = downloadURL {
                logDeepLink("Download link received: \(downloadURL.absoluteString)")
                
                logDeepLink("Fetching mod details for naming...")
                let modDetails = await nexusClient.fetchModDetails(modID: modID)
                let name = modDetails?.name ?? "Mod-\(modID)"
                let version = modDetails?.version ?? "1.0"
                // Clean filename
                let fileName = "\(name)-\(version).zip".replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
                logDeepLink("Target filename: \(fileName)")
                
                // Retrieve paths from User Defaults
                let useWine = UserDefaults.standard.bool(forKey: "useWine")
                let nativeSmapiDir = UserDefaults.standard.string(forKey: "nativeSmapiDir") ?? "/Applications/Stardew Valley.app/Contents/MacOS"
                let nativeModsDir = UserDefaults.standard.string(forKey: "nativeModsDir") ?? ""
                let wineSmapiDir = UserDefaults.standard.string(forKey: "wineSmapiDir") ?? ""
                let wineModsDir = UserDefaults.standard.string(forKey: "wineModsDir") ?? ""
                
                let smapiDir = useWine ? wineSmapiDir : nativeSmapiDir
                let modsDir = useWine ? wineModsDir : nativeModsDir
                
                logDeepLink("Starting download with parameters:")
                logDeepLink("  - SMAPI Dir: \(smapiDir)")
                logDeepLink("  - Mods Dir: \(modsDir)")
                logDeepLink("  - File: \(fileName)")
                
                DispatchQueue.main.async {
                    downloadManager.startOrResumeDownload(url: downloadURL, fileName: fileName, modID: modID, fileID: fileID, smapiDir: smapiDir, customModsDir: modsDir, modManager: self)
                    completion?()
                }
            } else {
                logDeepLink("Error: \(errorMsg ?? "Unknown error occurred requesting download link")")
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

    nonisolated private func getModDirectory(smapiDir: String, customModsDir: String) -> URL {
        if !customModsDir.isEmpty {
            return URL(fileURLWithPath: SMAPILauncher.resolvePath(customModsDir))
        }
        return URL(fileURLWithPath: SMAPILauncher.resolvePath(smapiDir)).appendingPathComponent("Mods")
    }

    func prepareProfileForLaunch(smapiDir: String, customModsDir: String) -> String? {
        guard let profileID = selectedProfileID, 
              profiles.contains(where: { $0.id == profileID }) else { return nil }
        
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

    nonisolated func installMod(zipURL: URL, smapiDir: String, customModsDir: String, collectionFolder: String? = nil, autoEnableInProfileID: UUID? = nil) {
        let modsPath = getModDirectory(smapiDir: smapiDir, customModsDir: customModsDir)
        let destinationPath: URL
        if let collectionFolder = collectionFolder {
            destinationPath = modsPath.appendingPathComponent(collectionFolder)
            try? FileManager.default.createDirectory(at: destinationPath, withIntermediateDirectories: true)
        } else {
            destinationPath = modsPath
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        task.arguments = ["-o", "-q", zipURL.path, "-d", destinationPath.path]

        do {
            try task.run()
            task.waitUntilExit()
            
            Task { @MainActor in
                self.loadMods(smapiDir: smapiDir, customModsDir: customModsDir)
            }
            
            if let profileID = autoEnableInProfileID {
                let fileManager = FileManager.default
                let enumerator = fileManager.enumerator(at: destinationPath, includingPropertiesForKeys: nil)
                var extractedIDs: [String] = []
                while let fileURL = enumerator?.nextObject() as? URL {
                    if fileURL.lastPathComponent.lowercased() == "manifest.json",
                       let rawData = try? Data(contentsOf: fileURL) {
                        var jsonString = String(data: rawData, encoding: .utf8) ?? String(data: rawData, encoding: .isoLatin1) ?? ""
                        jsonString = jsonString.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                        let blockCommentPattern = "/\\*[\\s\\S]*?\\*/"
                        if let blockRegex = try? NSRegularExpression(pattern: blockCommentPattern) {
                            let range = NSRange(jsonString.startIndex..., in: jsonString)
                            jsonString = blockRegex.stringByReplacingMatches(in: jsonString, range: range, withTemplate: "")
                        }
                        let lines = jsonString.components(separatedBy: .newlines)
                        jsonString = lines.filter { line in
                            let trimmed = line.trimmingCharacters(in: .whitespaces)
                            return !trimmed.hasPrefix("//")
                        }.joined(separator: "\n")
                        jsonString = jsonString.replacingOccurrences(of: "\"$schema\"", with: "\"_schema\"")
                        
                        if let strippedData = jsonString.data(using: .utf8),
                           let manifest = try? JSONDecoder().decode(ModManifest.self, from: strippedData) {
                            extractedIDs.append(manifest.UniqueID)
                        }
                    }
                }
                
                if !extractedIDs.isEmpty {
                    Task { @MainActor in
                        if let pIdx = self.profiles.firstIndex(where: { $0.id == profileID }) {
                            for id in extractedIDs {
                                self.profiles[pIdx].enabledModIDs.insert(id)
                            }
                            self.saveProfiles()
                        }
                    }
                }
            }
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
    
    func handleNXMCollectionURL(_ url: URL, nexusClient: NexusClient, downloadManager: DownloadManager, completion: (() -> Void)? = nil) {
        logDeepLink("Processing collection deep link: \(url.absoluteString)")
        
        let pathComponents = url.pathComponents
        
        guard let collectionsIndex = pathComponents.firstIndex(where: { $0 == "collections" || $0 == "collection" }),
              collectionsIndex + 1 < pathComponents.count else {
            logDeepLink("Error: Could not parse collection slug from path components: \(pathComponents.description)")
            return
        }
        let slug = pathComponents[collectionsIndex + 1]
        
        var revision: Int = 1
        if let revisionsIndex = pathComponents.firstIndex(where: { $0 == "revisions" || $0 == "revision" }),
           revisionsIndex + 1 < pathComponents.count,
           let parsedRevision = Int(pathComponents[revisionsIndex + 1]) {
            revision = parsedRevision
        }
        
        logDeepLink("Parsed Collection Slug: \(slug), Revision: \(revision)")
        
        Task {
            logDeepLink("Fetching collection revision mods via Nexus GraphQL API...")
            do {
                let (collectionName, modFiles) = try await fetchCollectionRevisionMods(slug: slug, revision: revision, nexusClient: nexusClient)
                logDeepLink("GraphQL Request successful. Collection Name: '\(collectionName)'. Found \(modFiles.count) files.")
                
                for (index, fileEntry) in modFiles.enumerated() {
                    let modName = fileEntry.file?.mod?.name ?? "Unknown Mod"
                    let modId = fileEntry.file?.mod?.modId ?? 0
                    let fileId = fileEntry.fileId
                    let optionalStr = fileEntry.optional ? " (Optional)" : ""
                    logDeepLink("  [\(index + 1)] Mod: \(modName) (ID: \(modId)), File ID: \(fileId)\(optionalStr)")
                }
                
                // Create a special collection profile if it doesn't exist
                let profileName = "Collection: \(collectionName)"
                var targetProfileID: UUID
                
                if let existingProfile = self.profiles.first(where: { $0.name == profileName }) {
                    targetProfileID = existingProfile.id
                    logDeepLink("Using existing profile: '\(profileName)'")
                } else {
                    let newProfile = ModProfile(name: profileName, enabledModIDs: [], isCollectionProfile: true)
                    targetProfileID = newProfile.id
                    DispatchQueue.main.async {
                        self.profiles.append(newProfile)
                        self.selectedProfileID = targetProfileID
                        self.saveProfiles()
                    }
                    logDeepLink("Created new special collection profile: '\(profileName)'")
                }
                
                // If it is the test collection slug, skip downloading as requested by user
                if slug == "tckf0m" {
                    logDeepLink("Info: Dry-run active for test modpack 'tckf0m'. Skipped downloading 400MB collection files as requested.")
                    return
                }
                
                let essentialFiles = modFiles.filter { !$0.optional }
                logDeepLink("Starting queue for \(essentialFiles.count) essential mods...")
                
                let useWine = UserDefaults.standard.bool(forKey: "useWine")
                let nativeSmapiDir = UserDefaults.standard.string(forKey: "nativeSmapiDir") ?? "/Applications/Stardew Valley.app/Contents/MacOS"
                let nativeModsDir = UserDefaults.standard.string(forKey: "nativeModsDir") ?? ""
                let wineSmapiDir = UserDefaults.standard.string(forKey: "wineSmapiDir") ?? ""
                let wineModsDir = UserDefaults.standard.string(forKey: "wineModsDir") ?? ""
                
                let smapiDir = useWine ? wineSmapiDir : nativeSmapiDir
                let modsDir = useWine ? wineModsDir : nativeModsDir
                
                // Download into Collections/slug/ folder
                let collectionFolder = "Collections/\(slug)"
                
                for fileEntry in essentialFiles {
                    guard let fileDetail = fileEntry.file,
                          let modDetail = fileDetail.mod else { continue }
                    
                    let modID = modDetail.modId
                    let fileID = fileDetail.fileId
                    let originalName = fileDetail.name
                    
                    let fileName = originalName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
                    
                    logDeepLink("Queueing: \(fileName) (Mod: \(modID), File: \(fileID))")
                    
                    let (downloadURL, errorMsg) = await nexusClient.getFileDownloadLink(modID: modID, fileID: fileID)
                    if let downloadURL = downloadURL {
                        DispatchQueue.main.async {
                            downloadManager.startOrResumeDownload(
                                url: downloadURL,
                                fileName: fileName,
                                modID: modID,
                                fileID: fileID,
                                smapiDir: smapiDir,
                                customModsDir: modsDir,
                                modManager: self,
                                collectionFolder: collectionFolder,
                                autoEnableInProfileID: targetProfileID
                            )
                        }
                    } else {
                        logDeepLink("  Error: Could not retrieve download URL for \(fileName): \(errorMsg ?? "Unknown error")")
                        let manualURL = URL(string: "https://www.nexusmods.com/stardewvalley/mods/\(modID)?tab=files&file_id=\(fileID)&nmm=1")
                        DispatchQueue.main.async {
                            downloadManager.addManualDownload(
                                fileName: fileName,
                                modID: modID,
                                fileID: fileID,
                                manualURL: manualURL,
                                errorMsg: errorMsg,
                                smapiDir: smapiDir,
                                customModsDir: modsDir,
                                collectionFolder: collectionFolder,
                                autoEnableInProfileID: targetProfileID
                            )
                        }
                    }
                }
                
                DispatchQueue.main.async {
                    completion?()
                }
                
            } catch {
                logDeepLink("Error: GraphQL collection fetch failed: \(error.localizedDescription)")
            }
        }
    }
    
    private func fetchCollectionRevisionMods(slug: String, revision: Int, nexusClient: NexusClient) async throws -> (name: String, files: [GraphQLResponse.ModFileEntry]) {
        let url = URL(string: "https://api.nexusmods.com/v2/graphql")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        
        if let key = nexusClient.getApiKey() {
            request.addValue(key, forHTTPHeaderField: "apiKey")
        }
        
        let query = """
        query CollectionData($revision: Int!, $slug: String!, $viewAdultContent: Boolean) {
            collection(slug: $slug) {
                name
            }
            collectionRevision(revision: $revision, slug: $slug, viewAdultContent: $viewAdultContent) {
                modFiles {
                    fileId
                    optional
                    file {
                        fileId
                        name
                        mod {
                            modId
                            name
                        }
                    }
                }
            }
        }
        """
        
        let variables: [String: Any] = [
            "revision": revision,
            "slug": slug,
            "viewAdultContent": true
        ]
        
        let payload: [String: Any] = [
            "query": query,
            "variables": variables,
            "operationName": "CollectionData"
        ]
        
        let jsonData = try JSONSerialization.data(withJSONObject: payload, options: [])
        request.httpBody = jsonData
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw NSError(domain: "GraphQL", code: code, userInfo: [NSLocalizedDescriptionKey: "Server returned status code \(code)"])
        }
        
        let decoded = try JSONDecoder().decode(GraphQLResponse.self, from: data)
        let collectionName = decoded.data?.collection?.name ?? "Collection \(slug)"
        let modFiles = decoded.data?.collectionRevision?.modFiles ?? []
        return (collectionName, modFiles)
    }
}

struct GraphQLResponse: Codable {
    let data: GraphQLData?
    
    struct GraphQLData: Codable {
        let collection: CollectionInfo?
        let collectionRevision: CollectionRevision?
    }
    
    struct CollectionInfo: Codable {
        let name: String
    }
    
    struct CollectionRevision: Codable {
        let modFiles: [ModFileEntry]?
    }
    
    struct ModFileEntry: Codable {
        let fileId: Int
        let optional: Bool
        let file: FileDetail?
    }
    
    struct FileDetail: Codable {
        let fileId: Int
        let name: String
        let mod: ModDetail?
    }
    
    struct ModDetail: Codable {
        let modId: Int
        let name: String
    }
}
