import Foundation

struct ModProfile: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var enabledModIDs: Set<String>
    var isCollectionProfile: Bool = false
    var collectionSourceID: String?
    var modSources: [String: String] = [:]
    var modNotes: [String: String] = [:]
    var ignoredUpdateVersions: [String: String] = [:]
    var missingMods: [SharedProfileMod] = []
    var preservedModConfigs: [String: ProfileJSONValue] = [:]
    var isProtected: Bool = false
    var missingModIDs: Set<String> { Set(missingMods.map(\.uniqueID)) }
    func ignoresUpdate(modID: String, version: String?) -> Bool {
        guard let version else { return false }
        return ignoredUpdateVersions.first { $0.key.caseInsensitiveCompare(modID) == .orderedSame }?.value == version
    }
    static func mergingCapturedConfigs(_ configs: [String: ProfileJSONValue], profileID: UUID, into persisted: Data) throws -> Data {
        var saved = try JSONDecoder().decode([ModProfile].self, from: persisted)
        if let index = saved.firstIndex(where: { $0.id == profileID }) { saved[index].preservedModConfigs = configs }
        return try JSONEncoder().encode(saved)
    }

    enum CodingKeys: String, CodingKey {
        case id, name, enabledModIDs, isCollectionProfile, collectionSourceID, modSources, modNotes, ignoredUpdateVersions, missingMods, isProtected, preservedModConfigs
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
        collectionSourceID = try container.decodeIfPresent(String.self, forKey: .collectionSourceID)
        modSources = try container.decodeIfPresent([String: String].self, forKey: .modSources) ?? [:]
        modNotes = try container.decodeIfPresent([String: String].self, forKey: .modNotes) ?? [:]
        ignoredUpdateVersions = try container.decodeIfPresent([String: String].self, forKey: .ignoredUpdateVersions) ?? [:]
        missingMods = try container.decodeIfPresent([SharedProfileMod].self, forKey: .missingMods) ?? []
        preservedModConfigs = try container.decodeIfPresent([String: ProfileJSONValue].self, forKey: .preservedModConfigs) ?? [:]
        isProtected = try container.decodeIfPresent(Bool.self, forKey: .isProtected) ?? false
    }
}

struct ModPreset: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var enabledModIDs: Set<String>
    var createdAt: Date = Date()
}

struct SharedProfileManifest: Codable {
    var format: String = "starfruit.profile.v2"
    var name: String
    var exportedAt: Date = Date()
    var enabledMods: [SharedProfileMod]
    var notes: [String: String]?
    var preservedModConfigs: [String: ProfileJSONValue]? = nil
}

struct SharedProfileMod: Codable, Hashable {
    var uniqueID: String
    var name: String
    var version: String
    var updateKeys: [String]
    var sourceID: String? = nil
    var isEnabled: Bool? = nil
    var note: String? = nil
}


// Include Stardrop's portable keys alongside native metadata so either application can import the same export.
extension SharedProfileManifest {
    private enum ExportKeys: String, CodingKey {
        case format, name, exportedAt, enabledMods, notes
        case preservedModConfigs
        case portableName = "Name", portableEnabled = "EnabledModIds", portableMods = "ModData", portableNotes = "Notes"
        case portableProtected = "IsProtected", portableConfigs = "PreservedModConfigs"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: ExportKeys.self)
        try container.encode(format, forKey: .format)
        try container.encode(name, forKey: .name)
        try container.encode(exportedAt, forKey: .exportedAt)
        try container.encode(enabledMods, forKey: .enabledMods)
        try container.encodeIfPresent(notes, forKey: .notes)
        try container.encodeIfPresent(preservedModConfigs, forKey: .preservedModConfigs)
        try container.encode(name, forKey: .portableName)
        let enabled = enabledMods.filter { $0.isEnabled != false }.map { mod -> [String: String] in
            var reference = ["UniqueId": mod.uniqueID]
            if let source = mod.sourceID { reference["SourceId"] = source }
            return reference
        }
        try container.encode(enabled, forKey: .portableEnabled)
        let portableMods = enabledMods.map { mod -> [String: String] in
            let nexus = mod.updateKeys.first(where: { $0.lowercased().hasPrefix("nexus:") })?.dropFirst(6)
            let page = nexus.map { "https://www.nexusmods.com/stardewvalley/mods/\($0)" } ?? ""
            return ["UniqueId": mod.uniqueID, "Version": mod.version, "Name": mod.name, "Author": "", "ModPageUri": page]
        }
        try container.encode(portableMods, forKey: .portableMods)
        try container.encode((notes ?? [:]).map { ["UniqueId": $0.key, "Note": $0.value] }, forKey: .portableNotes)
        try container.encode(false, forKey: .portableProtected)
        try container.encode(preservedModConfigs ?? [:], forKey: .portableConfigs)
    }

    static func decodePortable(_ data: Data) throws -> SharedProfileManifest {
        if let native = try? JSONDecoder().decode(Self.self, from: data) {
            guard ["starfruit.profile.v1", "starfruit.profile.v2"].contains(native.format) else { throw CollectionError.invalid("Unsupported profile format.") }
            return native
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CollectionError.invalid("Invalid profile JSON.") }
        func value(_ key: String, _ dictionary: [String: Any]) -> Any? { dictionary.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value }
        guard let name = value("Name", object) as? String, let enabled = value("EnabledModIds", object) as? [Any] else { throw CollectionError.invalid("This file is not a portable Stardrop profile.") }
        let metadata = value("ModData", object) as? [[String: Any]] ?? []
        var notes: [String: String] = [:]
        for note in value("Notes", object) as? [[String: Any]] ?? [] {
            if let id = value("UniqueId", note) as? String, let text = value("Note", note) as? String { notes[id] = text }
        }
        let references = enabled.compactMap { raw -> (String, String?)? in
            if let id = raw as? String, !id.isEmpty { return (id, nil) }
            guard let reference = raw as? [String: Any], let id = value("UniqueId", reference) as? String, !id.isEmpty else { return nil }
            return (id, value("SourceId", reference) as? String)
        }
        var entries: [SharedProfileMod] = []
        for info in metadata {
            guard let id = value("UniqueId", info) as? String else { continue }
            let reference = references.first { $0.0.caseInsensitiveCompare(id) == .orderedSame }
            var keys = value("UpdateKeys", info) as? [String] ?? []
            if keys.isEmpty, let text = value("ModPageUri", info) as? String, let url = URL(string: text),
               ["www.nexusmods.com", "nexusmods.com"].contains(url.host?.lowercased() ?? ""),
               let index = url.pathComponents.firstIndex(of: "mods"), url.pathComponents.indices.contains(index + 1),
               let nexusID = Int(url.pathComponents[index + 1]), nexusID > 0 { keys = ["Nexus:\(nexusID)"] }
            entries.append(SharedProfileMod(uniqueID: id, name: value("Name", info) as? String ?? id,
                version: value("Version", info) as? String ?? "Unknown", updateKeys: keys,
                sourceID: reference?.1 ?? value("SourceId", info) as? String, isEnabled: reference != nil,
                note: notes.first { $0.key.caseInsensitiveCompare(id) == .orderedSame }?.value))
        }
        for (id, source) in references where !entries.contains(where: { $0.uniqueID.caseInsensitiveCompare(id) == .orderedSame }) {
            entries.append(SharedProfileMod(uniqueID: id, name: id, version: "Unknown", updateKeys: [], sourceID: source, isEnabled: true, note: notes[id]))
        }
        let configs: [String: ProfileJSONValue]?
        if let raw = value("PreservedModConfigs", object) as? [String: Any] {
            configs = try JSONDecoder().decode([String: ProfileJSONValue].self, from: JSONSerialization.data(withJSONObject: raw))
        } else { configs = nil }
        return Self(name: name, enabledMods: entries, notes: notes, preservedModConfigs: configs)
    }
}

/// Keeps arbitrary config.json values lossless across native and Stardrop portable profiles.
indirect enum ProfileJSONValue: Codable, Hashable {
    case object([String: ProfileJSONValue]), array([ProfileJSONValue]), string(String), number(Decimal), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(Decimal.self) { self = .number(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode([String: ProfileJSONValue].self) { self = .object(value) }
        else { self = .array(try c.decode([ProfileJSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let value): try c.encode(value)
        case .array(let value): try c.encode(value)
        case .string(let value): try c.encode(value)
        case .number(let value): try c.encode(value)
        case .bool(let value): try c.encode(value)
        case .null: try c.encodeNil()
        }
    }
}

extension ModProfile {
    mutating func reconcileCollection(sourceID: String, newIDs: Set<String>, previousIDs: Set<String>) {
        let previous = Set(previousIDs.map { $0.lowercased() })
        let enabled = Set(enabledModIDs.map { $0.lowercased() })
        let disabled = previous.subtracting(enabled)
        // Keep ordinary mods and add-ons, then replace only references owned by the curator's old revision.
        enabledModIDs = enabledModIDs.filter { id in
            !(modSources[id] == sourceID && previous.contains(id.lowercased()))
        }
        for id in newIDs where !disabled.contains(id.lowercased()) {
            enabledModIDs.insert(id)
            modSources[id] = sourceID
        }
        for key in Array(modSources.keys) where previous.contains(key.lowercased()) && !newIDs.contains(where: { $0.caseInsensitiveCompare(key) == .orderedSame }) {
            modSources.removeValue(forKey: key)
        }
    }
}
