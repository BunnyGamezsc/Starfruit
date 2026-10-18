#!/bin/bash
set -e
cd "$(dirname "$0")"

BUILD_ONLY=false
if [ "${1:-}" = "--build-only" ]; then
    BUILD_ONLY=true
elif [ -n "${1:-}" ]; then
    echo "Usage: $0 [--build-only]" >&2
    exit 2
fi

SPARKLE_VERSION="2.10.0"
SPARKLE_SHA256="c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"
SPARKLE_DIR=".deps"
SPARKLE_FRAMEWORK="$SPARKLE_DIR/Sparkle.framework"
APP_VERSION="${APP_VERSION:-1.1.0}"
APP_BUILD="${APP_BUILD:-2}"
SIGN_IDENTITY="${SIGN_IDENTITY:-BunnyGamezDev}"
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-https://github.com/BunnyGamezsc/Starfruit/releases/latest/download/appcast.xml}"
if [ -z "${SPARKLE_PUBLIC_ED_KEY:-}" ]; then
    SPARKLE_PUBLIC_ED_KEY="$(tr -d '\r\n' < sparkle-public-key.txt)"
fi
if [[ ! "$SPARKLE_PUBLIC_ED_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
    echo "Expected a base64-encoded Sparkle Ed25519 public key (32 bytes)." >&2
    exit 2
fi
MACOS_DEPLOYMENT_TARGET="${MACOS_DEPLOYMENT_TARGET:-13.0}"
HOST_ARCH="$(uname -m)"
BUILD_ARCHS="${BUILD_ARCHS:-$HOST_ARCH}"
SWIFT_TARGET="${HOST_ARCH}-apple-macosx${MACOS_DEPLOYMENT_TARGET}"

find_working_sdk() {
    local default_sdk
    default_sdk="$(xcrun --sdk macosx --show-sdk-path)"

    local temp_base
    temp_base="$(mktemp -t test_state.XXXXXX)"
    local temp_swift="${temp_base}.swift"
    echo "import SwiftUI; typealias NativeState<Value> = SwiftUI.State<Value>; struct Test { @NativeState var x = 0 }" > "$temp_swift"

    if swiftc "$temp_swift" -typecheck -sdk "$default_sdk" -target "$SWIFT_TARGET" 2>/dev/null; then
        rm -f "$temp_base" "$temp_swift"
        echo "$default_sdk"
        return 0
    fi

    local clt_dir
    clt_dir="$(xcode-select -p 2>/dev/null || echo '/Library/Developer/CommandLineTools')"
    local sdk_dir="$clt_dir/SDKs"

    for sdk_path in $(ls -d "$sdk_dir"/MacOSX*.sdk 2>/dev/null | sort -V -r); do
        local resolved_sdk
        resolved_sdk="$(readlink -f "$sdk_path" || echo "$sdk_path")"
        if [ "$resolved_sdk" = "$default_sdk" ]; then
            continue
        fi

        if swiftc "$temp_swift" -typecheck -sdk "$resolved_sdk" -target "$SWIFT_TARGET" 2>/dev/null; then
            rm -f "$temp_base" "$temp_swift"
            echo "$resolved_sdk"
            return 0
        fi
    done

    rm -f "$temp_base" "$temp_swift"
    echo "$default_sdk"
}

resolve_sign_identity() {
    # Ad-hoc signing is an explicit CI/development choice, never a fallback.
    if [ "$SIGN_IDENTITY" = "-" ]; then
        printf '%s' '-'
        return
    fi
    local resolved
    resolved="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' -v name="$SIGN_IDENTITY" '{ split($1, fields, " "); if ($2 == name || toupper(fields[2]) == toupper(name)) print fields[2] }')"
    if [ -z "$resolved" ]; then
        echo "Code signing identity '$SIGN_IDENTITY' not found in Keychain. Build stopped before replacing any output." >&2
        echo "For a development/CI build only, explicitly set SIGN_IDENTITY=-." >&2
        return 1
    fi
    if [[ "$resolved" = *$'\n'* ]]; then
        echo "More than one identity matches '$SIGN_IDENTITY'; set SIGN_IDENTITY to the desired certificate's SHA-1 fingerprint." >&2
        return 1
    fi
    printf '%s' "$resolved"
}

sign_path() {
    codesign --force --timestamp=none -s "$1" "$2"
}

sign_path_runtime() {
    codesign --force --timestamp=none --options runtime --entitlements "$1" -s "$2" "$3"
}

sign_app_bundle() {
    local identity="$1"
    local sparkle_root="Starfruit.app/Contents/Frameworks/Sparkle.framework/Versions/B"

    # BunnyGamezDev is self-signed, with no Apple Team ID, as in Tokscale.
    # Permit the app's embedded Sparkle framework under hardened runtime.
    ENTITLEMENTS_PLIST="$(mktemp -t entitlements.XXXXXX.plist)"
    cat > "$ENTITLEMENTS_PLIST" << 'ENTEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
</dict>
</plist>
ENTEOF

    echo "Signing Sparkle helpers..."
    sign_path "$identity" "Starfruit.app/Contents/Resources/SMAPIWrapper"
    sign_path "$identity" "$sparkle_root/XPCServices/Downloader.xpc"
    sign_path "$identity" "$sparkle_root/XPCServices/Installer.xpc"
    sign_path "$identity" "$sparkle_root/Updater.app"
    sign_path "$identity" "$sparkle_root/Autoupdate"
    sign_path "$identity" "$sparkle_root/Sparkle"
    sign_path "$identity" "Starfruit.app/Contents/Frameworks/Sparkle.framework"
    sign_path_runtime "$ENTITLEMENTS_PLIST" "$identity" "Starfruit.app"
    # Signing the bundle last can leave the executable with an unusable CMS
    # authority for local self-signed identities on newer macOS toolchains.
    sign_path_runtime "$ENTITLEMENTS_PLIST" "$identity" "Starfruit.app/Contents/MacOS/Starfruit"
    rm -f "$ENTITLEMENTS_PLIST"
    codesign --verify --deep --strict --verbose=2 "Starfruit.app"
}

# Resolve the certificate before downloading dependencies or replacing a build.
RESOLVED_SIGN_IDENTITY="$(resolve_sign_identity)"
echo "Using signing identity: $SIGN_IDENTITY ($RESOLVED_SIGN_IDENTITY)"
echo "Detecting working SDK..."
WORKING_SDK="$(find_working_sdk)"
echo "Using SDK: $WORKING_SDK"

prepare_sparkle() (
    set -e
    mkdir -p "$SPARKLE_DIR"
    local staging
    staging="$(mktemp -d "$SPARKLE_DIR/download.XXXXXX")"
    trap 'rm -rf "$staging"' EXIT
    echo "Fetching and verifying Sparkle $SPARKLE_VERSION..."
    gh release download "$SPARKLE_VERSION" --repo sparkle-project/Sparkle \
        --pattern "Sparkle-${SPARKLE_VERSION}.tar.xz" --dir "$staging"
    printf '%s  %s\n' "$SPARKLE_SHA256" "$staging/Sparkle-${SPARKLE_VERSION}.tar.xz" | shasum -a 256 -c -
    tar -xJf "$staging/Sparkle-${SPARKLE_VERSION}.tar.xz" -C "$staging"
    test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$staging/Sparkle.framework/Resources/Info.plist")" = "$SPARKLE_VERSION"
    # Leave an older cache intact until the new archive has been authenticated.
    rm -rf "$SPARKLE_FRAMEWORK" "$SPARKLE_DIR/bin"
    mv "$staging/Sparkle.framework" "$SPARKLE_FRAMEWORK"
    mv "$staging/bin" "$SPARKLE_DIR/bin"
)

CACHED_SPARKLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SPARKLE_FRAMEWORK/Resources/Info.plist" 2>/dev/null || true)"
if [ "$CACHED_SPARKLE_VERSION" != "$SPARKLE_VERSION" ] || [ ! -x "$SPARKLE_DIR/bin/generate_appcast" ]; then
    prepare_sparkle
fi

echo "Cleaning old native builds..."
rm -rf "Starfruit.app"

echo "Creating App Bundle Structure..."
mkdir -p "Starfruit.app/Contents/MacOS"
mkdir -p "Starfruit.app/Contents/Resources"
mkdir -p "Starfruit.app/Contents/Frameworks"

echo "Copying Sparkle.framework..."
ditto "$SPARKLE_FRAMEWORK" "Starfruit.app/Contents/Frameworks/Sparkle.framework"

if [ -d "Resources" ]; then
    ditto "Resources" "Starfruit.app/Contents/Resources"
fi
if [ -f "../../LICENSE" ]; then
    cp "../../LICENSE" "Starfruit.app/Contents/Resources/LICENSE"
fi

echo "Compiling Swift source files directly into native executable..."
BUILD_TEMP="$(mktemp -d -t Starfruit-build.XXXXXX)"
trap 'rm -rf "$BUILD_TEMP"' EXIT
SWIFT_BINARIES=()
WRAPPER_BINARIES=()
for BUILD_ARCH in $BUILD_ARCHS; do
    case "$BUILD_ARCH" in
        arm64|x86_64) ;;
        *) echo "Unsupported macOS architecture: $BUILD_ARCH" >&2; exit 2 ;;
    esac
    RUNAPP_OBJECT="$BUILD_TEMP/RunApp-$BUILD_ARCH.o"
    SWIFT_BINARY="$BUILD_TEMP/Starfruit-$BUILD_ARCH"
    WRAPPER_BINARY="$BUILD_TEMP/SMAPIWrapper-$BUILD_ARCH"
    echo "Compiling native application for $BUILD_ARCH..."
    xcrun --sdk "$WORKING_SDK" clang -c Sources/RunApp.c -o "$RUNAPP_OBJECT" \
        -mmacosx-version-min="$MACOS_DEPLOYMENT_TARGET" -arch "$BUILD_ARCH"
    xcrun --sdk "$WORKING_SDK" clang Sources/SMAPIWrapper.c -o "$WRAPPER_BINARY" \
        -mmacosx-version-min="$MACOS_DEPLOYMENT_TARGET" -arch "$BUILD_ARCH"
    swiftc -whole-module-optimization -O Sources/*.swift "$RUNAPP_OBJECT" -o "$SWIFT_BINARY" \
        -sdk "$WORKING_SDK" \
        -target "${BUILD_ARCH}-apple-macosx${MACOS_DEPLOYMENT_TARGET}" \
        -F "$SPARKLE_DIR" \
        -framework Sparkle \
        -framework CoreFoundation \
        -framework CoreGraphics \
        -framework ApplicationServices \
        -framework Carbon \
        -Xlinker -rpath -Xlinker @executable_path/../Frameworks
    SWIFT_BINARIES+=("$SWIFT_BINARY")
    WRAPPER_BINARIES+=("$WRAPPER_BINARY")
done
if [ "${#SWIFT_BINARIES[@]}" -eq 1 ]; then
    cp "${SWIFT_BINARIES[0]}" "Starfruit.app/Contents/MacOS/Starfruit"
    cp "${WRAPPER_BINARIES[0]}" "Starfruit.app/Contents/Resources/SMAPIWrapper"
else
    xcrun lipo -create "${SWIFT_BINARIES[@]}" -output "Starfruit.app/Contents/MacOS/Starfruit"
    xcrun lipo -create "${WRAPPER_BINARIES[@]}" -output "Starfruit.app/Contents/Resources/SMAPIWrapper"
fi

echo "Writing macOS Info.plist..."
SPARKLE_KEY_PLIST=""
if [ -n "${SPARKLE_PUBLIC_ED_KEY:-}" ]; then
    SPARKLE_KEY_PLIST=$(
        cat <<EOF
    <key>SUPublicEDKey</key>
    <string>${SPARKLE_PUBLIC_ED_KEY}</string>
EOF
    )
fi

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
    <string>com.bunnygamez.starfruit</string>
    <key>CFBundleName</key>
    <string>Starfruit</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${APP_BUILD}</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 BunnyGamez. Licensed under GPLv3.</string>
    <key>SUFeedURL</key>
    <string>${SPARKLE_FEED_URL}</string>
${SPARKLE_KEY_PLIST}
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
    <string>${MACOS_DEPLOYMENT_TARGET}</string>
</dict>
</plist>
EOF

if [ -f "../Assets/Starfruit_Mac.icns" ]; then
    echo "Copying Starfruit Mac Icon..."
    cp "../Assets/Starfruit_Mac.icns" "Starfruit.app/Contents/Resources/Starfruit.icns"
elif [ -f "Resources/Starfruit.icns" ]; then
    cp "Resources/Starfruit.icns" "Starfruit.app/Contents/Resources/Starfruit.icns"
fi

echo "Signing Native App with ${SIGN_IDENTITY}..."
sign_app_bundle "$RESOLVED_SIGN_IDENTITY"

echo "Done! The Starfruit.app has been built natively."
if [ "$BUILD_ONLY" = true ]; then
    echo "Build-only mode: output is $PWD/Starfruit.app"
    exit 0
fi
echo "Installing Starfruit.app to /Applications..."
rm -rf "/Applications/Starfruit.app"
cp -R "Starfruit.app" "/Applications/Starfruit.app"

echo "Launching Starfruit.app..."
open "/Applications/Starfruit.app"
