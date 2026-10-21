import Foundation

@main
struct ModTrashRegression {
    enum FixtureError: Error { case assertion(String) }

    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw FixtureError.assertion(message) }
    }

    static func expectFailure(_ failure: NativeModTrash.Failure, _ action: () throws -> Void) throws {
        do {
            try action()
            throw FixtureError.assertion("Expected \(failure)")
        } catch let actual as NativeModTrash.Failure {
            try expect(String(describing: actual) == String(describing: failure), "Unexpected failure: \(actual)")
        }
    }

    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("StarfruitTrashFixture-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        let mods = root.appendingPathComponent("Mods")
        try fm.createDirectory(at: mods, withIntermediateDirectories: true)
        var trashed: [NativeTrashedMod] = []
        defer {
            try? fm.removeItem(at: root)
            // Only these uniquely created fixture folders can reach Trash.
            for item in trashed { try? fm.removeItem(at: item.trashURL) }
        }

        func fixture(_ folder: URL, version: String = "1.0", id: String = "Fixture.Mod") throws -> ModEntry {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let json = try JSONSerialization.data(withJSONObject: ["Name": "Trash Fixture", "Author": "Fixture", "Version": version, "UniqueID": id])
            try json.write(to: folder.appendingPathComponent("manifest.json"))
            try Data(version.utf8).write(to: folder.appendingPathComponent("config.json"))
            return ModEntry(manifest: try JSONDecoder().decode(ModManifest.self, from: json), folderPath: folder.path)
        }

        let folder = mods.appendingPathComponent("StarfruitTrashFixture-\(UUID().uuidString)")
        let mod = try fixture(folder)
        let first = try NativeModTrash.moveToTrash(mod, modsDirectory: mods)
        trashed.append(first)
        try expect(!fm.fileExists(atPath: folder.path), "Trash removes the original folder")
        try expect(fm.fileExists(atPath: first.trashURL.appendingPathComponent("manifest.json").path), "Trash retains the full mod")
        try expect(try String(contentsOf: first.trashURL.appendingPathComponent("config.json"), encoding: .utf8) == "1.0", "Trash retains configuration")

        // A second copy with the same folder name must have its own recovery URL.
        let newer = try fixture(folder, version: "2.0")
        let second = try NativeModTrash.moveToTrash(newer, modsDirectory: mods)
        trashed.append(second)
        try expect(first.trashURL != second.trashURL, "Trash name collisions retain distinct copies")
        try NativeModTrash.restore(second)
        try expect(try String(contentsOf: folder.appendingPathComponent("config.json"), encoding: .utf8) == "2.0", "Undo restores the correct version")
        try expectFailure(.destinationOccupied) { try NativeModTrash.restore(first) }
        try expect(fm.fileExists(atPath: first.trashURL.path), "Failed Undo keeps its recoverable copy")
        try fm.moveItem(at: folder, to: root.appendingPathComponent("NewerCopy"))

        // Even a dangling symlink must not be overwritten.
        try fm.createSymbolicLink(at: folder, withDestinationURL: root.appendingPathComponent("Absent"))
        try expectFailure(.destinationOccupied) { try NativeModTrash.restore(first) }
        try fm.removeItem(at: folder)
        try NativeModTrash.restore(first)
        try expect(try String(contentsOf: folder.appendingPathComponent("config.json"), encoding: .utf8) == "1.0", "Undo restores the original config")

        let nestedParent = mods.appendingPathComponent("Group")
        let nested = try fixture(nestedParent.appendingPathComponent("Nested"))
        let nestedTrash = try NativeModTrash.moveToTrash(nested, modsDirectory: mods)
        trashed.append(nestedTrash)
        let movedParent = root.appendingPathComponent("MovedGroup")
        try fm.moveItem(at: nestedParent, to: movedParent)
        try expectFailure(.missingOriginalParent) { try NativeModTrash.restore(nestedTrash) }
        try fm.createSymbolicLink(at: nestedParent, withDestinationURL: movedParent)
        try expectFailure(.missingOriginalParent) { try NativeModTrash.restore(nestedTrash) }
        try fm.removeItem(at: nestedParent)
        try fm.moveItem(at: movedParent, to: nestedParent)
        try NativeModTrash.restore(nestedTrash)

        let outside = try fixture(root.appendingPathComponent("Outside"))
        try expectFailure(.invalidLocation) { _ = try NativeModTrash.moveToTrash(outside, modsDirectory: mods) }
        var rootMod = mod
        rootMod.folderPath = mods.path
        try expectFailure(.invalidLocation) { _ = try NativeModTrash.moveToTrash(rootMod, modsDirectory: mods) }
        let link = mods.appendingPathComponent("LinkedMod")
        try fm.createSymbolicLink(at: link, withDestinationURL: folder)
        var linked = mod
        linked.folderPath = link.path
        try expectFailure(.invalidLocation) { _ = try NativeModTrash.moveToTrash(linked, modsDirectory: mods) }

        var collection = mod
        collection.sourceID = "collection_fixture"
        try expectFailure(.protectedMod) { _ = try NativeModTrash.moveToTrash(collection, modsDirectory: mods) }
        let core = try fixture(mods.appendingPathComponent("Core"), id: "smapi.SAVEBACKUP")
        try expectFailure(.protectedMod) { _ = try NativeModTrash.moveToTrash(core, modsDirectory: mods) }
        let legacy = try fixture(mods.appendingPathComponent("Collections/Legacy/Mod"))
        try expectFailure(.invalidLocation) { _ = try NativeModTrash.moveToTrash(legacy, modsDirectory: mods) }
        try expect(fm.fileExists(atPath: outside.folderPath) && fm.fileExists(atPath: core.folderPath), "Rejected operations keep files intact")

        let gone = try NativeModTrash.moveToTrash(mod, modsDirectory: mods)
        trashed.append(gone)
        try fm.removeItem(at: gone.trashURL) // Simulate Trash being emptied externally.
        do {
            try NativeModTrash.restore(gone)
            throw FixtureError.assertion("Undo must fail if Trash was emptied")
        } catch is CocoaError { }
        try expect(!fm.fileExists(atPath: folder.path), "Failed recovery does not create an empty replacement")
        print("Mod Trash regression fixtures passed")
    }
}
