import Foundation

extension CollectionRegression {
    static func revisions() throws {
        var oldOptional = entry("old-file", optional: true)
        oldOptional.modID = 100
        oldOptional.fileID = 101
        var mandatory = entry("new-file")
        mandatory.modID = 100
        mandatory.fileID = 102
        var updated = collection([mandatory])
        updated.carryForwardSelections(from: collection([oldOptional]))
        try expect(updated.entries[0].selected, "a former optional file becoming mandatory stays selected across changed file IDs")
        try expect(try updated.orderedEntryIDs() == ["new-file"], "mandatory replacement participates in installation")

        var optional = entry("optional", optional: true)
        optional.selected = true
        updated = collection([entry("optional", optional: true)])
        updated.carryForwardSelections(from: collection([optional]))
        try expect(updated.entries[0].selected, "selected optional preference survives a revision")
        updated = collection([entry("optional", optional: true)])
        updated.carryForwardSelections(from: collection([entry("optional", optional: true)]))
        try expect(!updated.entries[0].selected, "unselected optional preference survives a revision")

        updated = collection([entry("required"), entry("optional", optional: true)], rules: [
            .init(kind: "requires", sourceID: "required", targetID: "optional")
        ])
        updated.carryForwardSelections(from: collection([entry("optional", optional: true)]))
        try expect(updated.entries[1].selected, "new dependency overrides the old optional choice")
        try expect(try updated.orderedEntryIDs() == ["optional", "required"], "required dependency remains installable after carrying choices")

        let metadata = CollectionRevisionMetadata(slug: "fixture", revisionNumber: 1, name: "Fixture", downloadLink: URL(string: "https://example.invalid/index.zip")!)
        let index = Data(#"{"mods":[{"name":"Config","source":{"type":"bundle","fileExpression":"config*"}},{"name":"Pinned","source":{"type":"nexus","modId":100,"fileId":101,"md5":"aabb"}}]}"#.utf8)
        var previous = try NativeCollection.readIndex(index, metadata: metadata)
        previous.entries[0].status = .installed
        previous.entries[1].status = .installed
        var nextMetadata = metadata
        nextMetadata.revisionNumber = 2
        let next = try NativeCollection.readIndex(index, metadata: nextMetadata)
        try expect(previous.entries[0].id == next.entries[0].id, "bundle paths can retain their entry identity across revisions")
        try expect(!next.entries[0].canReusePayload(from: previous.entries[0]), "new revision restages bundles even with unchanged expressions")
        try expect(next.entries[1].canReusePayload(from: previous.entries[1]), "unchanged installed Nexus pins retain payload reuse")
        var replacement = next.entries[1]
        replacement.id = "different-file"
        try expect(!replacement.canReusePayload(from: previous.entries[1]), "changed Nexus pins do not reuse old payloads")
        previous.entries[1].status = .pending
        try expect(!next.entries[1].canReusePayload(from: previous.entries[1]), "unfinished payloads are not reused")
    }
}
