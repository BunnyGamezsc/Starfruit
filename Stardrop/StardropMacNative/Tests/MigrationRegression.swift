import Foundation

@main
struct MigrationRegression {
    static var checks = 0
    static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        if try !value() { throw CollectionError.invalid("Migration fixture: \(message)") }
    }
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url)
    }
    static func data(_ string: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(string.utf8).write(to: url)
    }
    static func profiles(_ root: URL) throws -> [ModProfile] {
        try JSONDecoder().decode([ModProfile].self, from: Data(contentsOf: root.appendingPathComponent("StarfruitNative/profiles.json")))
    }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StarfruitMigration-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let native = root.appendingPathComponent("StarfruitNative")
        let legacy = root.appendingPathComponent("Starfruit")
        let currentFile = native.appendingPathComponent("profiles.json")
        let oldFile = legacy.appendingPathComponent("profiles.json")
        let sharedID = UUID()
        var newer = ModProfile(id: sharedID, name: "Edited in new app", enabledModIDs: ["New.Mod"])
        newer.modNotes = ["New.Mod": "keep my edit"]
        let older = ModProfile(id: sharedID, name: "Old name", enabledModIDs: ["Old.Mod"])
        let imported = ModProfile(name: "Old native profile", enabledModIDs: ["Author.Mod"])
        try write([newer], to: currentFile)
        let originalCurrent = try Data(contentsOf: currentFile)
        try write([older, imported], to: oldFile)
        let originalLegacy = try Data(contentsOf: oldFile)
        let preset = ModPreset(name: "Old preset", enabledModIDs: ["Author.Mod"])
        try write([preset], to: legacy.appendingPathComponent("presets.json"))
        let portable = legacy.appendingPathComponent("Data/Profiles/Shared.json")
        try data(#"{"Name":"Shared C#","EnabledModIds":[{"UniqueId":"Missing.Mod","SourceId":"stardewvalley-pack"}],"ModData":[{"UniqueId":"Missing.Mod","Name":"Missing","Version":"1.0"},{"UniqueId":"Disabled.Mod","Name":"Disabled"}],"Notes":[{"UniqueId":"Missing.Mod","Note":"keep note"}],"PreservedModConfigs":{"Missing.Mod":{"Enabled":true}}}"#, to: portable)
        let migration = LegacyDataMigration(applicationSupport: root)
        let first = migration.run()
        try expect(first.completed, "valid migration completes")
        try expect(first.importedProfiles == 2 && first.importedPresets == 1, "native and portable files imported automatically")
        let converted = try profiles(root)
        try expect(converted.count == 3, "existing profiles retained")
        try expect(converted.first(where: { $0.id == sharedID }) == newer, "newer selections and notes win")
        try expect(converted.contains(where: { $0.id == imported.id }), "native UUID retained for selected profile preference")
        let shared = converted.first(where: { $0.name == "Shared C#" })!
        try expect(shared.enabledModIDs == ["Missing.Mod"], "disabled mods not enabled by import")
        try expect(shared.missingMods.count == 2, "missing and disabled metadata retained")
        try expect(shared.modSources["Missing.Mod"] == "stardewvalley-pack", "portable source retained")
        try expect(shared.modNotes["Missing.Mod"] == "keep note", "notes retained")
        try expect(shared.preservedModConfigs["Missing.Mod"] != nil, "config objects retained")
        try expect(try Data(contentsOf: oldFile) == originalLegacy, "legacy source left byte-for-byte unchanged")
        try expect(try Data(contentsOf: native.appendingPathComponent("MigrationBackups/v3/profiles.json")) == originalCurrent, "backup precedes rewrite")
        let second = migration.run()
        try expect(second.importedProfiles == 0 && second.importedPresets == 0, "relaunch imports nothing twice")
        try expect(try profiles(root).count == 3, "no duplicate profiles after retry")
        try FileManager.default.removeItem(at: migration.stateURL)
        try expect(migration.run().importedProfiles == 0, "restart after journal interruption remains idempotent")

        let broken = legacy.appendingPathComponent("Data/Profiles/Broken.json")
        try data("{broken", to: broken)
        let failed = migration.run()
        try expect(!failed.completed && !failed.issues.isEmpty, "malformed source leaves migration retryable")
        try data(#"{"Name":"Recovered","EnabledModIds":["Recovered.Mod"]}"#, to: broken)
        try expect(migration.run().importedProfiles == 1, "only failed source retried after repair")
        try expect(try profiles(root).count == 4, "repaired file creates one profile")

        let corruptRoot = root.appendingPathComponent("corrupt")
        try data("unreadable original", to: corruptRoot.appendingPathComponent("StarfruitNative/profiles.json"))
        try write([imported], to: corruptRoot.appendingPathComponent("Starfruit/profiles.json"))
        let corrupt = LegacyDataMigration(applicationSupport: corruptRoot).run()
        try expect(!corrupt.completed, "corrupted destination is not treated as empty")
        try expect(try String(contentsOf: corruptRoot.appendingPathComponent("StarfruitNative/profiles.json"), encoding: .utf8) == "unreadable original", "corrupted destination not overwritten")

        let preferences = LegacyDataMigration.mergingPreferences(current: ["winePrefix": "new", "useWine": false], older: [
            ["winePrefix": "old", "useWine": true, "wineSmapiDir": "/old/game", "selectedProfileID": imported.id.uuidString,
             "migration_done_old_v2": true, "nexus-api-key-fallback": "fixture-secret"]])
        try expect(preferences["winePrefix"] as? String == "new" && preferences["useWine"] as? Bool == false, "explicit new preferences take priority including false")
        try expect(preferences["wineSmapiDir"] as? String == "/old/game", "old launch settings copied")
        try expect(preferences["selectedProfileID"] as? String == imported.id.uuidString, "selected profile UUID copied")
        try expect(preferences["migration_done_old_v2"] == nil, "old completion marker does not suppress new migration")
        try expect(preferences["nexus-api-key-fallback"] == nil, "plaintext login never copied into new preferences")
        try data(#"{"SMAPIFolderPath":"/old/game/StardewModdingAPI.exe","ModFolderPath":"/old/mods","WinePrefixPath":"/old/prefix","LastSelectedProfileName":"Shared C#","ShouldAutomaticallySaveProfileChanges":false}"#, to: legacy.appendingPathComponent("Data/Settings.json"))
        let desktop = try migration.desktopPreferences()
        try expect(desktop["wineSmapiDir"] as? String == "/old/game" && desktop["wineModsDir"] as? String == "/old/mods", "desktop launcher paths converted to native directory settings")
        try expect(desktop["useWine"] as? Bool == true && desktop["automaticallySaveProfileChanges"] as? Bool == false, "desktop Wine/manual-save settings retained")
        try expect(desktop["selectedProfileID"] as? String == shared.id.uuidString, "desktop last profile selection mapped to imported UUID")
        let configRoot = root.appendingPathComponent("dot-config")
        try data(#"{"Name":"Earlier desktop","EnabledModIds":["Desktop.Mod"]}"#, to: configRoot.appendingPathComponent("Stardrop/Data/Profiles/Desktop.json"))
        let withConfig = LegacyDataMigration(applicationSupport: root, additionalApplicationSupportRoots: [configRoot])
        try expect(withConfig.run().importedProfiles == 1, "earlier desktop config directory imported automatically")

        let noIDRoot = root.appendingPathComponent("no-id")
        try data(#"[{"name":"Old UUID-less","enabledModIDs":["Author.Mod"]}]"#, to: noIDRoot.appendingPathComponent("Starfruit/profiles.json"))
        let noID = LegacyDataMigration(applicationSupport: noIDRoot)
        try expect(noID.run().completed, "old profile without UUID supported")
        let stable = try profiles(noIDRoot)[0].id
        try FileManager.default.removeItem(at: noID.stateURL)
        let noIDRetry = noID.run()
        let stableAgain = try profiles(noIDRoot)[0].id
        try expect(noIDRetry.importedProfiles == 0 && stableAgain == stable, "UUID-less import stable after interrupted journal")

        let backupFailureRoot = root.appendingPathComponent("backup-failure")
        try write([newer], to: backupFailureRoot.appendingPathComponent("StarfruitNative/profiles.json"))
        try write([imported], to: backupFailureRoot.appendingPathComponent("Starfruit/profiles.json"))
        try data("blocks backup folder creation", to: backupFailureRoot.appendingPathComponent("StarfruitNative/MigrationBackups"))
        let backupFailure = LegacyDataMigration(applicationSupport: backupFailureRoot)
        try expect(!backupFailure.run().completed, "backup failure leaves migration retryable")
        try expect(try profiles(backupFailureRoot) == [newer], "profile not changed when backup cannot be created")
        try FileManager.default.removeItem(at: backupFailureRoot.appendingPathComponent("StarfruitNative/MigrationBackups"))
        try expect(backupFailure.run().importedProfiles == 1, "backup failure recovers on next attempt")

        let game = root.appendingPathComponent("game/Mods/Collections/pack")
        let modFolder = game.appendingPathComponent("ExampleMod")
        let manifest = #"{"Name":"Example","Author":"Author","Version":"2.3","UniqueID":"Author.Mod"}"#
        try data(manifest, to: modFolder.appendingPathComponent("manifest.json"))
        try data(#"{"UserSetting":42}"#, to: modFolder.appendingPathComponent("config.json"))
        let model = try JSONDecoder().decode(ModManifest.self, from: Data(manifest.utf8))
        let mod = ModEntry(manifest: model, folderPath: modFolder.path, sourceID: "legacy_pack")
        var oldProfile = ModProfile(name: "Collection: My Pack", enabledModIDs: ["Author.Mod"], isCollectionProfile: true)
        oldProfile.modNotes = ["Author.Mod": "old note"]
        let storage = CollectionStorage(root: root.appendingPathComponent("catalog"))
        let collectionImport = try LegacyCollectionMigration.run(mods: [mod], profiles: [oldProfile], storage: storage)
        try expect(collectionImport.created == 1 && collectionImport.changedProfiles, "installed old collection recognized automatically")
        let record = collectionImport.records[0]
        try expect(record.isLegacyImport && record.installedRevision == 0, "unknown original revision explicitly distinguished")
        try expect(record.entries[0].fileID == nil && record.entries[0].modID == nil, "does not invent Nexus file pins")
        try expect(record.name == "My Pack", "old profile name retained in collection manager")
        try expect(try storage.modsDirectory(record).path == game.path, "existing files used without copying or redownloading")
        try expect(collectionImport.profiles[0].id == oldProfile.id && collectionImport.profiles[0].enabledModIDs == oldProfile.enabledModIDs, "old profile identity and mod choices retained")
        try expect(collectionImport.profiles[0].modSources["Author.Mod"] == record.id, "physical collection source attached")
        try expect(collectionImport.profiles[0].modNotes == oldProfile.modNotes, "old per-mod notes retained")
        try expect(try String(contentsOf: modFolder.appendingPathComponent("config.json"), encoding: .utf8) == #"{"UserSetting":42}"#, "existing mod configuration untouched")
        try expect(!record.pageURL.path.contains("revisions/0"), "does not link to fictional Nexus revision")
        let again = try LegacyCollectionMigration.run(mods: [mod], profiles: collectionImport.profiles, storage: storage)
        try expect(again.created == 0 && !again.changedProfiles, "collection import repeat-safe")
        var pending = record
        pending.revision = 8
        try expect(try storage.modsDirectory(pending).path == game.path, "old install remains playable during revision review")
        try expect(try storage.modsDirectory(pending, pending: true).path != game.path, "new revision staged separately")
        pending.installedRevision = 8
        let managedPath = try storage.modsDirectory(pending)
        try expect(!pending.isLegacyImport && managedPath.path != game.path, "completed update switches to managed storage")

        let otherMod = ModEntry(manifest: model, folderPath: root.appendingPathComponent("game/Mods/Collections/other/ExampleMod").path, sourceID: "legacy_other")
        let ambiguousStorage = CollectionStorage(root: root.appendingPathComponent("ambiguous"))
        let ambiguous = try LegacyCollectionMigration.run(mods: [mod, otherMod], profiles: [oldProfile], storage: ambiguousStorage)
        try expect(ambiguous.records.count == 2 && !ambiguous.issues.isEmpty, "ambiguous copies both retained and reported")
        try expect(ambiguous.profiles[0].collectionSourceID == nil && ambiguous.profiles[0].modSources.isEmpty, "ambiguous mod versions never guessed")
        try expect(LegacyCollectionMigration.unresolvedModIDs(in: ambiguous.profiles[0], mods: [mod, otherMod]) == ["Author.Mod"], "ambiguous selection blocks launching rather than loading no mods or the wrong copy")
        oldProfile.modSources["Author.Mod"] = "legacy_other"
        try expect(LegacyCollectionMigration.unresolvedModIDs(in: oldProfile, mods: [mod, otherMod]).isEmpty, "explicit copy resolves the launch guard")
        let explicit = try LegacyCollectionMigration.run(mods: [mod, otherMod], profiles: [oldProfile], storage: ambiguousStorage)
        try expect(explicit.profiles[0].collectionSourceID == "stardewvalley-other", "explicit source wins over matching ID sets")
        var detached = record
        detached.isDetached = true
        try storage.save(detached)
        let detachedImport = try LegacyCollectionMigration.run(mods: [mod], profiles: [], storage: storage)
        try expect(detachedImport.created == 0 && detachedImport.records[0].isDetached, "user removal is not undone on restart")
        let corruptCatalog = CollectionStorage(root: root.appendingPathComponent("corrupt-catalog"))
        let corruptRecord = try corruptCatalog.directory("stardewvalley-pack").appendingPathComponent("record.json")
        try data("unreadable newer record", to: corruptRecord)
        let protectedCatalog = try LegacyCollectionMigration.run(mods: [mod], profiles: [oldProfile], storage: corruptCatalog)
        try expect(protectedCatalog.created == 0 && !protectedCatalog.issues.isEmpty, "unreadable destination catalog does not look like an empty catalog")
        try expect(try String(contentsOf: corruptRecord, encoding: .utf8) == "unreadable newer record", "unreadable newer collection data not replaced")
        try data(#"{"Name":"Edited in new app","EnabledModIds":["Different.OldMod"]}"#, to: legacy.appendingPathComponent("Data/Profiles/SameName.json"))
        try expect(migration.run().importedProfiles == 1, "different old profile is not silently discarded on a name collision")
        let collisionProfiles = try profiles(root)
        try expect(collisionProfiles.first(where: { $0.id == sharedID }) == newer, "name collision does not change the new profile")
        try expect(collisionProfiles.contains(where: { $0.name == "Edited in new app (Imported)" && $0.enabledModIDs == ["Different.OldMod"] }), "name collision imports a separate named recovery copy")
        try expect(migration.run().importedProfiles == 0, "name-collision copy is not duplicated on retry")
        print("Migration regressions passed (\(checks) assertions; temporary files and pure preferences only).")
    }
}
