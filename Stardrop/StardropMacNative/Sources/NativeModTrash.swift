import Foundation

struct NativeTrashedMod {
    let name: String
    let originalURL: URL
    let trashURL: URL
}

enum NativeModTrash {
    enum Failure: LocalizedError {
        case invalidLocation, protectedMod, missingTrashLocation, destinationOccupied, missingOriginalParent

        var errorDescription: String? {
            switch self {
            case .invalidLocation: return "Only individual mod folders inside the current Mods directory can be moved to Trash."
            case .protectedMod: return "Collection mods and SMAPI's built-in mods cannot be moved to Trash here."
            case .missingTrashLocation: return "macOS did not return the Trash location. You can restore the mod using Finder."
            case .destinationOccupied: return "A file or folder already exists at the original location. Move it aside before trying Undo again."
            case .missingOriginalParent: return "The original parent folder has moved or is unavailable. Restore it before trying Undo again, or recover the mod from Trash in Finder."
            }
        }
    }

    static func moveToTrash(_ mod: ModEntry, modsDirectory: URL, fileManager: FileManager = .default) throws -> NativeTrashedMod {
        guard mod.sourceID == nil,
              !["smapi.consolecommands", "smapi.savebackup"].contains(mod.id.lowercased()) else {
            throw Failure.protectedMod
        }
        let root = modsDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let source = URL(fileURLWithPath: mod.folderPath, isDirectory: true).standardizedFileURL
        let resolved = source.resolvingSymlinksInPath()
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              resolved.path.hasPrefix(root.path + "/"),
              !resolved.path.dropFirst(root.path.count + 1).split(separator: "/").contains(where: { $0.lowercased() == "collections" }) else {
            throw Failure.invalidLocation
        }
        var resultingURL: NSURL?
        try fileManager.trashItem(at: resolved, resultingItemURL: &resultingURL)
        guard let trashURL = resultingURL as URL? else { throw Failure.missingTrashLocation }
        return NativeTrashedMod(name: mod.manifest.Name, originalURL: resolved, trashURL: trashURL)
    }

    static func restore(_ item: NativeTrashedMod, fileManager: FileManager = .default) throws {
        // Query fresh filesystem attributes, including dangling symlinks. URL
        // resource values may be cached from before the move to Trash.
        if (try? fileManager.attributesOfItem(atPath: item.originalURL.path)) != nil {
            throw Failure.destinationOccupied
        }
        let parent = item.originalURL.deletingLastPathComponent()
        let attributes = try? fileManager.attributesOfItem(atPath: parent.path)
        guard attributes?[.type] as? FileAttributeType == .typeDirectory,
              parent.resolvingSymlinksInPath().path == parent.path else {
            throw Failure.missingOriginalParent
        }
        // moveItem refuses to replace a destination that appeared after the check.
        try fileManager.moveItem(at: item.trashURL, to: item.originalURL)
    }
}
