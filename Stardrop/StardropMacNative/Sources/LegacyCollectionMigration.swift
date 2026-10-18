import Foundation

struct LegacyCollectionImport {
    var records: [NativeCollection]
    var profiles: [ModProfile]
    var created = 0
    var changedProfiles = false
    var issues: [String] = []
}

enum LegacyCollectionMigration {
    static func unresolvedModIDs(in profile: ModProfile, mods: [ModEntry]) -> [String] {
        guard profile.isCollectionProfile else { return [] }
        return profile.enabledModIDs.filter { id in
            if profile.modSources.keys.contains(where: { $0.caseInsensitiveCompare(id) == .orderedSame }) { return false }
            if let source = profile.collectionSourceID, mods.contains(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame && $0.sourceID == source }) { return false }
            let copies = mods.filter { $0.id.caseInsensitiveCompare(id) == .orderedSame && $0.sourceID?.hasPrefix("legacy_") == true }
            return Set(copies.compactMap(\.sourceID)).count > 1
        }.sorted()
    }

    /// Imports metadata only. Existing mod folders, versions and config.json
    /// files are neither moved nor changed during the upgrade.
    static func run(mods: [ModEntry], profiles: [ModProfile], storage: CollectionStorage) throws -> LegacyCollectionImport {
        var result = LegacyCollectionImport(records: storage.load(), profiles: profiles)
        let groups = Dictionary(grouping: mods.filter { $0.sourceID?.hasPrefix("legacy_") == true }, by: { $0.sourceID! })
        var mappings: [String: String] = [:]
        for source in groups.keys.sorted() {
            let slug = String(source.dropFirst("legacy_".count))
            guard !slug.isEmpty, slug.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
                  let entries = groups[source], !entries.isEmpty else { continue }
            let id = "stardewvalley-\(slug)"
            if let existing = result.records.first(where: { $0.id == id }) {
                if existing.isLegacyImport && !existing.isDetached { mappings[source] = id }
                continue // A managed or intentionally detached collection belongs to the new installation.
            }
            let catalog = try storage.directory(id)
            if FileManager.default.fileExists(atPath: catalog.path),
               !(try FileManager.default.contentsOfDirectory(atPath: catalog.path)).isEmpty {
                result.issues.append("The existing collection record for \(slug) could not be read and has not been replaced. Restore its record or choose another storage folder before retrying.")
                continue
            }
            guard let first = entries.first, let root = legacyRoot(for: first.folderPath, slug: slug) else { continue }
            let installed = entries.sorted { $0.folderPath < $1.folderPath }.map { mod in
                NativeCollectionEntry(id: LegacyDataMigration.stableID(mod.folderPath).uuidString,
                    name: mod.manifest.Name, version: mod.manifest.Version, author: mod.manifest.Author,
                    optional: false, selected: true, phase: 0, source: .bundle,
                    fileExpression: nil, logicalFilename: nil, status: .installed,
                    installedMods: [CollectionModReference(uniqueID: mod.id,
                        folder: String(URL(fileURLWithPath: mod.folderPath).standardizedFileURL.path.dropFirst(root.path.count + 1)))])
            }
            let record = NativeCollection(id: id, slug: slug, name: "Imported Collection: \(slug)",
                summary: "Imported from an older Starfruit installation. Existing files and settings are unchanged.",
                instructions: "The older app did not record the installed Nexus revision or exact download IDs. Your installed copy remains usable. Review a Nexus revision before upgrading; no update is installed automatically.",
                revision: 0, installedRevision: 0, latestRevision: nil, entries: installed, rules: [],
                legacyModsDirectory: root.path)
            try storage.save(record)
            result.records.append(record)
            result.created += 1
            mappings[source] = id
        }
        for index in result.profiles.indices {
            for (modID, source) in result.profiles[index].modSources {
                if let mapped = mappings[source] {
                    result.profiles[index].modSources[modID] = mapped
                    result.changedProfiles = true
                }
            }
            guard result.profiles[index].isCollectionProfile, result.profiles[index].collectionSourceID == nil else { continue }
            let enabled = Set(result.profiles[index].enabledModIDs.map { $0.lowercased() }.filter {
                !["smapi.consolecommands", "smapi.savebackup"].contains($0)
            })
            let explicit = Set(result.profiles[index].modSources.values)
            let explicitCandidates = explicit.intersection(Set(mappings.values))
            let candidates = explicitCandidates.isEmpty ? mappings.values.filter { id in
                guard let record = result.records.first(where: { $0.id == id }) else { return false }
                let ids = Set(record.entries.flatMap(\.installedMods).map { $0.uniqueID.lowercased() })
                return !enabled.isEmpty && enabled.isSubset(of: ids)
            } : Array(explicitCandidates)
            if candidates.count == 1, let id = candidates.first {
                result.profiles[index].collectionSourceID = id
                for modID in result.profiles[index].enabledModIDs where result.profiles[index].modSources[modID] == nil {
                    if result.records.first(where: { $0.id == id })?.entries.flatMap(\.installedMods).contains(where: { $0.uniqueID.caseInsensitiveCompare(modID) == .orderedSame }) == true {
                        result.profiles[index].modSources[modID] = id
                    }
                }
                if let record = result.records.first(where: { $0.id == id }), record.name == "Imported Collection: \(record.slug)" {
                    var named = record
                    let name = result.profiles[index].name
                    named.name = name.hasPrefix("Collection: ") ? String(name.dropFirst("Collection: ".count)) : name
                    try storage.save(named)
                    if let recordIndex = result.records.firstIndex(where: { $0.id == id }) { result.records[recordIndex] = named }
                }
                result.changedProfiles = true
            } else if candidates.count > 1 {
                result.issues.append("More than one old collection matches \(result.profiles[index].name). Both installations were retained; select the intended collection before playing.")
            }
        }
        return result
    }

    private static func legacyRoot(for path: String, slug: String) -> URL? {
        var url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        while url.path != "/" {
            if url.lastPathComponent == slug && url.deletingLastPathComponent().lastPathComponent.lowercased() == "collections" { return url }
            url.deleteLastPathComponent()
        }
        return nil
    }
}
