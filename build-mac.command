#!/bin/bash

# Navigate to the script's directory
cd "$(dirname "$0")"

echo "Navigating to Stardrop source directory..."
cd Stardrop

echo "Cleaning up old builds..."
rm -rf published/mac

echo "Creating package directories..."
mkdir -p "published/mac/Stardrop.app/Contents/MacOS"
mkdir -p "published/mac/Stardrop.app/Contents/Resources"

echo "Publishing Stardrop for macOS..."
dotnet publish . --output "published/mac/Stardrop.app/Contents/MacOS" --configuration "Release" --runtime "osx-x64" --framework "net8.0" --self-contained

echo "Packaging Stardrop App bundle..."
cp Assets/Info.plist "published/mac/Stardrop.app/Contents/Info.plist"
cp Assets/Stardrop.icns "published/mac/Stardrop.app/Contents/Resources/Stardrop.icns"
chmod +x "published/mac/Stardrop.app/Contents/MacOS/Stardrop"

echo "Signing Stardrop App..."
codesign --force --deep -s - "published/mac/Stardrop.app"

echo "Build complete! Launching Stardrop..."
open "published/mac/Stardrop.app"
