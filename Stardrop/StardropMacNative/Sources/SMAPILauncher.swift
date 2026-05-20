import Foundation

struct SMAPILauncher {
    /// Launches SMAPI via a reusable wrapper app that accepts arguments.
    static func launch(smapiDir: String, winePrefix: String, wineBinary: String, useWine: Bool, modsPath: String?) {
        let resolvedSmapiDir = resolvePath(smapiDir)
        let resolvedWinePrefix = resolvePath(winePrefix)
        let resolvedWineBinary = resolvePath(wineBinary)
        
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let wrappersDir = appSupport.appendingPathComponent("StarfruitNative/Wrappers", isDirectory: true)
        let wrapperAppName = useWine ? "SMAPI Wine.app" : "SMAPI Native.app"
        let wrapperApp = wrappersDir.appendingPathComponent(wrapperAppName)
        
        let contentsDir  = wrapperApp.appendingPathComponent("Contents")
        let macosDir     = contentsDir.appendingPathComponent("MacOS")
        let resourcesDir = contentsDir.appendingPathComponent("Resources")
        let scriptPath   = macosDir.appendingPathComponent("SMAPI").path
        let plistPath    = contentsDir.appendingPathComponent("Info.plist").path
        
        // Always update the wrapper to ensure it has the latest launch logic
        setupWrapperApp(scriptPath: scriptPath, plistPath: plistPath, macosDir: macosDir, resourcesDir: resourcesDir, smapiDir: resolvedSmapiDir, useWine: useWine)

        print("[SMAPILauncher] Launching wrapper at: \(wrapperApp.path)")
        
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        
        var args = ["-n", wrapperApp.path, "--args", 
                    "--game-dir", resolvedSmapiDir, 
                    "--wine-prefix", resolvedWinePrefix,
                    "--wine-bin", resolvedWineBinary]
        
        if let modsPath = modsPath {
            args.append(contentsOf: ["--mods-path", modsPath])
        }
        if useWine {
            args.append("--use-wine")
        }
        
        task.arguments = args
        
        do {
            try task.run()
            print("[SMAPILauncher] Wrapper launched via open")
        } catch {
            print("[SMAPILauncher] Failed to execute open: \(error)")
        }
    }
    
    /// Expands tilde (~) and resolves the path to an absolute string.
    static func resolvePath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).path
    }
    
    private static func findWineBinary() -> String {
        let paths = [
            "/Applications/Wine Crossover.app/Contents/Resources/wine/bin/wine64",
            "/opt/homebrew/bin/wine",
            "/usr/local/bin/wine"
        ]
        return paths.first { FileManager.default.fileExists(atPath: $0) } ?? "wine"
    }
    
    private static func setupWrapperApp(scriptPath: String, plistPath: String, macosDir: URL, resourcesDir: URL, smapiDir: String, useWine: Bool) {
        try? FileManager.default.createDirectory(at: macosDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: resourcesDir, withIntermediateDirectories: true)
        
        // Copy icon from SMAPI.app if it exists
        let sourceIcon = URL(fileURLWithPath: smapiDir).appendingPathComponent("StardewValleyModdingAPI.app/Contents/Resources/AppIcon.icns")
        let destIcon = resourcesDir.appendingPathComponent("AppIcon.icns")
        if FileManager.default.fileExists(atPath: sourceIcon.path) {
            try? FileManager.default.removeItem(at: destIcon)
            try? FileManager.default.copyItem(at: sourceIcon, to: destIcon)
        }
        
        let scriptContent = """
        #!/bin/bash
        # SMAPI Wrapper Script for Starfruit Native
        
        GAME_DIR=""
        WINE_PREFIX=""
        MODS_PATH=""
        WINE_BIN="wine"
        USE_WINE=false
        
        # Parse arguments
        while [[ "$#" -gt 0 ]]; do
            case $1 in
                --game-dir) GAME_DIR="$2"; shift ;;
                --wine-prefix) WINE_PREFIX="$2"; shift ;;
                --mods-path) MODS_PATH="$2"; shift ;;
                --wine-bin) WINE_BIN="$2"; shift ;;
                --use-wine) USE_WINE=true ;;
            esac
            shift
        done
        
        LOG_FILE="$HOME/Library/Logs/StarfruitNative_SMAPI.log"
        echo "--- Wrapper Launch at $(date) ---" > "$LOG_FILE"
        
        export SMAPI_MODS_PATH="$MODS_PATH"
        export SMAPI_NO_TERMINAL=true
        export TERM=xterm
        export CORECLR_GLOBAL_INVARIANT=1
        export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
        
        if [ "$USE_WINE" = true ]; then
            export WINEPREFIX="$WINE_PREFIX"
            WINE_DIR=$(dirname $(dirname "$WINE_BIN"))
            export PATH="$WINE_DIR/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
            export DYLD_LIBRARY_PATH="$WINE_DIR/lib:$DYLD_LIBRARY_PATH"
            
            GAME_EXE="$GAME_DIR/StardewModdingAPI.exe"
            if [ -f "$GAME_EXE" ]; then
                cd "$GAME_DIR"
                echo "Executing Wine SMAPI via script(1)..." >> "$LOG_FILE"
                /usr/bin/script -q /dev/null "$WINE_BIN" "$(basename "$GAME_EXE")" >> "$LOG_FILE" 2>&1
            else
                echo "ERROR: Could not find $GAME_EXE" >> "$LOG_FILE"
                osascript -e "display dialog \\"Could not find SMAPI at $GAME_EXE\\" buttons {\\"OK\\"} default button \\"OK\\" with icon stop"
            fi
        else
            NATIVE_BIN="$GAME_DIR/StardewModdingAPI"
            if [ -f "$NATIVE_BIN" ]; then
                cd "$GAME_DIR"
                chmod +x "$NATIVE_BIN"
                echo "Executing Native SMAPI..." >> "$LOG_FILE"
                "$NATIVE_BIN" >> "$LOG_FILE" 2>&1
            else
                echo "ERROR: Could not find $NATIVE_BIN" >> "$LOG_FILE"
                osascript -e "display dialog \\"Could not find Native SMAPI at $NATIVE_BIN\\" buttons {\\"OK\\"} default button \\"OK\\" with icon stop"
            fi
        fi
        
        echo "Wrapper exiting." >> "$LOG_FILE"
        """
        
        let plistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleExecutable</key><string>SMAPI</string>
            <key>CFBundleIconFile</key><string>AppIcon</string>
            <key>CFBundleIdentifier</key><string>com.starfruit.smapi-\(useWine ? "wine" : "native")-wrapper</string>
            <key>CFBundleName</key><string>SMAPI \(useWine ? "Wine" : "Native")</string>
            <key>CFBundlePackageType</key><string>APPL</string>
            <key>NSHighResolutionCapable</key><true/>
            <key>LSUIElement</key><false/>
        </dict>
        </plist>
        """
        
        try? scriptContent.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try? plistContent.write(toFile: plistPath, atomically: true, encoding: .utf8)
        
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+x", scriptPath]
        try? chmod.run()
        chmod.waitUntilExit()
    }
}
