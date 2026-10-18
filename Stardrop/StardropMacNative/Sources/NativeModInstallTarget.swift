import AppKit
import Foundation

enum NativeModInstallTarget: Equatable {
    case ordinary
    case collectionAddon

    static let preferenceKey = "alwaysAskForCollectionInstallTarget"

    static func shouldAsk(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: preferenceKey) == nil || defaults.bool(forKey: preferenceKey)
    }

    /// Call only after matching pinned collection files and existing manual downloads.
    @MainActor
    static func choose(collectionName: String, defaults: UserDefaults = .standard) -> NativeModInstallTarget? {
        guard shouldAsk(defaults: defaults) else { return .collectionAddon }
        let alert = NSAlert()
        alert.messageText = "Choose Mod Install Destination"
        alert.informativeText = "Install this mod normally, or add it to \(collectionName)? Collection add-ons stay with that collection and are preserved during revision updates. A pinned collection mod cannot be replaced."
        alert.addButton(withTitle: "Install Normally")
        alert.addButton(withTitle: "Add to Collection")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .ordinary
        case .alertSecondButtonReturn: return .collectionAddon
        default: return nil
        }
    }
}
