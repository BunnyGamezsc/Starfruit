import Foundation
import CryptoKit

/// Collection payloads live in Application Support, never inside the game's ordinary Mods directory.
struct CollectionStorage: Sendable {
    let root: URL

    init(root: URL? = nil) {
        self.root = root ?? UserDefaults.standard.string(forKey: "nativeCollectionStorageRoot").flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("StarfruitNative/Collections", isDirectory: true)
    }

    func relocated(to target: URL) throws -> CollectionStorage {
        let manager = FileManager.default
        let old = root.standardizedFileURL.resolvingSymlinksInPath()
        let new = target.standardizedFileURL.resolvingSymlinksInPath()
        if old == new { return self }
        guard !new.path.hasPrefix(old.path + "/"), !old.path.hasPrefix(new.path + "/") else { throw CollectionError.invalid("Choose a separate collection storage folder.") }
        if manager.fileExists(atPath: new.path), !(try manager.contentsOfDirectory(atPath: new.path)).isEmpty { throw CollectionError.invalid("The new collection storage folder must be empty.") }
        let candidate = new.deletingLastPathComponent().appendingPathComponent(".StarfruitCollectionMove-\(UUID().uuidString)")
        try manager.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: candidate) }
        if manager.fileExists(atPath: old.path) { try manager.copyItem(at: old, to: candidate) }
        else { try manager.createDirectory(at: candidate, withIntermediateDirectories: true) }
        if manager.fileExists(atPath: new.path) { try manager.removeItem(at: new) }
        try manager.moveItem(at: candidate, to: new)
        return CollectionStorage(root: new)
    }

    func directory(_ id: String) throws -> URL {
        guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else {
            throw CollectionError.invalid("Invalid collection identifier.")
        }
        return root.appendingPathComponent(id, isDirectory: true)
    }

    func modsDirectory(_ collection: NativeCollection, pending: Bool = false) throws -> URL {
        if !pending, collection.hasLegacyInstalledCopy, let path = collection.legacyModsDirectory {
            let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            guard path.hasPrefix("/"), url.pathComponents.dropLast().last?.lowercased() == "collections",
                  url.lastPathComponent.caseInsensitiveCompare(collection.slug) == .orderedSame else {
                throw CollectionError.invalid("The imported collection location is invalid.")
            }
            return url
        }
        let revision = pending ? collection.revision : collection.installedRevision ?? collection.revision
        return try directory(collection.id).appendingPathComponent("revisions/\(revision)/Mods", isDirectory: true)
    }

    func revisionDirectory(_ collection: NativeCollection) throws -> URL {
        try directory(collection.id).appendingPathComponent("revisions/\(collection.revision)", isDirectory: true)
    }

    func load() -> [NativeCollection] {
        guard let directories = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return directories.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("record.json")),
                  let record = try? JSONDecoder().decode(NativeCollection.self, from: data),
                  (try? directory(record.id))?.standardizedFileURL == folder.standardizedFileURL else { return nil }
            return record
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func save(_ collection: NativeCollection) throws {
        let directory = try directory(collection.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(collection).write(to: directory.appendingPathComponent("record.json"), options: .atomic)
    }

    func remove(_ id: String) throws {
        let path = try directory(id)
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }

    static func checksum(_ archive: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        var digest = Insecure.MD5()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { digest.update(data: data) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func manifests(in root: URL) -> [(ModManifest, URL)] {
        var pending = [root]
        var result: [(ModManifest, URL)] = []
        while let directory = pending.popLast() {
            guard let children = try? FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey], options: [.skipsHiddenFiles]) else { continue }
            if let url = children.first(where: { $0.lastPathComponent.lowercased() == "manifest.json" }),
               let data = try? Data(contentsOf: url),
               let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
               let cleaned = cleanManifestJSON(text).data(using: .utf8),
               let manifest = try? JSONDecoder().decode(ModManifest.self, from: cleaned) {
                result.append((manifest, directory))
                continue // A mod's internal manifests are data; do not discover them as separate installs.
            }
            for child in children.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
                guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]),
                      values.isDirectory == true, values.isSymbolicLink != true, values.isPackage != true else { continue }
                pending.append(child)
            }
        }
        return result
    }

    static func cleanManifestJSON(_ text: String) -> String {
        let chars = Array(text)
        var result = ""
        var index = 0
        var inString = false
        var escaped = false
        while index < chars.count {
            let char = chars[index]
            if inString {
                result.append(char)
                if escaped { escaped = false }
                else if char == "\\" { escaped = true }
                else if char == "\"" { inString = false }
                index += 1
                continue
            }
            if char == "\"" { inString = true; result.append(char); index += 1; continue }
            if char == "/", index + 1 < chars.count, chars[index + 1] == "/" {
                while index < chars.count && chars[index] != "\n" { index += 1 }
                continue
            }
            if char == "/", index + 1 < chars.count, chars[index + 1] == "*" {
                index += 2
                while index + 1 < chars.count && !(chars[index] == "*" && chars[index + 1] == "/") { index += 1 }
                index = min(chars.count, index + 2)
                result.append(" ")
                continue
            }
            if char == "," {
                var next = index + 1
                while next < chars.count && chars[next].isWhitespace { next += 1 }
                if next < chars.count && (chars[next] == "}" || chars[next] == "]") { index += 1; continue }
            }
            result.append(char)
            index += 1
        }
        return result
    }

    /// Preserve config.json for surviving mods and unpinned add-ons/dropped copies when requested.
    static func preserveUserFiles(previous: URL, destination: URL, includeRemovedMods: Bool, retainedIDs: Set<String> = [], priorPinnedIDs: Set<String> = []) throws {
        let previousMods = manifests(in: previous)
        let currentMods = Dictionary(manifests(in: destination).map { ($0.0.UniqueID.lowercased(), $0.1) }, uniquingKeysWith: { first, _ in first })
        for (manifest, folder) in previousMods {
            let id = manifest.UniqueID.lowercased()
            if let current = currentMods[id] {
                let config = folder.appendingPathComponent("config.json")
                if FileManager.default.fileExists(atPath: config.path) {
                    let target = current.appendingPathComponent("config.json")
                    if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                    try FileManager.default.copyItem(at: config, to: target)
                }
            } else if includeRemovedMods || retainedIDs.contains(id) || !priorPinnedIDs.contains(id) {
                // Add-ons are user-owned even when removing obsolete curator pins was requested.
                let target = destination.appendingPathComponent("Retained/" + (try NativeArchiveInstaller.safeFolderName(manifest.UniqueID)), isDirectory: true)
                try mergeDirectory(folder, into: target)
            }
        }
    }

    static func compose(_ collection: NativeCollection, revisionRoot: URL, into candidate: URL, previous: URL?, retainedIDs: Set<String> = [], cancelled: () -> Bool = { false }) throws -> [String: [CollectionModReference]] {
        var installed: [String: [CollectionModReference]] = [:]
        var overlays: [URL] = []
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        for entryID in try collection.orderedEntryIDs() {
            if cancelled() { throw CancellationError() }
            let payload = revisionRoot.appendingPathComponent("Payloads/\(entryID)", isDirectory: true)
            guard FileManager.default.fileExists(atPath: payload.path) else { throw CollectionError.invalid("A staged file is missing. Retry the collection installation.") }
            let found = manifests(in: payload)
            if found.isEmpty { overlays.append(payload); continue }
            var references: [CollectionModReference] = []
            for (manifest, folder) in found {
                _ = try NativeArchiveInstaller.safeFolderName(manifest.UniqueID)
                var relative = try NativeArchiveInstaller.safeFolderName(folder == payload ? "Mod-\(entryID)" : folder.lastPathComponent)
                for (oldManifest, oldFolder) in manifests(in: candidate) where oldManifest.UniqueID.caseInsensitiveCompare(manifest.UniqueID) == .orderedSame && oldFolder.lastPathComponent != relative {
                    try FileManager.default.removeItem(at: oldFolder)
                }
                let collision = candidate.appendingPathComponent(relative, isDirectory: true)
                if let existing = manifests(in: collision).first, existing.0.UniqueID.caseInsensitiveCompare(manifest.UniqueID) != .orderedSame {
                    relative = try NativeArchiveInstaller.safeFolderName(manifest.UniqueID)
                }
                try mergeDirectory(folder, into: candidate.appendingPathComponent(relative, isDirectory: true))
                references.append(CollectionModReference(uniqueID: manifest.UniqueID, folder: relative))
            }
            installed[entryID] = references
        }
        if let previous {
            let priorPinnedIDs = Set((collection.previousEntries ?? collection.entries).flatMap(\.installedMods).map { $0.uniqueID.lowercased() })
            try preserveUserFiles(previous: previous, destination: candidate, includeRemovedMods: collection.preserveRemovedMods, retainedIDs: retainedIDs, priorPinnedIDs: priorPinnedIDs)
        }
        // Curator overlays deliberately win over restored user configuration, in their resolved rule order.
        for overlay in overlays {
            if cancelled() { throw CancellationError() }
            try mergeDirectory(overlay, into: candidate)
        }
        if cancelled() { throw CancellationError() }
        return installed
    }

    static func stageBundleDirectory(_ source: URL, into payload: URL) throws {
        let children = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        let hasManifest = children.contains { $0.lastPathComponent.caseInsensitiveCompare("manifest.json") == .orderedSame }
        let hasSubfolders = children.contains { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        let target = hasManifest || !hasSubfolders ? payload.appendingPathComponent(try NativeArchiveInstaller.safeFolderName(source.lastPathComponent)) : payload
        try mergeDirectory(source, into: target)
    }

    static func stagePayload(_ archive: URL, entry: NativeCollectionEntry, into payload: URL, cancelled: () -> Bool = { false }) throws {
        if cancelled() { throw CancellationError() }
        let values = try archive.resourceValues(forKeys: [.isDirectoryKey])
        if values.isDirectory == true { try stageBundleDirectory(archive, into: payload) }
        else {
            let looseTypes: Set<String> = ["json", "dll", "png", "xnb", "txt", "yaml", "yml", "toml", "ini", "xml"]
            let logicalIsLoose = entry.logicalFilename.map { looseTypes.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) } ?? false
            let sourceName = entry.source == .bundle ? archive.lastPathComponent : logicalIsLoose ? entry.logicalFilename! : entry.url?.lastPathComponent ?? entry.logicalFilename ?? archive.lastPathComponent
            let actualType = archive.pathExtension.lowercased()
            let sourceType = URL(fileURLWithPath: sourceName).pathExtension.lowercased()
            if NativeArchiveInstaller.supportedExtensions.contains(actualType) || NativeArchiveInstaller.supportedExtensions.contains(sourceType) || (actualType == "archive" && !looseTypes.contains(sourceType)) {
                try NativeArchiveInstaller.extract(archive, to: payload, cancelled: cancelled)
            } else {
                let filename = try NativeArchiveInstaller.safeFolderName(sourceName)
                try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: archive, to: payload.appendingPathComponent(filename))
            }
        }
        for (manifest, _) in manifests(in: payload) { _ = try NativeArchiveInstaller.safeFolderName(manifest.UniqueID) }
        if cancelled() { throw CancellationError() }
    }

    /// Replace ordinary mod folders as a transaction: obsolete files disappear and cancellation rolls back.
    static func installOrdinaryArchive(_ archive: URL, destination: URL, protectedModIDs: Set<String> = [], cancellationCheck: () throws -> Void = {}) throws -> [String] {
        try cancellationCheck()
        let manager = FileManager.default
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        let transaction = destination.appendingPathComponent(".Starfruit-Install-\(UUID().uuidString)", isDirectory: true)
        let payload = transaction.appendingPathComponent("Payload", isDirectory: true)
        let prepared = transaction.appendingPathComponent("Prepared", isDirectory: true)
        let backups = transaction.appendingPathComponent("Backups", isDirectory: true)
        defer { try? manager.removeItem(at: transaction) }
        try NativeArchiveInstaller.extract(archive, to: payload)
        try cancellationCheck()
        let found = manifests(in: payload)
        guard !found.isEmpty else { throw CollectionError.invalid("No SMAPI mod manifest was found in this archive.") }
        guard !found.contains(where: { protectedModIDs.contains($0.0.UniqueID.lowercased()) }) else {
            throw CollectionError.invalid("This add-on would replace a mod pinned by the installed collection revision. Copy the collection profile and install that version normally instead.")
        }
        try manager.createDirectory(at: prepared, withIntermediateDirectories: true)
        try manager.createDirectory(at: backups, withIntermediateDirectories: true)
        let legacyRoot = destination.appendingPathComponent("Collections", isDirectory: true).path.lowercased() + "/"
        let existing = manifests(in: destination).filter { !$0.1.path.lowercased().hasPrefix(legacyRoot) }
        var operations: [(prepared: URL, target: URL, originals: [URL])] = []
        var used = Set<String>()
        for (manifest, folder) in found {
            _ = try NativeArchiveInstaller.safeFolderName(manifest.UniqueID)
            var name = try NativeArchiveInstaller.safeFolderName(folder == payload ? manifest.UniqueID : folder.lastPathComponent)
            let old = existing.filter { $0.0.UniqueID.caseInsensitiveCompare(manifest.UniqueID) == .orderedSame }
            let initialTarget = destination.appendingPathComponent(name)
            if existing.contains(where: { $0.1.standardizedFileURL.path.caseInsensitiveCompare(initialTarget.standardizedFileURL.path) == .orderedSame && $0.0.UniqueID.caseInsensitiveCompare(manifest.UniqueID) != .orderedSame }) || !used.insert(name.lowercased()).inserted {
                name = manifest.UniqueID
                guard used.insert(name.lowercased()).inserted else { throw CollectionError.invalid("The archive contains duplicate mod identifiers.") }
                let fallback = destination.appendingPathComponent(name)
                guard !existing.contains(where: { $0.1.standardizedFileURL.path.caseInsensitiveCompare(fallback.standardizedFileURL.path) == .orderedSame && $0.0.UniqueID.caseInsensitiveCompare(manifest.UniqueID) != .orderedSame }) else {
                    throw CollectionError.invalid("The mod's folder conflicts with another installed mod. Rename its archive folder before installing.")
                }
            }
            let ready = prepared.appendingPathComponent(UUID().uuidString)
            try mergeDirectory(folder, into: ready)
            if let oldFolder = old.first?.1 {
                let config = oldFolder.appendingPathComponent("config.json")
                if manager.fileExists(atPath: config.path) {
                    let targetConfig = ready.appendingPathComponent("config.json")
                    if manager.fileExists(atPath: targetConfig.path) { try manager.removeItem(at: targetConfig) }
                    try manager.copyItem(at: config, to: targetConfig)
                }
            }
            let target = destination.appendingPathComponent(name)
            var originals = old.map { $0.1 }
            if manager.fileExists(atPath: target.path), !originals.contains(target) { originals.append(target) }
            operations.append((ready, target, originals))
        }
        try cancellationCheck()
        var moved: [(original: URL, backup: URL)] = []
        var written: [URL] = []
        do {
            for operation in operations {
                try cancellationCheck()
                for original in operation.originals where manager.fileExists(atPath: original.path) {
                    let backup = backups.appendingPathComponent(UUID().uuidString)
                    try manager.moveItem(at: original, to: backup)
                    moved.append((original, backup))
                }
                try manager.moveItem(at: operation.prepared, to: operation.target)
                written.append(operation.target)
            }
            try cancellationCheck()
        } catch {
            for target in written.reversed() { try? manager.removeItem(at: target) }
            for move in moved.reversed() { try? manager.moveItem(at: move.backup, to: move.original) }
            throw error
        }
        return found.map { $0.0.UniqueID }
    }

    static func mergeDirectory(_ source: URL, into destination: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        for child in try manager.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw CollectionError.invalid("Symbolic links inside mod archives are not supported.") }
            let target = destination.appendingPathComponent(child.lastPathComponent)
            if values.isDirectory == true {
                try mergeDirectory(child, into: target)
            } else {
                if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
                try manager.copyItem(at: child, to: target)
            }
        }
    }
}

/// Checked extraction shared by ordinary mods and collections. libarchive supports zip, 7z, rar and tar variants.
enum NativeArchiveInstaller {
    static let supportedExtensions: Set<String> = ["zip", "7z", "rar", "tar", "gz", "bz2", "xz", "tgz", "tbz", "tbz2", "txz"]
    static func safeFolderName(_ name: String) throws -> String {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"), !name.contains("\0") else {
            throw CollectionError.invalid("A mod has an unsafe folder identifier.")
        }
        return name
    }

    static func extract(_ archive: URL, to destination: URL, cancelled: () -> Bool = { false }) throws {
        if cancelled() { throw CancellationError() }
        let names = try run(["-tf", archive.path])
        for path in names.split(separator: "\n") {
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
                throw CollectionError.invalid("The archive contains a path outside its destination.")
            }
        }
        if cancelled() { throw CancellationError() }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        _ = try run(["-xf", archive.path, "-C", destination.path, "--no-same-owner"])
        if cancelled() { throw CancellationError() }
        let enumerator = FileManager.default.enumerator(at: destination, includingPropertiesForKeys: [.isSymbolicLinkKey])
        while let file = enumerator?.nextObject() as? URL {
            guard (try file.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
                throw CollectionError.invalid("Symbolic links inside mod archives are not supported.")
            }
        }
    }

    private static func run(_ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments
        process.standardOutput = output
        // Keep diagnostics bounded without risking a full stderr pipe blocking the child process.
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CollectionError.invalid("Archive extraction failed (tar exit \(process.terminationStatus)). The download may be damaged or use an unsupported format.")
        }
        return String(decoding: data, as: UTF8.self)
    }
}
