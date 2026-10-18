import Foundation

struct SMAPILauncher {
    /// Launches SMAPI via a reusable wrapper app that accepts arguments.
    static func launch(smapiDir: String, winePrefix: String, wineBinary: String, useWine: Bool, modsPath: String?) {
        let resolvedSmapiDir = resolvePath(smapiDir)
        let resolvedWinePrefix = resolvePath(winePrefix)
        let resolvedWineBinary = resolvePath(wineBinary)

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let wrappersDir = appSupport.appendingPathComponent("StarfruitNative/Wrappers", isDirectory: true)
        let wrapperAppName = useWine ? "SMAPI-Wine.app" : "SMAPI-Native.app"
        let legacyWrapperName = useWine ? "SMAPI Wine.app" : "SMAPI Native.app"
        let wrapperApp = wrappersDir.appendingPathComponent(wrapperAppName)
        let legacyWrapperApp = wrappersDir.appendingPathComponent(legacyWrapperName)

        let contentsDir  = wrapperApp.appendingPathComponent("Contents")
        let macosDir     = contentsDir.appendingPathComponent("MacOS")
        let resourcesDir = contentsDir.appendingPathComponent("Resources")
        let executablePath = macosDir.appendingPathComponent("SMAPI").path
        let plistPath    = contentsDir.appendingPathComponent("Info.plist").path

        try? FileManager.default.removeItem(at: legacyWrapperApp)

        guard setupWrapperApp(executablePath: executablePath, plistPath: plistPath, macosDir: macosDir, resourcesDir: resourcesDir, smapiDir: resolvedSmapiDir, useWine: useWine) else {
            print("[SMAPILauncher] Failed to install native SMAPI wrapper executable")
            return
        }

        print("[SMAPILauncher] Launching wrapper app: \(wrapperApp.path)")

        var args = ["--game-dir", resolvedSmapiDir,
                    "--wine-prefix", resolvedWinePrefix,
                    "--wine-bin", resolvedWineBinary]

        if let modsPath = modsPath {
            args.append(contentsOf: ["--mods-path", modsPath])
        }
        if useWine {
            args.append("--use-wine")
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", wrapperApp.path, "--args"] + args

        do {
            try task.run()
            print("[SMAPILauncher] Wrapper launched via LaunchServices")
        } catch {
            print("[SMAPILauncher] Failed to start wrapper: \(error)")
        }
    }

    /// Expands tilde (~) and resolves the path to an absolute string.
    static func resolvePath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).path
    }

    @discardableResult
    private static func setupWrapperApp(executablePath: String, plistPath: String, macosDir: URL, resourcesDir: URL, smapiDir: String, useWine: Bool) -> Bool {
        let fileManager = FileManager.default

        do {
            try fileManager.createDirectory(at: macosDir, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: resourcesDir, withIntermediateDirectories: true)
        } catch {
            print("[SMAPILauncher] Failed to create wrapper directories: \(error)")
            return false
        }

        guard let bundledWrapper = Bundle.main.path(forResource: "SMAPIWrapper", ofType: nil) else {
            print("[SMAPILauncher] Bundled SMAPIWrapper executable not found in Starfruit.app")
            return false
        }

        do {
            if fileManager.fileExists(atPath: executablePath) {
                try fileManager.removeItem(atPath: executablePath)
            }
            try fileManager.copyItem(atPath: bundledWrapper, toPath: executablePath)
        } catch {
            print("[SMAPILauncher] Failed to copy SMAPI wrapper executable: \(error)")
            return false
        }

        let sourceIcon = URL(fileURLWithPath: smapiDir).appendingPathComponent("StardewValleyModdingAPI.app/Contents/Resources/AppIcon.icns")
        let destIcon = resourcesDir.appendingPathComponent("AppIcon.icns")
        if fileManager.fileExists(atPath: sourceIcon.path) {
            try? fileManager.removeItem(at: destIcon)
            try? fileManager.copyItem(at: sourceIcon, to: destIcon)
        }

        let plistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleExecutable</key><string>SMAPI</string>
            <key>CFBundleIconFile</key><string>AppIcon</string>
            <key>CFBundleIdentifier</key><string>com.bunnygamez.starfruit.smapi-\(useWine ? "wine" : "native")-wrapper</string>
            <key>CFBundleName</key><string>SMAPI \(useWine ? "Wine" : "Native")</string>
            <key>CFBundlePackageType</key><string>APPL</string>
            <key>CFBundleShortVersionString</key><string>1.0</string>
            <key>CFBundleVersion</key><string>1</string>
            <key>NSHighResolutionCapable</key><true/>
            <key>LSUIElement</key><false/>
            <key>LSMinimumSystemVersion</key><string>13.0</string>
        </dict>
        </plist>
        """

        do {
            try plistContent.write(toFile: plistPath, atomically: true, encoding: .utf8)
        } catch {
            print("[SMAPILauncher] Failed to write wrapper Info.plist: \(error)")
            return false
        }

        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+x", executablePath]
        try? chmod.run()
        chmod.waitUntilExit()

        return true
    }
}
