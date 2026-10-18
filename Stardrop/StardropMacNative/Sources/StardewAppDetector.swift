import AppKit

enum StardewAppDetector {
    private static let wineProcessNames: Set<String> = [
        "wine",
        "wine64",
        "wine-preloader",
        "wine64-preloader"
    ]

    static func isStardewApp(_ app: NSRunningApplication?) -> Bool {
        guard let app else { return false }
        let bid = (app.bundleIdentifier ?? "").lowercased()
        let name = app.localizedName ?? ""
        let executableName = app.executableURL?.lastPathComponent.lowercased() ?? ""

        return bid.contains("codeweavers") ||
               bid.contains("stardew") ||
               name.localizedCaseInsensitiveContains("Stardew Valley") ||
               name.localizedCaseInsensitiveContains("SMAPI") ||
               wineProcessNames.contains(name.lowercased()) ||
               wineProcessNames.contains(executableName)
    }

    static var isStardewFrontmost: Bool {
        isStardewApp(NSWorkspace.shared.frontmostApplication)
    }
}
