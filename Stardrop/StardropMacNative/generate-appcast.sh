#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -x ".deps/bin/generate_appcast" ]; then
    echo "Sparkle tools missing. Run ./build-native.sh first."
    exit 1
fi

if [ "$#" -ne 2 ] || [[ "$2" != https://*/ ]]; then
    echo "Usage: ./generate-appcast.sh /path/to/update/archives https://github.com/BunnyGamezsc/Starfruit/releases/download/vVERSION/" >&2
    exit 2
fi

SPARKLE_KEY_ACCOUNT="${SPARKLE_KEY_ACCOUNT:-com.bunnygamez.starfruit}"
EXPECTED_KEY="${SPARKLE_PUBLIC_ED_KEY:-$(tr -d '\r\n' < sparkle-public-key.txt)}"
KEYCHAIN_PUBLIC_KEY="$(.deps/bin/generate_keys --account "$SPARKLE_KEY_ACCOUNT" -p)"
if [ "$KEYCHAIN_PUBLIC_KEY" != "$EXPECTED_KEY" ]; then
    echo "The Sparkle Keychain account does not match Starfruit's public update key. No appcast was generated." >&2
    exit 1
fi

.deps/bin/generate_appcast --account "$SPARKLE_KEY_ACCOUNT" \
    --download-url-prefix "$2" --link https://github.com/BunnyGamezsc/Starfruit "$1"
