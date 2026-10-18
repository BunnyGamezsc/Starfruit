import Foundation
import CryptoKit

struct LegacyMigrationReport: Codable {
    var importedProfiles = 0
    var importedPresets = 0
    var copiedFiles = 0
    var retainedProfiles: Int? = nil
    var retainedPresets: Int? = nil
    var issues: [String] = []
    var completed: Bool { issues.isEmpty }
}

/// File-only migration, with explicit roots so tests never touch the user's data.
struct LegacyDataMigration {
    let applicationSupport: URL
    var additionalApplicationSupportRoots: [URL] = []
    var fileManager = FileManager.default
    var destination: URL { applicationSupport.appendingPathComponent("StarfruitNative", isDirectory: true) }
    var stateURL: URL { destination.appendingPathComponent("legacy-import-state-v3.json") }

    private struct State: Codable {
        var importedFiles: Set<String> = []
    }

    func run() -> LegacyMigrationReport {
        var report = LegacyMigrationReport()
        do {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            for name in ["profiles.json", "presets.json"] {
                do {
                    if name == "profiles.json" { report.retainedProfiles = try read([ModProfile].self, at: destination.appendingPathComponent(name))?.count }
                    else { report.retainedPresets = try read([ModPreset].self, at: destination.appendingPathComponent(name))?.count }
                } catch { report.issues.append("Existing \(name) could not be read and has not been replaced: \(error.localizedDescription)") }
            }
            var state: State
            if fileManager.fileExists(atPath: stateURL.path) {
                state = try JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL))
            } else { state = State() }
            for name in ["profiles.json", "presets.json"] {
                do {
                    let count = try importAggregate(name, state: &state)
                    if name == "profiles.json" { report.importedProfiles += count }
                    else { report.importedPresets += count }
                } catch { report.issues.append("Could not import \(name): \(error.localizedDescription)") }
            }
            for folder in profileFolders {
                guard fileManager.fileExists(atPath: folder.path) else { continue }
                do {
                    for file in try fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) where file.pathExtension.lowercased() == "json" {
                        do { report.importedProfiles += try importPortable(file, state: &state) }
                        catch { report.issues.append("Could not import \(file.lastPathComponent): \(error.localizedDescription)") }
                    }
                } catch { report.issues.append("Could not read \(folder.path): \(error.localizedDescription)") }
            }
            // Logs are useful for diagnosis. Wrappers are rebuilt by the new launcher.
            let log = applicationSupport.appendingPathComponent("Starfruit/deeplinks.log")
            let targetLog = destination.appendingPathComponent("deeplinks.log")
            if fileManager.fileExists(atPath: log.path), !fileManager.fileExists(atPath: targetLog.path) {
                do { try fileManager.copyItem(at: log, to: targetLog); report.copiedFiles += 1 }
                catch { report.issues.append("Could not copy the old log: \(error.localizedDescription)") }
            }
            try write(state, to: stateURL)
        } catch { report.issues.append("Could not save migration progress: \(error.localizedDescription)") }
        return report
    }

    var profileFolders: [URL] {
        ([applicationSupport] + additionalApplicationSupportRoots).flatMap { root in
            ["Starfruit", "Stardrop", "StarfruitNative"].map {
                root.appendingPathComponent("\($0)/Data/Profiles", isDirectory: true)
            }
        }
    }

    func desktopPreferences() throws -> [String: Any] {
        var result: [String: Any] = [:]
        for root in [applicationSupport] + additionalApplicationSupportRoots {
            for name in ["Starfruit", "Stardrop"] {
                let file = root.appendingPathComponent("\(name)/Data/Settings.json")
                guard fileManager.fileExists(atPath: file.path) else { continue }
                guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] else { continue }
                func field(_ key: String) -> Any? { object.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value }
                var values: [String: Any] = [:]
                if let prefix = field("WinePrefixPath") as? String { values["winePrefix"] = prefix }
                if let automatic = field("ShouldAutomaticallySaveProfileChanges") as? Bool { values["automaticallySaveProfileChanges"] = automatic }
                if let path = field("SMAPIFolderPath") as? String {
                    let wine = path.lowercased().hasSuffix(".exe")
                    if wine || path.lowercased().hasSuffix(".dll") {
                        values["useWine"] = wine
                        values[wine ? "wineSmapiDir" : "nativeSmapiDir"] = URL(fileURLWithPath: path).deletingLastPathComponent().path
                        if let mods = field("ModFolderPath") as? String { values[wine ? "wineModsDir" : "nativeModsDir"] = mods }
                    }
                }
                if let name = field("LastSelectedProfileName") as? String {
                    let matching = try (read([ModProfile].self, at: destination.appendingPathComponent("profiles.json")) ?? []).filter {
                        $0.name.caseInsensitiveCompare(name) == .orderedSame || $0.name.lowercased().hasPrefix(name.lowercased() + " (imported")
                    }
                    if matching.count == 1 { values["selectedProfileID"] = matching[0].id.uuidString }
                }
                result = Self.mergingPreferences(current: result, older: [values])
            }
        }
        return result
    }

    private func importAggregate(_ name: String, state: inout State) throws -> Int {
        let target = destination.appendingPathComponent(name)
        let sources = ["Starfruit", "com.starfruit.macnative"].map { applicationSupport.appendingPathComponent("\($0)/\(name)") }
        var imported = 0
        for source in sources where fileManager.fileExists(atPath: source.path) {
            let key = source.standardizedFileURL.path
            guard !state.importedFiles.contains(key) else { continue }
            let input = try Data(contentsOf: source)
            if name == "profiles.json" {
                let raw = try JSONSerialization.jsonObject(with: input) as? [[String: Any]]
                var old = try JSONDecoder().decode([ModProfile].self, from: input)
                for index in old.indices where raw?.indices.contains(index) == true && raw?[index]["id"] == nil {
                    old[index].id = Self.stableID("\(key)#\(index)")
                }
                var current = try read([ModProfile].self, at: target) ?? []
                var seen = Set(current.map(\.id))
                let additions = old.filter { seen.insert($0.id).inserted }
                if !additions.isEmpty {
                    try backup(target)
                    current.append(contentsOf: additions)
                    try write(current, to: target)
                    imported += additions.count
                }
            } else {
                let old = try JSONDecoder().decode([ModPreset].self, from: input)
                var current = try read([ModPreset].self, at: target) ?? []
                var seen = Set(current.map(\.id))
                let additions = old.filter { seen.insert($0.id).inserted }
                if !additions.isEmpty {
                    try backup(target)
                    current.append(contentsOf: additions)
                    try write(current, to: target)
                    imported += additions.count
                }
            }
            state.importedFiles.insert(key)
            try write(state, to: stateURL)
        }
        return imported
    }

    private func importPortable(_ source: URL, state: inout State) throws -> Int {
        let key = source.standardizedFileURL.path
        guard !state.importedFiles.contains(key) else { return 0 }
        let data = try Data(contentsOf: source)
        let portable = try SharedProfileManifest.decodePortable(data)
        let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let originalID = raw.first { $0.key.lowercased() == "id" }?.value as? String
        let id = originalID.flatMap(UUID.init(uuidString:)) ?? Self.stableID(key)
        let target = destination.appendingPathComponent("profiles.json")
        var current = try read([ModProfile].self, at: target) ?? []
        let existing = current.contains { $0.id == id }
        if !existing {
            let enabled = portable.enabledMods.filter { $0.isEnabled != false }
            var name = portable.name
            var suffix = 1
            while current.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                name = portable.name + (suffix == 1 ? " (Imported)" : " (Imported \(suffix))")
                suffix += 1
            }
            var profile = ModProfile(id: id, name: name, enabledModIDs: Set(enabled.map(\.uniqueID)))
            profile.modSources = Dictionary(enabled.compactMap { mod in mod.sourceID.map { (mod.uniqueID, $0) } }, uniquingKeysWith: { first, _ in first })
            profile.modNotes = portable.notes ?? [:]
            profile.preservedModConfigs = portable.preservedModConfigs ?? [:]
            profile.missingMods = portable.enabledMods
            current.append(profile)
            try backup(target)
            try write(current, to: target)
        }
        state.importedFiles.insert(key)
        try write(state, to: stateURL)
        return existing ? 0 : 1
    }

    private func read<T: Decodable>(_ type: T.Type, at url: URL) throws -> T? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    func backup(_ source: URL) throws {
        guard fileManager.fileExists(atPath: source.path) else { return }
        let folder = destination.appendingPathComponent("MigrationBackups/v3", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(source.lastPathComponent)
        if !fileManager.fileExists(atPath: target.path) { try fileManager.copyItem(at: source, to: target) }
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    static func stableID(_ value: String) -> UUID {
        let hex = SHA256.hash(data: Data(value.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        let parts = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { range in
            String(hex[hex.index(hex.startIndex, offsetBy: range.lowerBound)..<hex.index(hex.startIndex, offsetBy: range.upperBound)])
        }
        return UUID(uuidString: parts.joined(separator: "-"))!
    }

    static func mergingPreferences(current: [String: Any], older: [[String: Any]]) -> [String: Any] {
        var result = current
        for domain in older {
            for (key, value) in domain where result[key] == nil && !key.hasPrefix("migration_done_") && key != "nexus-api-key-fallback" {
                result[key] = value
            }
        }
        return result
    }
}
