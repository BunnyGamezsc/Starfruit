import Foundation

extension CollectionRegression {
    static func profileRoundTrips() throws {
        let manifest = SharedProfileManifest(
            name: "Native round trip",
            exportedAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
            enabledMods: [
                SharedProfileMod(uniqueID: "Author.Enabled", name: "Enabled", version: "1.2.3",
                    updateKeys: ["GitHub:author/enabled", "Nexus:123"], sourceID: "collection-source",
                    isEnabled: true, note: "Enabled note"),
                SharedProfileMod(uniqueID: "Author.Disabled", name: "Disabled", version: "2.0.0",
                    updateKeys: ["GitHub:author/disabled"], sourceID: "collection-source",
                    isEnabled: false, note: "Disabled note")
            ],
            notes: ["Author.Disabled": "Profile note"],
            preservedModConfigs: ["Author.Enabled": .object(["Enabled": .bool(true), "Scale": .number(1.25)])]
        )
        for (label, strategy) in [("ISO8601", JSONEncoder.DateEncodingStrategy.iso8601), ("numeric", .deferredToDate)] {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = strategy
            let data = try encoder.encode(manifest)
            let restored = try SharedProfileManifest.decodePortable(data)
            try expect(restored.name == manifest.name && restored.format == manifest.format, "\(label) profile identity retained")
            try expect(restored.exportedAt == manifest.exportedAt, "\(label) export date retained")
            try expect(restored.enabledMods == manifest.enabledMods, "\(label) update keys, disabled source identity, and mod notes retained")
            try expect(restored.notes == manifest.notes && restored.preservedModConfigs == manifest.preservedModConfigs, "\(label) profile notes and configs retained")
        }
    }
}
