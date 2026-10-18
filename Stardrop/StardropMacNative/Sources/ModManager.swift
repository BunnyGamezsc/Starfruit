import Foundation
import AppKit




@MainActor
class ModManager: ObservableObject {
    @Published var mods: [ModEntry] = []
    @Published var profiles: [ModProfile] = []
    @Published var presets: [ModPreset] = []
    @Published var selectedProfileID: UUID?
    @Published var searchText: String = ""
    @Published var isGameRunning: Bool = false
    @Published var isLaunching: Bool = false
    @Published var isCheckingUpdates: Bool = false
    @Published var updateCheckStatus: String?
    private var statusTimer: Timer?
    lazy var collectionManager = CollectionManager(modManager: self)
    @Published var hasUnsavedProfileChanges = false
    @Published var automaticallySaveProfileChanges = UserDefaults.standard.object(forKey: "automaticallySaveProfileChanges") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(automaticallySaveProfileChanges, forKey: "automaticallySaveProfileChanges")
            if automaticallySaveProfileChanges { savePendingProfiles() }
        }
    }
    @Published var profilePersistenceError: String?
    @Published var collectionsSkipSMAPIUpdateCheck = UserDefaults.standard.object(forKey: "collectionsSkipSMAPIUpdateCheck") as? Bool ?? true {
        didSet { UserDefaults.standard.set(collectionsSkipSMAPIUpdateCheck, forKey: "collectionsSkipSMAPIUpdateCheck") }
    }
    private var didObserveLaunchedGame = false
    private var launchedProfileID: UUID?
    private var launchedModFolders: [String: URL] = [:]
    private var loadedSMAPIDir = ""
    private var loadedCustomModsDir = ""
    private var profileStoreUnreadable = false
    private var presetStoreUnreadable = false
    private var didMigrateLegacyCollections = false
    @Published var legacyMigrationReport: LegacyMigrationReport? = Migration.lastReport
    @Published var legacyCollectionImportCount = 0


    var currentProfile: ModProfile? {
        profiles.first(where: { $0.id == selectedProfileID })
    }

    var filteredMods: [ModEntry] {
        let visible = modsForCurrentProfile
        guard !searchText.isEmpty else { return visible }
        return visible.filter { $0.manifest.Name.localizedCaseInsensitiveContains(searchText) || $0.manifest.Author.localizedCaseInsensitiveContains(searchText) }
    }

    /// Resolve one physical copy per logical mod ID, keeping a profile's source selection explicit.
    var modsForCurrentProfile: [ModEntry] {
        guard let profile = currentProfile else { return [] }
        let groups = Dictionary(grouping: mods, by: { $0.id.lowercased() })
        return groups.values.compactMap { copies -> ModEntry? in
            guard let first = copies.first else { return nil }
            let reference = profile.modSources.first(where: { $0.key.caseInsensitiveCompare(first.id) == .orderedSame })?.value
            if let reference { return copies.first(where: { $0.sourceID?.caseInsensitiveCompare(reference) == .orderedSame }) }
            if let source = profile.collectionSourceID, let collection = copies.first(where: { $0.sourceID == source }) { return collection }
            if profile.isCollectionProfile && copies.contains(where: { $0.sourceID?.hasPrefix("legacy_") == true }) { return nil }
            return copies.first(where: { $0.sourceID == nil && !$0.folderPath.localizedCaseInsensitiveContains("/Collections/") })
        }.sorted { $0.manifest.Name.localizedStandardCompare($1.manifest.Name) == .orderedAscending }
    }

    init() {
        loadProfiles()
        loadPresets()
        loadDeepLinkLogs()
        if profiles.isEmpty {
            let defaultProfile = ModProfile(name: "Default", enabledModIDs: [])
            profiles.append(defaultProfile)
            selectedProfileID = defaultProfile.id
            if !profileStoreUnreadable { saveProfiles() }
        } else if !profiles.contains(where: { $0.id == selectedProfileID }) {
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
            if app.bundleIdentifier == "com.bunnygamez.starfruit.smapi-wine-wrapper" ||
               app.bundleIdentifier == "com.bunnygamez.starfruit.smapi-native-wrapper" ||
               app.bundleIdentifier == "com.concernedape.stardewvalley" ||
               app.localizedName == "SMAPI Wine" ||
               app.localizedName == "SMAPI Native" ||
               app.localizedName == "SMAPI" ||
               app.localizedName == "Stardew Valley" {
                isRunning = true
                break
            }
        }

        Task { @MainActor in
            if isRunning && self.launchedProfileID != nil { self.didObserveLaunchedGame = true }
            if !isRunning && self.didObserveLaunchedGame { self.captureLaunchedProfileConfigs() }
            if self.isGameRunning != isRunning {
                self.isGameRunning = isRunning
            }
            // Clear launching flag if we've detected the game
            if isRunning {
                self.isLaunching = false
            }
        }
    }

    func startLaunchTimeout(seconds: TimeInterval = 8.0) {
        // Set launching UI state immediately
        Task { @MainActor in
            self.isLaunching = true
            self.isGameRunning = true
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self = self else { return }
            // Re-check process list and update state
            self.checkGameStatus()
            Task { @MainActor in
                if !self.isGameRunning {
                    self.isLaunching = false
                    self.isGameRunning = false
                } else {
                    self.isLaunching = false
                }
            }
        }
    }

    func stopGame() {
        let runningApps = NSWorkspace.shared.runningApplications
        for app in runningApps {
            if app.bundleIdentifier == "com.bunnygamez.starfruit.smapi-wine-wrapper" ||
               app.bundleIdentifier == "com.bunnygamez.starfruit.smapi-native-wrapper" ||
               app.bundleIdentifier == "com.concernedape.stardewvalley" ||
               app.localizedName == "SMAPI Wine" ||
               app.localizedName == "SMAPI Native" ||
               app.localizedName == "SMAPI" ||
               app.localizedName == "Stardew Valley" {
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
        guard url.scheme?.lowercased() == "nxm", url.host?.lowercased() == "stardewvalley" else {
            logDeepLink("Error: Only Stardew Valley NXM links are supported.")
            return
        }
        logDeepLink("Processing Nexus deep link for Stardew Valley")

        var nxmKey: String? = nil
        var nxmExpires: String? = nil

        // Log query parameters for debugging
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            let queryItems = components.queryItems ?? []
            nxmKey = queryItems.first(where: { $0.name == "key" })?.value
            nxmExpires = queryItems.first(where: { $0.name == "expires" })?.value

            logDeepLink("Download authorization parameters received.")
        }

        let pathComponents = url.pathComponents
        logDeepLink("Path components: \(pathComponents.description)")

        if pathComponents.contains("collections") || pathComponents.contains("collection") {
            handleNXMCollectionURL(url, nexusClient: nexusClient, downloadManager: downloadManager, completion: completion)
            return
        }

        if collectionManager.handleFileLink(url, nexusClient: nexusClient) { completion?(); return }
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
        var archiveInstallation: NativeArchiveInstallation?
        if !downloadManager.hasPendingManualDownload(modID: modID, fileID: fileID),
           let sourceID = currentProfile?.collectionSourceID,
           let collection = collectionManager.records.first(where: { $0.id == sourceID && $0.installedRevision != nil }) {
            guard let target = NativeModInstallTarget.choose(collectionName: collection.name) else { completion?(); return }
            if target == .collectionAddon {
                let collections = collectionManager
                archiveInstallation = { archive, cancellationCheck in
                    try await collections.installAddonArchive(archive, collectionID: sourceID, cancellationCheck: cancellationCheck)
                }
            }
        }
        let selectedInstallation = archiveInstallation
        let ordinaryProfileID = currentProfile?.isProtected == false ? selectedProfileID : nil
        Task {
            logDeepLink("Requesting download link from Nexus API (with key & expires tokens)...")
            let (downloadURL, errorMsg) = await nexusClient.getFileDownloadLink(modID: modID, fileID: fileID, nxmKey: nxmKey, nxmExpires: nxmExpires)
            if let downloadURL = downloadURL {
                logDeepLink("Download link received.")

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
                    downloadManager.startOrResumeDownload(url: downloadURL, fileName: fileName, modID: modID, fileID: fileID, smapiDir: smapiDir, customModsDir: modsDir, modManager: self, autoEnableInProfileID: ordinaryProfileID, archiveInstallation: selectedInstallation)
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

    func addProfile(name: String, enabledModIDs: Set<String>, isCollectionProfile: Bool = false) {
        let newProfile = ModProfile(name: name, enabledModIDs: enabledModIDs, isCollectionProfile: isCollectionProfile)
        profiles.append(newProfile)
        selectedProfileID = newProfile.id
        saveProfiles()
    }

    func deleteProfile(id: UUID) {
        guard profiles.first(where: { $0.id == id })?.isProtected != true else { return }
        profiles.removeAll { $0.id == id }
        if selectedProfileID == id {
            selectedProfileID = profiles.first?.id
        }
        saveProfiles()
    }

    func renameProfile(id: UUID, newName: String) {
        if let index = profiles.firstIndex(where: { $0.id == id }), !profiles[index].isProtected {
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

    private var presetsFileURL: URL {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let appSupport = paths[0].appendingPathComponent("StarfruitNative", isDirectory: true)
        if !FileManager.default.fileExists(atPath: appSupport.path) {
            try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        }
        return appSupport.appendingPathComponent("presets.json")
    }

    func saveProfiles(force: Bool = false) {
        guard !profileStoreUnreadable else {
            profilePersistenceError = "The existing profiles file could not be read. It has been left unchanged; recover it or restore a backup before saving."
            return
        }
        guard force || automaticallySaveProfileChanges else { hasUnsavedProfileChanges = true; return }
        do {
            let data = try JSONEncoder().encode(profiles)
            try data.write(to: profilesFileURL, options: .atomic)
            UserDefaults.standard.set(selectedProfileID?.uuidString, forKey: "selectedProfileID")
            hasUnsavedProfileChanges = false
            profilePersistenceError = nil
        } catch { hasUnsavedProfileChanges = true; profilePersistenceError = error.localizedDescription }
    }

    func savePendingProfiles() { saveProfiles(force: true) }

    func loadProfiles() {
        profileStoreUnreadable = false
        if FileManager.default.fileExists(atPath: profilesFileURL.path) {
            do { profiles = try JSONDecoder().decode([ModProfile].self, from: Data(contentsOf: profilesFileURL)) }
            catch {
                profileStoreUnreadable = true
                profilePersistenceError = "Could not read the existing profiles file. Your original data has not been replaced: \(error.localizedDescription)"
            }
        }
        if let idString = UserDefaults.standard.string(forKey: "selectedProfileID"),
           let uuid = UUID(uuidString: idString) {
            self.selectedProfileID = uuid
        }
    }

    func savePresets() {
        guard !presetStoreUnreadable else {
            profilePersistenceError = "The existing presets file could not be read and has been left unchanged."
            return
        }
        if let data = try? JSONEncoder().encode(presets) {
            try? data.write(to: presetsFileURL)
        }
    }

    func loadPresets() {
        presetStoreUnreadable = false
        if FileManager.default.fileExists(atPath: presetsFileURL.path) {
            do { presets = try JSONDecoder().decode([ModPreset].self, from: Data(contentsOf: presetsFileURL)) }
            catch {
                presetStoreUnreadable = true
                profilePersistenceError = "Could not read the existing presets file. Your original data has not been replaced: \(error.localizedDescription)"
            }
        }
    }

    func saveCurrentProfileAsPreset(name: String) {
        guard let profile = currentProfile else { return }
        presets.append(ModPreset(name: name, enabledModIDs: profile.enabledModIDs))
        savePresets()
    }

    func applyPreset(_ preset: ModPreset) {
        guard let index = profiles.firstIndex(where: { $0.id == selectedProfileID }), !profiles[index].isProtected else { return }
        profiles[index].enabledModIDs = preset.enabledModIDs
        saveProfiles()
    }

    func deletePreset(_ preset: ModPreset) {
        presets.removeAll { $0.id == preset.id }
        savePresets()
    }

    func sharedProfileManifestForCurrentProfile(includeNotes: Bool = true, includeDisabledMods: Bool = false, includeModConfigs: Bool = false) -> SharedProfileManifest? {
        guard let profile = currentProfile else { return nil }
        var entries = modsForCurrentProfile.filter { includeDisabledMods || isModEnabled(modID: $0.id) }.map { mod in
            SharedProfileMod(uniqueID: mod.id, name: mod.manifest.Name, version: mod.manifest.Version,
                updateKeys: mod.manifest.UpdateKeys ?? [], sourceID: mod.sourceID,
                isEnabled: isModEnabled(modID: mod.id), note: includeNotes ? profile.modNotes[mod.id] : nil)
        }
        for missing in profile.missingMods where !entries.contains(where: { $0.uniqueID.caseInsensitiveCompare(missing.uniqueID) == .orderedSame }) {
            var exported = missing
            if !includeNotes { exported.note = nil }
            entries.append(exported)
        }
        var configs = includeModConfigs ? profile.preservedModConfigs : [:]
        if includeModConfigs {
            for mod in modsForCurrentProfile where entries.contains(where: { $0.uniqueID == mod.id }) && (launchedProfileID == profile.id || !configs.keys.contains(where: { $0.caseInsensitiveCompare(mod.id) == .orderedSame })) {
                if let data = try? Data(contentsOf: URL(fileURLWithPath: mod.folderPath).appendingPathComponent("config.json")),
                   let config = try? JSONDecoder().decode(ProfileJSONValue.self, from: data) { configs[mod.id] = config }
            }
        }
        return SharedProfileManifest(name: profile.name, enabledMods: entries, notes: includeNotes ? profile.modNotes : nil,
            preservedModConfigs: includeModConfigs ? configs : nil)
    }

    func importSharedProfile(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let manifest = try SharedProfileManifest.decodePortable(data)
        var profile = ModProfile(name: "\(manifest.name) (Imported)", enabledModIDs: [])
        profile.modNotes = manifest.notes ?? [:]
        profile.preservedModConfigs = manifest.preservedModConfigs ?? [:]
        for entry in manifest.enabledMods {
            if entry.isEnabled != false { profile.enabledModIDs.insert(entry.uniqueID) }
            if let source = entry.sourceID { profile.modSources[entry.uniqueID] = source }
            if let note = entry.note { profile.modNotes[entry.uniqueID] = note }
            if !mods.contains(where: { $0.id.caseInsensitiveCompare(entry.uniqueID) == .orderedSame && $0.sourceID == entry.sourceID }) { profile.missingMods.append(entry) }
        }
        profiles.append(profile)
        selectedProfileID = profile.id
        saveProfiles()
    }

    static func decodeUpstreamProfile(_ data: Data) throws -> SharedProfileManifest {
        try SharedProfileManifest.decodePortable(data)
    }

    func copyCurrentProfile(name: String? = nil) {
        guard var copy = currentProfile else { return }
        copy.id = UUID()
        copy.name = name ?? "\(copy.name) (Copy)"
        copy.collectionSourceID = nil
        copy.isCollectionProfile = false
        copy.isProtected = false
        profiles.append(copy)
        selectedProfileID = copy.id
        saveProfiles()
    }

    func setVisibleModsEnabled(_ enabled: Bool, modIDs: [String]) {
        guard let index = profiles.firstIndex(where: { $0.id == selectedProfileID }), !profiles[index].isProtected else { return }
        for id in modIDs where !isCoreMod(id) {
            if enabled { enableModWithDependencies(id, profileIndex: index) }
            else { profiles[index].enabledModIDs = profiles[index].enabledModIDs.filter { $0.caseInsensitiveCompare(id) != .orderedSame } }
        }
        saveProfiles()
    }

    func setModNote(modID: String, note: String) {
        guard let index = profiles.firstIndex(where: { $0.id == selectedProfileID }), !profiles[index].isProtected else { return }
        if note.isEmpty { profiles[index].modNotes.removeValue(forKey: modID) }
        else { profiles[index].modNotes[modID] = note }
        saveProfiles()
    }

    func ignoreUpdate(modID: String, version: String?) {
        guard let index = profiles.firstIndex(where: { $0.id == selectedProfileID }) else { return }
        let oldKeys = profiles[index].ignoredUpdateVersions.keys.filter { $0.caseInsensitiveCompare(modID) == .orderedSame }
        for key in oldKeys { profiles[index].ignoredUpdateVersions.removeValue(forKey: key) }
        profiles[index].ignoredUpdateVersions[modID] = version
        for mod in mods.indices where mods[mod].id.caseInsensitiveCompare(modID) == .orderedSame {
            mods[mod].hasUpdate = mods[mod].suggestedVersion != nil
        }
        saveProfiles()
    }

    func getSuggestedVersion(for mod: ModEntry) -> String? { mod.suggestedVersion }

    func reloadCurrentModDirectories() { loadMods(smapiDir: loadedSMAPIDir, customModsDir: loadedCustomModsDir) }

    func syncCollectionProfile(_ collection: NativeCollection) {
        let references = collection.entries.filter { $0.selected && $0.status == .installed }.flatMap(\.installedMods)
        let ids = Set(references.map(\.uniqueID))
        if let index = profiles.firstIndex(where: { $0.collectionSourceID == collection.id }) {
            profiles[index].reconcileCollection(sourceID: collection.id, newIDs: ids,
                previousIDs: Set((collection.previousEntries ?? collection.entries).flatMap(\.installedMods).map(\.uniqueID)))
            profiles[index].isProtected = true
        } else {
            var profile = ModProfile(name: "Collection: \(collection.name)", enabledModIDs: ids, isCollectionProfile: true)
            profile.collectionSourceID = collection.id
            profile.modSources = Dictionary(ids.map { ($0, collection.id) }, uniquingKeysWith: { first, _ in first })
            profile.isProtected = true
            profiles.append(profile)
            selectedProfileID = profile.id
        }
        saveProfiles()
    }

    func enableCollectionAddons(sourceID: String, ids: [String]) {
        guard let index = profiles.firstIndex(where: { $0.collectionSourceID == sourceID }) else { return }
        profiles[index].enabledModIDs.formUnion(ids)
        for id in ids { profiles[index].modSources[id] = sourceID }
        saveProfiles()
    }

    func removeCollectionProfile(sourceID: String, keepMods: Bool) {
        if keepMods {
            for index in profiles.indices where profiles[index].collectionSourceID == sourceID {
                profiles[index].collectionSourceID = nil
                profiles[index].isCollectionProfile = false
                profiles[index].isProtected = false
            }
        } else {
            profiles.removeAll { $0.collectionSourceID == sourceID }
            if !profiles.contains(where: { $0.id == selectedProfileID }) { selectedProfileID = profiles.first?.id }
        }
        saveProfiles()
    }

    private func isCoreMod(_ modID: String) -> Bool {
        modID.caseInsensitiveCompare("SMAPI.ConsoleCommands") == .orderedSame || modID.caseInsensitiveCompare("SMAPI.SaveBackup") == .orderedSame
    }

    func importOriginalProfiles() {
        guard !hasUnsavedProfileChanges else {
            profilePersistenceError = "Save your pending profile changes before retrying the older installation import."
            return
        }
        legacyMigrationReport = Migration.migrateIfNeeded(force: true)
        loadProfiles()
        loadPresets()
        if !profileStoreUnreadable && !presetStoreUnreadable { profilePersistenceError = nil }
        didMigrateLegacyCollections = false
        reloadCurrentModDirectories()
    }

    func toggleMod(modID: String) {
        guard let index = profiles.firstIndex(where: { $0.id == selectedProfileID }) else { return }
        guard !profiles[index].isProtected, !isCoreMod(modID) else { return }
        if profiles[index].enabledModIDs.contains(where: { $0.caseInsensitiveCompare(modID) == .orderedSame }) {
            profiles[index].enabledModIDs = profiles[index].enabledModIDs.filter { $0.caseInsensitiveCompare(modID) != .orderedSame }
        } else {
            enableModWithDependencies(modID, profileIndex: index)
        }
        saveProfiles()
    }

    private func enableModWithDependencies(_ modID: String, profileIndex: Int) {
        // Avoid infinite recursion
        if profiles[profileIndex].enabledModIDs.contains(where: { $0.caseInsensitiveCompare(modID) == .orderedSame }) { return }

        profiles[profileIndex].enabledModIDs.insert(modID)

        // Find the mod manifest to check for dependencies
        if let mod = modsForCurrentProfile.first(where: { $0.id.caseInsensitiveCompare(modID) == .orderedSame }),
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
        if isCoreMod(modID) {
            return true
        }
        guard let profile = profiles.first(where: { $0.id == selectedProfileID }) else { return false }
        return profile.enabledModIDs.contains(where: { $0.caseInsensitiveCompare(modID) == .orderedSame })
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
        guard !profileStoreUnreadable else {
            profilePersistenceError = "Restore or recover the existing profiles file before launching; it could not be read safely."
            return nil
        }
        guard let profile = currentProfile else { return nil }
        let unresolved = LegacyCollectionMigration.unresolvedModIDs(in: profile, mods: mods)
        guard unresolved.isEmpty else {
            profilePersistenceError = "Choose the intended imported collection before launching. The older app did not record which copies of these mods were selected: \(unresolved.joined(separator: ", "))."
            return nil
        }
        captureLaunchedProfileConfigs()
        let stagingDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StarfruitNativeStagingMods", isDirectory: true)
        do {
            if FileManager.default.fileExists(atPath: stagingDir.path) { try FileManager.default.removeItem(at: stagingDir) }
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            var usedNames = Set<String>()
            for mod in modsForCurrentProfile where isModEnabled(modID: mod.id) {
                let source = URL(fileURLWithPath: mod.folderPath)
                if let config = currentProfile?.preservedModConfigs.first(where: { $0.key.caseInsensitiveCompare(mod.id) == .orderedSame })?.value {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    try encoder.encode(config).write(to: source.appendingPathComponent("config.json"), options: .atomic)
                }
                let name = uniqueStagingName(for: mod, usedNames: &usedNames)
                try FileManager.default.createSymbolicLink(at: stagingDir.appendingPathComponent(name), withDestinationURL: source)
            }
            if collectionsSkipSMAPIUpdateCheck {
                let suppressed = modsForCurrentProfile.filter { $0.sourceID != nil && isModEnabled(modID: $0.id) }.map(\.id)
                let data = try JSONSerialization.data(withJSONObject: ["SuppressUpdateChecks": suppressed], options: [.prettyPrinted, .sortedKeys])
                try data.write(to: stagingDir.appendingPathComponent("SMAPI-config.json"), options: .atomic)
            }
            didObserveLaunchedGame = false
            launchedProfileID = selectedProfileID
            launchedModFolders = Dictionary(modsForCurrentProfile.filter { isModEnabled(modID: $0.id) }.map { ($0.id, URL(fileURLWithPath: $0.folderPath)) }, uniquingKeysWith: { first, _ in first })
            return stagingDir.path
        } catch { profilePersistenceError = "Could not prepare the selected mods: \(error.localizedDescription)"; return nil }
    }

    func captureLaunchedProfileConfigs() {
        guard let id = launchedProfileID, let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        for (modID, folder) in launchedModFolders {
            if let data = try? Data(contentsOf: folder.appendingPathComponent("config.json")),
               let config = try? JSONDecoder().decode(ProfileJSONValue.self, from: data) {
                profiles[index].preservedModConfigs[modID] = config
            }
        }
        launchedProfileID = nil
        didObserveLaunchedGame = false
        launchedModFolders = [:]
        if automaticallySaveProfileChanges { saveProfiles() }
        else {
            // Game-written configuration is durable independently of pending manual profile edits.
            do {
                let saved = try ModProfile.mergingCapturedConfigs(profiles[index].preservedModConfigs, profileID: id, into: Data(contentsOf: profilesFileURL))
                try saved.write(to: profilesFileURL, options: .atomic)
            } catch { profilePersistenceError = "Could not preserve the game's mod configuration: \(error.localizedDescription)" }
        }
    }

    private func uniqueStagingName(for mod: ModEntry, usedNames: inout Set<String>) -> String {
        let folderName = URL(fileURLWithPath: mod.folderPath).lastPathComponent
        if usedNames.insert(folderName).inserted {
            return folderName
        }

        var candidate = (try? NativeArchiveInstaller.safeFolderName(mod.id)) ?? "Mod"
        var suffix = 2
        while !usedNames.insert(candidate).inserted {
            candidate = "Mod-\(suffix)"
            suffix += 1
        }
        return candidate
    }

    func loadMods(smapiDir: String, customModsDir: String) {
        loadedSMAPIDir = smapiDir
        loadedCustomModsDir = customModsDir
        let root = getModDirectory(smapiDir: smapiDir, customModsDir: customModsDir)
        var loaded = CollectionStorage.manifests(in: root).map { manifest, folder -> ModEntry in
            let relative = folder.path.replacingOccurrences(of: root.path + "/", with: "")
            let parts = relative.split(separator: "/")
            let legacySource = parts.count >= 2 && parts[0].lowercased() == "collections" ? "legacy_\(parts[1])" : nil
            return ModEntry(manifest: manifest, folderPath: folder.path, sourceID: legacySource)
        }
        if !didMigrateLegacyCollections && !profileStoreUnreadable && loaded.contains(where: { $0.sourceID?.hasPrefix("legacy_") == true }) {
            do {
                if collectionManager.activeIDs.isEmpty && !collectionManager.isResolving {
                    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    try LegacyDataMigration(applicationSupport: support).backup(profilesFileURL)
                    let imported = try collectionManager.importLegacyInstallations(mods: loaded, profiles: profiles)
                    if imported.changedProfiles { profiles = imported.profiles; saveProfiles(force: true) }
                    legacyCollectionImportCount += imported.created
                    if !imported.issues.isEmpty { profilePersistenceError = imported.issues.joined(separator: "\n") }
                    didMigrateLegacyCollections = imported.issues.isEmpty && !hasUnsavedProfileChanges
                }
            } catch { profilePersistenceError = "Older collection import will retry: \(error.localizedDescription)" }
        }
        for collection in collectionManager.records {
            // A partially downloaded revision must never displace a playable installed revision.
            guard collection.installedRevision != nil, let path = try? collectionManager.storage.modsDirectory(collection) else { continue }
            loaded.append(contentsOf: CollectionStorage.manifests(in: path).map { ModEntry(manifest: $0.0, folderPath: $0.1.path, sourceID: collection.id) })
        }
        mods = loaded.sorted { $0.manifest.Name.localizedStandardCompare($1.manifest.Name) == .orderedAscending }
        var changed = false
        for profile in profiles.indices {
            let oldCount = profiles[profile].missingMods.count
            profiles[profile].missingMods.removeAll { missing in
                mods.contains { $0.id.caseInsensitiveCompare(missing.uniqueID) == .orderedSame && $0.sourceID == missing.sourceID }
            }
            changed = changed || oldCount != profiles[profile].missingMods.count
            // Pre-source native collection profiles migrate deterministically to their slug's old folder.
            if profiles[profile].isCollectionProfile && profiles[profile].collectionSourceID == nil {
                for id in profiles[profile].enabledModIDs where profiles[profile].modSources[id] == nil {
                    let candidates = Set(mods.filter { $0.id.caseInsensitiveCompare(id) == .orderedSame && $0.sourceID?.hasPrefix("legacy_") == true }.compactMap(\.sourceID))
                    if candidates.count == 1, let source = candidates.first {
                        profiles[profile].modSources[id] = source
                        changed = true
                    } else if candidates.count > 1 {
                        profilePersistenceError = "Multiple older collections contain \(id). Open Collections and choose the intended installed copy; the original files and profile selections have been retained."
                    }
                }
            }
        }
        if changed { saveProfiles() }
    }
    func deleteMod(modID: String, smapiDir: String, customModsDir: String) {
        guard let mod = modsForCurrentProfile.first(where: { $0.id == modID }), mod.sourceID == nil else { return }
        let fileManager = FileManager.default
        do {
            try fileManager.removeItem(atPath: mod.folderPath)
            loadMods(smapiDir: smapiDir, customModsDir: customModsDir)
        } catch {
            print("Failed to delete mod: \(error)")
        }
    }

    nonisolated func installMod(zipURL: URL, smapiDir: String, customModsDir: String, collectionFolder: String? = nil, autoEnableInProfileID: UUID? = nil, cancellationCheck: (() throws -> Void)? = nil) throws {
        let root = getModDirectory(smapiDir: smapiDir, customModsDir: customModsDir)
        let destination: URL
        if let folder = collectionFolder {
            let components = folder.split(separator: "/")
            guard !folder.hasPrefix("/"), !components.contains("..") else { throw CollectionError.invalid("Invalid collection installation path.") }
            destination = components.reduce(root) { $0.appendingPathComponent(String($1), isDirectory: true) }
        } else { destination = root }
        let extractedIDs = try CollectionStorage.installOrdinaryArchive(zipURL, destination: destination, cancellationCheck: { try cancellationCheck?() })
        Task { @MainActor in
            self.loadMods(smapiDir: smapiDir, customModsDir: customModsDir)
            if let profileID = autoEnableInProfileID, let index = self.profiles.firstIndex(where: { $0.id == profileID }), !self.profiles[index].isProtected {
                self.profiles[index].enabledModIDs.formUnion(extractedIDs)
                for id in extractedIDs { self.profiles[index].modSources.removeValue(forKey: id) }
                self.profiles[index].missingMods.removeAll { missing in extractedIDs.contains(where: { $0.caseInsensitiveCompare(missing.uniqueID) == .orderedSame }) }
                self.saveProfiles()
            }
        }
    }
    func checkAllUpdates(nexusClient: NexusClient) async {
        isCheckingUpdates = true
        updateCheckStatus = "Checking updates..."
        defer { isCheckingUpdates = false }

        // Filter mods that actually have update keys (contain a colon like "nexus:...")
        var seenUpdateIDs = Set<String>()
        let modsWithUpdateKeys = mods.filter { mod in
            guard mod.sourceID == nil, seenUpdateIDs.insert(mod.id.lowercased()).inserted, let keys = mod.manifest.UpdateKeys else { return false }
            return keys.contains(where: { $0.contains(":") })
        }

        guard !modsWithUpdateKeys.isEmpty else {
            updateCheckStatus = "No installed mods have update keys."
            for index in mods.indices {
                mods[index].hasUpdate = false
                mods[index].suggestedVersion = nil
                mods[index].suggestedUpdateURL = nil
            }
            return
        }

        let searchEntries = modsWithUpdateKeys.map { mod in
            SMAPIModSearchEntry(
                Id: mod.id,
                InstalledVersion: mod.manifest.Version,
                UpdateKeys: mod.manifest.UpdateKeys ?? []
            )
        }

        let searchData = SMAPIModSearchData(
            Mods: searchEntries,
            ApiVersion: "4.0.8",
            GameVersion: "1.6.8",
            Platform: "Mac",
            IncludeExtendedMetadata: true
        )

        guard let url = URL(string: "https://smapi.io/api/v3.0/mods") else {
            updateCheckStatus = "Error: Invalid update API URL."
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Starfruit", forHTTPHeaderField: "Application-Name")
        request.setValue("1.0", forHTTPHeaderField: "Application-Version")

        do {
            let encoder = JSONEncoder()
            let jsonData = try encoder.encode(searchData)
            request.httpBody = jsonData

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                updateCheckStatus = "Error: server returned code \(status)"
                return
            }

            let decoder = JSONDecoder()
            let updates = try decoder.decode([SMAPIModUpdateResponse].self, from: data)

            var updateCount = 0
            for update in updates {
                if update.suggestedUpdate != nil {
                    if let index = mods.firstIndex(where: { $0.id == update.id && $0.sourceID == nil }) {
                        mods[index].suggestedVersion = update.suggestedUpdate?.version
                        let suggestedURL = (update.suggestedUpdate?.url).flatMap(URL.init(string:))
                        mods[index].suggestedUpdateURL = suggestedURL.flatMap { url in
                            ["https", "http"].contains(url.scheme?.lowercased() ?? "") && url.host != nil && url.user == nil && url.password == nil ? url : nil
                        }
                        let ignored = currentProfile?.ignoresUpdate(modID: update.id, version: update.suggestedUpdate?.version) == true
                        mods[index].hasUpdate = true
                        if !ignored { updateCount += 1 }
                    }
                } else {
                    if let index = mods.firstIndex(where: { $0.id == update.id && $0.sourceID == nil }) {
                        mods[index].hasUpdate = false
                        mods[index].suggestedVersion = nil
                mods[index].suggestedUpdateURL = nil
                    }
                }
            }

            // Set mods without updates in response to false
            let updatedIDs = Set(updates.map { $0.id })
            for index in mods.indices {
                if !updatedIDs.contains(mods[index].id) {
                    mods[index].hasUpdate = false
                    mods[index].suggestedVersion = nil
                mods[index].suggestedUpdateURL = nil
                }
            }

            updateCheckStatus = updateCount == 1 ? "1 update available." : "\(updateCount) updates available."
        } catch {
            updateCheckStatus = "Error: \(error.localizedDescription)"
        }
    }

    private func nexusModID(from updateKeys: [String]?) -> Int? {
        guard let nexusKey = updateKeys?.first(where: { $0.lowercased().hasPrefix("nexus:") }) else {
            return nil
        }
        let suffix = nexusKey.dropFirst("Nexus:".count)
        let digits = suffix.prefix { $0.isNumber }
        return Int(digits)
    }

    func handleNXMCollectionURL(_ url: URL, nexusClient: NexusClient, downloadManager: DownloadManager, completion: (() -> Void)? = nil) {
        collectionManager.importCollection(link: url.absoluteString, nexusClient: nexusClient)
        completion?()
    }

    private func collectionDownloadErrorMessage(_ errorMsg: String?) -> String {
        guard let errorMsg, !errorMsg.isEmpty else {
            return "Nexus did not return a download link."
        }
        if errorMsg.contains("HTTP 403") {
            return "Nexus returned HTTP 403. Collection auto-downloads require Nexus Premium; use the manual download link for this file."
        }
        return errorMsg
    }


}

// MARK: - SMAPI.io Update Check Models

struct SMAPIModSearchEntry: Codable {
    let Id: String
    let InstalledVersion: String
    let UpdateKeys: [String]
}

struct SMAPIModSearchData: Codable {
    let Mods: [SMAPIModSearchEntry]
    let ApiVersion: String
    let GameVersion: String
    let Platform: String
    let IncludeExtendedMetadata: Bool
}

struct SMAPISuggestedUpdate: Codable {
    let version: String
    let url: String
}

struct SMAPIModUpdateResponse: Codable {
    let id: String
    let suggestedUpdate: SMAPISuggestedUpdate?
}
