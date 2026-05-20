#!/bin/bash
set -e
cd "$(dirname "$0")"

echo "Cleaning old native builds..."
rm -rf "Starfruit.app"

echo "Creating App Bundle Structure..."
mkdir -p "Starfruit.app/Contents/MacOS"
mkdir -p "Starfruit.app/Contents/Resources"

echo "Compiling Swift source files directly into native executable..."
swiftc Sources/*.swift -o "Starfruit.app/Contents/MacOS/Starfruit"

echo "Writing macOS Info.plist..."
cat > "Starfruit.app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Starfruit</string>
    <key>CFBundleIconFile</key>
    <string>Starfruit</string>
    <key>CFBundleIdentifier</key>
    <string>com.starfruit.macnative</string>
    <key>CFBundleName</key>
    <string>Starfruit</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 BunnyGamez. Licensed under GPLv3.</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>Nexus Mods Link</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>nxm</string>
            </array>
        </dict>
    </array>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
</dict>
</plist>
EOF

if [ -f "../Assets/Starfruit_Mac.icns" ]; then
    echo "Copying Starfruit Mac Icon..."
    cp "../Assets/Starfruit_Mac.icns" "Starfruit.app/Contents/Resources/Starfruit.icns"
fi

echo "Signing Native App..."
codesign --force --deep -s - "Starfruit.app"

echo "Done! The Starfruit.app has been built natively."
echo "Double click Starfruit.app or run: open Starfruit.app"
