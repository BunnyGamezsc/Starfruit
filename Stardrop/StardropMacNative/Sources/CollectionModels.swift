import Foundation
import CryptoKit

struct CollectionRevisionMetadata: Codable, Sendable {
    var slug: String
    var revisionNumber: Int
    var name: String
    var summary: String?
    var curator: String?
    var downloadLink: URL
}

enum CollectionEntryStatus: String, Codable, Sendable {
    case pending, downloading, manual, installed, failed, skipped, cancelled
}

enum CollectionEntrySource: String, Codable, Sendable {
    case nexus, direct, browse, bundle
}

struct CollectionModReference: Codable, Hashable, Sendable {
    var uniqueID: String
    var folder: String
}

struct NativeCollectionEntry: Identifiable, Codable, Sendable {
    var id: String
    var name: String
    var version: String?
    var author: String?
    var optional: Bool
    var selected: Bool
    var phase: Int
    var source: CollectionEntrySource
    var modID: Int?
    var fileID: Int?
    var url: URL?
    var checksum: String?
    var fileExpression: String?
    var logicalFilename: String?
    var tag: String?
    var updatePolicy: String?
    var size: Int64?
    var status: CollectionEntryStatus = .pending
    var failure: String?
    var installedMods: [CollectionModReference] = []
    var isPinned: Bool { updatePolicy?.lowercased() == "exact" }
    var satisfied: Bool { !selected || status == .installed || status == .skipped }
    func canReusePayload(from previous: NativeCollectionEntry) -> Bool {
        // A bundle's expression identifies a path in its revision archive, not its contents.
        source != .bundle && id == previous.id && previous.status == .installed
    }
    var pageURL: URL? {
        if let modID, let fileID {
            return URL(string: "https://www.nexusmods.com/stardewvalley/mods/\(modID)?tab=files&file_id=\(fileID)&nmm=1")
        }
        return url
    }
}

struct NativeCollectionRule: Codable, Sendable {
    var kind: String
    var sourceID: String
    var targetID: String
}

struct NativeCollection: Identifiable, Codable, Sendable {
    var id: String
    var slug: String
    var name: String
    var summary: String?
    var curator: String?
    var instructions: String?
    var revision: Int
    var installedRevision: Int?
    var latestRevision: Int?
    var entries: [NativeCollectionEntry]
    var rules: [NativeCollectionRule]
    var previousEntries: [NativeCollectionEntry]? = nil
    /// Older Starfruit did not save revision/file pins. Keep its installed files
    /// in place until the user explicitly reviews a real Nexus revision.
    var legacyModsDirectory: String? = nil
    var preserveRemovedMods: Bool = true
    var isDetached: Bool = false
    var updatedAt: Date = Date()
    var completedCount: Int { entries.filter { $0.selected && $0.status == .installed }.count }
    var selectedCount: Int { entries.filter(\.selected).count }
    var isComplete: Bool { entries.allSatisfy(\.satisfied) }
    var hasUpdate: Bool { (latestRevision ?? revision) > revision }
    var hasLegacyInstalledCopy: Bool { installedRevision == 0 && legacyModsDirectory != nil }
    var isLegacyImport: Bool { revision == 0 && hasLegacyInstalledCopy }
    var pageURL: URL {
        let base = "https://www.nexusmods.com/games/stardewvalley/collections/\(slug)"
        return URL(string: isLegacyImport ? base : base + "/revisions/\(revision)")!
    }

    /// Stable phase ordering plus curator before/after dependencies. A cycle must never silently choose winners.
    func orderedEntryIDs() throws -> [String] {
        for rule in rules where rule.kind.lowercased() == "requires" {
            if entries.first(where: { $0.id == rule.sourceID })?.selected == true,
               entries.first(where: { $0.id == rule.targetID })?.selected != true {
                throw CollectionError.invalid("A selected mod requires an optional file that is not selected.")
            }
        }
        let chosen = entries.filter(\.selected)
        let ids = Set(chosen.map(\.id))
        var edges: [String: Set<String>] = [:]
        var incoming = Dictionary(uniqueKeysWithValues: chosen.map { ($0.id, 0) })
        for rule in rules where ids.contains(rule.sourceID) && ids.contains(rule.targetID) {
            let a: String
            let b: String
            switch rule.kind.lowercased() {
            case "before": a = rule.sourceID; b = rule.targetID
            case "after", "requires": a = rule.targetID; b = rule.sourceID
            case "conflicts":
                throw CollectionError.invalid("Conflicting collection entries are selected. Deselect an optional entry before installing.")
            default: continue
            }
            if edges[a, default: []].insert(b).inserted { incoming[b, default: 0] += 1 }
        }
        var result: [String] = []
        var remaining = chosen.sorted { $0.phase == $1.phase ? $0.name < $1.name : $0.phase < $1.phase }
        while !remaining.isEmpty {
            guard let index = remaining.firstIndex(where: { incoming[$0.id] == 0 }) else {
                throw CollectionError.invalid("The collection contains a cycle in its installation rules.")
            }
            let entry = remaining.remove(at: index)
            result.append(entry.id)
            for next in edges[entry.id] ?? [] { incoming[next, default: 0] -= 1 }
        }
        return result
    }

    static func readIndex(_ data: Data, metadata: CollectionRevisionMetadata) throws -> NativeCollection {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mods = json["mods"] as? [[String: Any]] else {
            throw CollectionError.invalid("The collection archive has no valid collection.json mod list.")
        }
        let info = json["info"] as? [String: Any] ?? [:]
        let domain = (info["domainName"] as? String ?? "stardewvalley").lowercased()
        guard domain == "stardewvalley" else { throw CollectionError.invalid("This collection is for a different game.") }
        var entries: [NativeCollectionEntry] = []
        for (index, item) in mods.enumerated() {
            guard let source = item["source"] as? [String: Any] else { continue }
            let typeText = (source["type"] as? String ?? "nexus").lowercased()
            guard let type = CollectionEntrySource(rawValue: typeText) else {
                throw CollectionError.invalid("Unsupported collection source: \(typeText)")
            }
            let modID = int(source["modId"])
            if modID == 2400 { continue } // SMAPI is installed with the game, never as a regular mod.
            let fileID = int(source["fileId"])
            let optional = item["optional"] as? Bool ?? false
            let checksum = source["md5"] as? String
            let expression = source["fileExpression"] as? String
            let identity = "\(typeText):\(modID ?? 0):\(fileID ?? 0):\(checksum ?? expression ?? source["url"] as? String ?? item["name"] as? String ?? "")"
            let baseID = SHA256.hash(data: Data(identity.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
            let id = entries.contains(where: { $0.id == baseID }) ? "\(baseID)-\(index)" : baseID
            entries.append(NativeCollectionEntry(id: id, name: item["name"] as? String ?? "Unnamed mod", version: item["version"] as? String,
                author: item["author"] as? String, optional: optional, selected: !optional, phase: int(item["phase"]) ?? 0,
                source: type, modID: modID, fileID: fileID, url: (source["url"] as? String).flatMap(URL.init(string:)),
                checksum: checksum, fileExpression: expression, logicalFilename: source["logicalFilename"] as? String,
                tag: source["tag"] as? String, updatePolicy: source["updatePolicy"] as? String, size: int(source["fileSize"]).map(Int64.init)))
        }
        func match(_ reference: [String: Any]?) -> String? {
            guard let reference else { return nil }
            return entries.first { CollectionReferenceMatcher.matches($0, reference: reference) }?.id
        }
        let rules = (json["modRules"] as? [[String: Any]] ?? []).compactMap { rule -> NativeCollectionRule? in
            guard let source = match(rule["source"] as? [String: Any]),
                  let target = match(rule["reference"] as? [String: Any]), source != target else { return nil }
            return NativeCollectionRule(kind: rule["type"] as? String ?? "unknown", sourceID: source, targetID: target)
        }
        var collection = NativeCollection(id: "stardewvalley-\(metadata.slug)", slug: metadata.slug,
            name: info["name"] as? String ?? metadata.name, summary: metadata.summary, curator: metadata.curator ?? info["author"] as? String,
            instructions: info["installInstructions"] as? String, revision: metadata.revisionNumber, installedRevision: nil,
            latestRevision: metadata.revisionNumber, entries: entries, rules: rules)
        collection.resolveRequiredSelections()
        return collection
    }

    mutating func carryForwardSelections(from previous: NativeCollection) {
        for index in entries.indices where entries[index].optional {
            if let old = previous.entries.first(where: {
                $0.id == entries[index].id || ($0.modID != nil && $0.modID == entries[index].modID)
            }) {
                entries[index].selected = old.selected
            }
        }
        resolveRequiredSelections()
    }

    mutating func resolveRequiredSelections() {
        var changed = true
        while changed {
            changed = false
            for rule in rules where rule.kind.lowercased() == "requires" {
                if entries.first(where: { $0.id == rule.sourceID })?.selected == true,
                   let target = entries.firstIndex(where: { $0.id == rule.targetID }), !entries[target].selected {
                    entries[target].selected = true
                    entries[target].status = .pending
                    changed = true
                }
            }
        }
    }

    var updateSummary: CollectionUpdateSummary? {
        guard let previousEntries else { return nil }
        return CollectionUpdateSummary(previous: previousEntries, updated: entries)
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? String { return Int(value) }
        return nil
    }
}

enum CollectionError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { switch self { case .invalid(let message): return message } }
}

struct CollectionUpdateSummary: Sendable {
    var added: Int = 0
    var removed: Int = 0
    var replaced: Int = 0
    var unchanged: Int = 0

    init(previous: [NativeCollectionEntry], updated: [NativeCollectionEntry]) {
        var remaining = previous
        for entry in updated {
            if let exact = remaining.firstIndex(where: { $0.id == entry.id }) {
                unchanged += 1
                remaining.remove(at: exact)
            } else if let replacement = remaining.firstIndex(where: { old in
                if let modID = entry.modID { return old.modID == modID }
                return old.name.caseInsensitiveCompare(entry.name) == .orderedSame && old.source == entry.source
            }) {
                replaced += 1
                remaining.remove(at: replacement)
            } else { added += 1 }
        }
        removed = remaining.count
    }
}
