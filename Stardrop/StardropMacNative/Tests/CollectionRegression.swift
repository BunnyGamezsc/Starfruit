import Foundation

@main
struct CollectionRegression {
    static var assertions = 0
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        assertions += 1
        if try !condition() { throw CollectionError.invalid("Regression failed: \(message)") }
    }
    static func rejects(_ message: String, _ operation: () throws -> Void) throws {
        var rejected = false
        do { try operation() } catch { rejected = true }
        try expect(rejected, message)
    }
    static func entry(_ id: String, name: String? = nil, phase: Int = 0, optional: Bool = false) -> NativeCollectionEntry {
        NativeCollectionEntry(id: id, name: name ?? id, optional: optional, selected: !optional, phase: phase, source: .bundle)
    }
    static func collection(_ entries: [NativeCollectionEntry], rules: [NativeCollectionRule] = []) -> NativeCollection {
        NativeCollection(id: "stardewvalley-fixture", slug: "fixture", name: "Fixture", revision: 2, installedRevision: 1, entries: entries, rules: rules)
    }
    static func write(_ text: String, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    static func mod(_ root: URL, folder: String, id: String, config: String? = nil, extra: String? = nil) throws -> URL {
        let url = root.appendingPathComponent(folder)
        let object = ["Name": folder, "Author": "Fixture", "Version": "1.0", "UniqueID": id]
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: url.appendingPathComponent("manifest.json"))
        if let config { try write(config, at: url.appendingPathComponent("config.json")) }
        if let extra { try write(extra, at: url.appendingPathComponent(extra)) }
        return url
    }
    static func run(_ executable: String, _ arguments: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        try expect(p.terminationStatus == 0, "fixture tool succeeded")
    }
    static func main() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("StarfruitCollectionFixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try models()
        try profiles()
        try storage(temporary)
        try archives(temporary)
        print("Collection/profile/archive regressions passed (\(assertions) assertions; isolated temporary fixtures).")
    }
    static func models() throws {
        let metadata = CollectionRevisionMetadata(slug: "fixture", revisionNumber: 2, name: "Fixture", downloadLink: URL(string: "https://example.invalid/index.zip")!)
        let data = Data(#"{"info":{"domainName":"stardewvalley","installInstructions":"Read this"},"mods":[{"name":"SMAPI","source":{"type":"nexus","modId":2400}},{"name":"Base","version":"1.2.3","source":{"type":"nexus","modId":100,"fileId":101,"md5":"aabb","updatePolicy":"exact","tag":"base"}},{"name":"Optional","optional":true,"source":{"type":"direct","url":"https://example.invalid/optional.zip","tag":"extra"}},{"name":"Overlay","phase":1,"source":{"type":"bundle","fileExpression":"config*","tag":"overlay"}}],"modRules":[{"type":"requires","source":{"tag":"base"},"reference":{"tag":"extra"}},{"type":"after","source":{"tag":"overlay"},"reference":{"tag":"base"}}]}"#.utf8)
        let record = try NativeCollection.readIndex(data, metadata: metadata)
        try expect(record.entries.count == 3, "SMAPI excluded, optional retained")
        try expect(record.entries[0].fileID == 101 && record.entries[0].isPinned, "exact Nexus pin retained")
        try expect(record.entries[1].optional && record.entries[1].selected, "requires selects optional dependency")
        let order = try record.orderedEntryIDs()
        try expect(order.first == record.entries[1].id && order.last == record.entries[2].id, "requires and after ordering")
        let repeated = try NativeCollection.readIndex(data, metadata: metadata)
        try expect(repeated.entries.map(\.id) == record.entries.map(\.id), "durable identities stable")
        try rejects("wrong game rejected") { _ = try NativeCollection.readIndex(Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "stardewvalley", with: "othergame").utf8), metadata: metadata) }
        let a = entry("a"), b = entry("b")
        let rules = [NativeCollectionRule(kind: "before", sourceID: "a", targetID: "b"), NativeCollectionRule(kind: "after", sourceID: "a", targetID: "b")]
        try rejects("rule cycles rejected") { _ = try collection([a,b], rules: rules).orderedEntryIDs() }
        try rejects("selected conflicts rejected") { _ = try collection([a,b], rules: [.init(kind: "conflicts", sourceID: "a", targetID: "b")]).orderedEntryIDs() }
        try rejects("unselected required entry rejected") { _ = try collection([a,entry("b", optional: true)], rules: [.init(kind: "requires", sourceID: "a", targetID: "b")]).orderedEntryIDs() }
        try expect(collection([a,entry("b", optional: true)]).selectedCount == 1, "unselected optional does not block selected count")
        var pinned = entry("pin")
        pinned.checksum = "AABB"; pinned.fileExpression = "Mod-123-1-2.zip"; pinned.logicalFilename = "Mod.zip"; pinned.version = "1.2.3"
        try expect(CollectionReferenceMatcher.matches(pinned, reference: ["fileMD5":"aabb"]), "checksum case insensitive")
        try expect(!CollectionReferenceMatcher.matches(pinned, reference: ["fileMD5":"bad", "fileExpression":"Mod*"]), "exact checksum cannot fuzzy match filename")
        try expect(CollectionReferenceMatcher.matches(pinned, reference: ["fileMD5":"bad", "fileExpression":"Mod*", "versionMatch":"^1.0"]), "fuzzy reference permits version-compatible filename")
        try expect(CollectionReferenceMatcher.glob("Mod-123.zip", "mod-???.zip"), "glob questions and case")
        try expect(!CollectionReferenceMatcher.glob("ModXzip", "Mod.zip"), "glob literal dot")
        try expect(CollectionReferenceMatcher.bundleMatches("Some_Mod.zip", expression: "Some:Mod.zip"), "sanitized bundle filenames")
        try expect(CollectionReferenceMatcher.versionMatches("1.3.0", requirement: ">=1.2 <2.0"), "semver range")
        try expect(!CollectionReferenceMatcher.versionMatches("0.3.0", requirement: "^0.2.1"), "zero major caret bound")
        try expect(CollectionReferenceMatcher.versionMatches("1.2.9", requirement: "1.2.x"), "wildcard semver")
        try expect(!CollectionReferenceMatcher.versionMatches("1.2.0-beta", requirement: ">=1.2.0"), "prerelease ordering")
        let summary = CollectionUpdateSummary(previous: [a,b], updated: [a,entry("c")])
        try expect(summary.unchanged == 1 && summary.added == 1 && summary.removed == 1, "revision diff")
    }
    static func profiles() throws {
        var profile = try JSONDecoder().decode(ModProfile.self, from: Data(#"{"name":"Legacy","enabledModIDs":["A"]}"#.utf8))
        try expect(profile.modSources.isEmpty && profile.preservedModConfigs.isEmpty && !profile.isProtected, "legacy profile defaults")
        let upstream = Data(#"{"Name":"Portable","EnabledModIds":["A",{"UniqueId":"B","SourceId":"stardewvalley-fixture"}],"ModData":[{"UniqueId":"A","Name":"Enabled","Version":"1.2","ModPageUri":"https://www.nexusmods.com/stardewvalley/mods/123"},{"UniqueId":"B","Name":"Pinned","Version":"2.0"},{"UniqueId":"C","Name":"Disabled","Version":"3.0"}],"Notes":[{"UniqueId":"a","Note":"Keep this note"}],"PreservedModConfigs":{"A":{"Enabled":true,"Scale":1.25,"Nested":[null,"yes",3]}}}"#.utf8)
        let portable = try SharedProfileManifest.decodePortable(upstream)
        try expect(portable.enabledMods.count == 3, "disabled portable ModData preserved")
        try expect(portable.enabledMods[2].isEnabled == false, "disabled intent retained")
        try expect(portable.enabledMods[1].sourceID == "stardewvalley-fixture", "portable source identity")
        try expect(portable.enabledMods[0].note == "Keep this note" && portable.enabledMods[0].updateKeys == ["Nexus:123"], "notes and page download metadata")
        let roundTripData = try JSONEncoder().encode(portable)
        let roundTrip = try SharedProfileManifest.decodePortable(roundTripData)
        try expect(roundTrip.preservedModConfigs == portable.preservedModConfigs && roundTrip.enabledMods == portable.enabledMods, "native portable roundtrip lossless")
        let object = try JSONSerialization.jsonObject(with: roundTripData) as! [String: Any]
        try expect((object["PreservedModConfigs"] as? [String: Any])?["A"] is [String: Any], "upstream config values are JSON objects")
        try expect((object["EnabledModIds"] as? [[String:String]])?.count == 2, "upstream exports only enabled refs")
        let legacy = try SharedProfileManifest.decodePortable(Data(#"{"format":"starfruit.profile.v1","name":"Old export","exportedAt":0,"enabledMods":[{"uniqueID":"Missing","name":"Missing","version":"1","updateKeys":[] }]}"#.utf8))
        try expect(legacy.enabledMods[0].isEnabled == nil, "old share exports stay readable")
        profile.missingMods = portable.enabledMods
        profile.modNotes = portable.notes ?? [:]
        profile.preservedModConfigs = portable.preservedModConfigs ?? [:]
        profile.ignoredUpdateVersions = ["a":"1.2.0"]
        let restored = try JSONDecoder().decode(ModProfile.self, from: JSONEncoder().encode(profile))
        try expect(restored == profile && restored.missingModIDs == ["A","B","C"], "missing mod intent, configs, notes persist")
        try expect(profile.ignoresUpdate(modID: "A", version: "1.2.0") && !profile.ignoresUpdate(modID: "A", version: "1.3.0"), "ignore only exact version, case-insensitive ID")
        profile.enabledModIDs = ["A","Addon","Local"]
        profile.modSources = ["A":"pack","B":"pack","Addon":"pack"]
        profile.reconcileCollection(sourceID: "pack", newIDs: ["A","B","New"], previousIDs: ["A","B"])
        try expect(profile.enabledModIDs == ["A","New","Addon","Local"], "revision reconcile preserves disabled state and addons")
        try expect(profile.modNotes == restored.modNotes && profile.preservedModConfigs == restored.preservedModConfigs, "revision preserves profile config and notes")
        var unsaved = restored
        unsaved.enabledModIDs = ["Unsaved.Selection"]
        unsaved.modNotes = ["A":"Unsaved note"]
        let captured: [String: ProfileJSONValue] = ["A":.object(["Speed":.number(2)])]
        let merged = try JSONDecoder().decode([ModProfile].self, from: ModProfile.mergingCapturedConfigs(captured, profileID: restored.id, into: JSONEncoder().encode([restored])))
        try expect(merged[0].preservedModConfigs == captured, "manual-save mode durably merges game config")
        try expect(merged[0].enabledModIDs == restored.enabledModIDs && merged[0].modNotes == restored.modNotes && merged[0].enabledModIDs != unsaved.enabledModIDs, "game config persistence does not save pending selections or notes")
    }
    static func storage(_ root: URL) throws {
        let storage = CollectionStorage(root: root.appendingPathComponent("External Collections"))
        var record = collection([entry("base"),entry("overlay")], rules: [.init(kind: "after", sourceID: "overlay", targetID: "base")])
        record.previousEntries = [entry("removed")]
        record.previousEntries![0].installedMods = [.init(uniqueID: "Removed", folder: "Removed")]
        record.preserveRemovedMods = false
        try storage.save(record)
        try expect(storage.load().first?.entries.map(\.id) == ["base","overlay"], "external storage persistence")
        try rejects("unsafe record ID rejected") { _ = try storage.directory("../outside") }
        for id in [".","..","A/B","A\\B",""] { try rejects("unsafe mod ID rejected") { _ = try NativeArchiveInstaller.safeFolderName(id) } }
        let revision = try storage.revisionDirectory(record)
        let base = revision.appendingPathComponent("Payloads/base")
        _ = try mod(base, folder: "MyMod", id: "Author.MyMod", config: "archive-default")
        try write("curator-overlay", at: revision.appendingPathComponent("Payloads/overlay/MyMod/config.json"))
        let previous = root.appendingPathComponent("Previous")
        _ = try mod(previous, folder: "OldFolder", id: "Author.MyMod", config: "user-setting")
        _ = try mod(previous, folder: "Addon", id: "Author.Addon", config: "addon-setting")
        _ = try mod(previous, folder: "Removed", id: "Removed")
        let composed = root.appendingPathComponent("Composed")
        let refs = try CollectionStorage.compose(record, revisionRoot: revision, into: composed, previous: previous)
        try expect(refs["base"]?.first?.uniqueID == "Author.MyMod", "composition returns source refs")
        let config = try String(contentsOf: composed.appendingPathComponent("MyMod/config.json"), encoding: .utf8)
        try expect(config == "curator-overlay", "curator overlays win over restored user config")
        let ids = Set(CollectionStorage.manifests(in: composed).map { $0.0.UniqueID })
        try expect(ids.contains("Author.Addon") && !ids.contains("Removed"), "addons preserved independently of removed curator mods")
        let retained = root.appendingPathComponent("RetainedComposition")
        _ = try CollectionStorage.compose(record, revisionRoot: revision, into: retained, previous: previous, retainedIDs: ["removed"])
        try expect(CollectionStorage.manifests(in: retained).contains { $0.0.UniqueID == "Removed" }, "dependent profiles retain removed pin")
        let same = root.appendingPathComponent("SameRevision")
        var noOverlay = collection([entry("base")]); noOverlay.preserveRemovedMods = false
        _ = try CollectionStorage.compose(noOverlay, revisionRoot: revision, into: same, previous: previous)
        try expect(try String(contentsOf: same.appendingPathComponent("MyMod/config.json"), encoding: .utf8) == "user-setting", "same-revision recomposition preserves config")
        try rejects("cancel before composition leaves installed revision intact") { _ = try CollectionStorage.compose(record, revisionRoot: revision, into: root.appendingPathComponent("Cancelled"), previous: previous, cancelled: { true }) }
        try expect(FileManager.default.fileExists(atPath: previous.appendingPathComponent("OldFolder/config.json").path), "cancel leaves prior revision")
        _ = try mod(base.appendingPathComponent("MyMod"), folder: "Internal", id: "NotASeparateMod")
        try expect(CollectionStorage.manifests(in: base).count == 1, "manifest discovery prunes nested mods")
        let sourceBundle = root.appendingPathComponent("Bundle/MyMod")
        _ = try mod(root.appendingPathComponent("Bundle"), folder: "MyMod", id: "Bundle.Mod")
        let bundlePayload = root.appendingPathComponent("BundlePayload")
        try CollectionStorage.stageBundleDirectory(sourceBundle, into: bundlePayload)
        try expect(CollectionStorage.manifests(in: bundlePayload).first?.1.lastPathComponent == "MyMod", "bundled mod preserves folder for overlays")
        let looseBundle = root.appendingPathComponent("Loose/MyMod")
        try write("bundled-config", at: looseBundle.appendingPathComponent("config.json"))
        let loosePayload = root.appendingPathComponent("LoosePayload")
        try CollectionStorage.stageBundleDirectory(looseBundle, into: loosePayload)
        try expect(FileManager.default.fileExists(atPath: loosePayload.appendingPathComponent("MyMod/config.json").path), "bundled loose files preserve target folder")
        let checksumFile = root.appendingPathComponent("checksum")
        try write("hello", at: checksumFile)
        try expect(try CollectionStorage.checksum(checksumFile) == "5d41402abc4b2a76b9719d911017c592", "manual matching uses actual MD5")
        let commented = #"{/*comment*/"Name":"URL // intact","Author":"Fixture","Version":"1","UniqueId":"Comments",}"#
        try write(commented, at: root.appendingPathComponent("Commented/manifest.json"))
        try expect(CollectionStorage.manifests(in: root.appendingPathComponent("Commented")).first?.0.Name == "URL // intact", "manifest comments do not corrupt strings")
        let moved = try storage.relocated(to: root.appendingPathComponent("Moved Collections"))
        try expect(moved.load().first?.id == record.id && FileManager.default.fileExists(atPath: try moved.revisionDirectory(record).appendingPathComponent("Payloads/base/MyMod/manifest.json").path), "relocation preserves records and payloads")
        try expect(storage.load().count == 1, "relocation leaves original until caller commits")
        try rejects("relocation cannot recurse into itself") { _ = try storage.relocated(to: storage.root.appendingPathComponent("Nested")) }
        try rejects("relocation cannot overwrite occupied folder") { _ = try storage.relocated(to: moved.root) }
    }
    static func archives(_ root: URL) throws {
        let source = root.appendingPathComponent("ArchiveSource")
        _ = try mod(source, folder: "First", id: "Author.First", config: "archive-default", extra: "new.txt")
        _ = try mod(source, folder: "Second", id: "Author.Second", extra: "new.txt")
        let archive = root.appendingPathComponent("Mods.zip")
        try run("/usr/bin/tar", ["-a", "-cf", archive.path, "-C", source.path, "."])
        let extracted = root.appendingPathComponent("Extracted")
        try NativeArchiveInstaller.extract(archive, to: extracted)
        try expect(CollectionStorage.manifests(in: extracted).count == 2, "actual ZIP archive extracted")
        var extensionless = entry("logical")
        extensionless.logicalFilename = "mod-logical-name-without-extension"
        let staged = root.appendingPathComponent("Extensionless")
        try CollectionStorage.stagePayload(archive, entry: extensionless, into: staged)
        try expect(CollectionStorage.manifests(in: staged).count == 2, "extensionless logical filename still extracts actual archive")
        var direct = entry("loose")
        direct.source = .direct
        direct.url = URL(string: "https://example.invalid/download?id=1")
        direct.logicalFilename = "config.json"
        let looseArchive = root.appendingPathComponent("download.archive")
        try write("{\"Enabled\":true}", at: looseArchive)
        let directPayload = root.appendingPathComponent("DirectPayload")
        try CollectionStorage.stagePayload(looseArchive, entry: direct, into: directPayload)
        try expect(FileManager.default.fileExists(atPath: directPayload.appendingPathComponent("config.json").path), "direct endpoint respects logical loose filename")
        let destination = root.appendingPathComponent("OrdinaryMods")
        _ = try mod(destination, folder: "First", id: "Author.First", config: "saved-user-config", extra: "obsolete.txt")
        _ = try mod(destination, folder: "Second", id: "Author.Second", extra: "old.txt")
        try rejects("cancellation during ordinary replacement rolls back") {
            _ = try CollectionStorage.installOrdinaryArchive(archive, destination: destination, cancellationCheck: {
                if FileManager.default.fileExists(atPath: destination.appendingPathComponent("First/new.txt").path) { throw CancellationError() }
            })
        }
        try expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("First/obsolete.txt").path) && FileManager.default.fileExists(atPath: destination.appendingPathComponent("Second/old.txt").path), "all originals restored after rollback")
        let installed = try CollectionStorage.installOrdinaryArchive(archive, destination: destination)
        try expect(Set(installed) == ["Author.First","Author.Second"], "ordinary archive returns exact IDs")
        try expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("First/obsolete.txt").path), "obsolete files removed")
        try expect(try String(contentsOf: destination.appendingPathComponent("First/config.json"), encoding: .utf8) == "saved-user-config", "ordinary replacement preserves user config")
        let corrupt = root.appendingPathComponent("Corrupt.zip")
        try write("not an archive", at: corrupt)
        try rejects("corrupt download is not installed") { _ = try CollectionStorage.installOrdinaryArchive(corrupt, destination: destination) }
        let unsafeSource = root.appendingPathComponent("UnsafeSource")
        _ = try mod(unsafeSource, folder: "Unsafe", id: "..")
        let unsafe = root.appendingPathComponent("Unsafe.tar")
        try run("/usr/bin/tar", ["-cf",unsafe.path,"-C",unsafeSource.path,"."])
        try rejects("unsafe manifest ID cannot escape ordinary destination") { _ = try CollectionStorage.installOrdinaryArchive(unsafe, destination: destination) }
        try rejects("unsafe manifest ID rejected before collection entry marked installed") { try CollectionStorage.stagePayload(unsafe, entry: entry("unsafe"), into: root.appendingPathComponent("UnsafePayload")) }
        let collectionDestination = root.appendingPathComponent("Collections/fixture/Mods")
        _ = try mod(collectionDestination, folder: "First", id: "Pinned.Mod", config: "pinned-config")
        _ = try CollectionStorage.installOrdinaryArchive(archive, destination: collectionDestination, protectedModIDs: ["pinned.mod"])
        try expect(CollectionStorage.manifests(in: collectionDestination).contains { $0.0.UniqueID == "Pinned.Mod" }, "addon folder collision cannot replace pinned other ID")
        try expect(try String(contentsOf: collectionDestination.appendingPathComponent("First/config.json"), encoding: .utf8) == "pinned-config", "pinned collision preserves original config")
        try rejects("addon cannot replace exact pinned ID") { _ = try CollectionStorage.installOrdinaryArchive(archive, destination: collectionDestination, protectedModIDs: ["author.first"]) }
        let symlinkSource = root.appendingPathComponent("LinkSource")
        try FileManager.default.createDirectory(at: symlinkSource, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlinkSource.appendingPathComponent("outside"), withDestinationURL: root)
        let linkArchive = root.appendingPathComponent("Link.tar")
        try run("/usr/bin/tar", ["-cf",linkArchive.path,"-C",symlinkSource.path,"."])
        try rejects("archive symbolic links rejected") { try NativeArchiveInstaller.extract(linkArchive, to: root.appendingPathComponent("Links")) }
        try expect(NativeArchiveInstaller.supportedExtensions.contains("7z") && NativeArchiveInstaller.supportedExtensions.contains("txz"), "archive policy includes upstream native formats")
    }
}
