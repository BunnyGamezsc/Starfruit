#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

bash Tests/run-network-input-regressions.sh
bash Tests/run-search-regressions.sh
bash Tests/run-collection-regressions.sh
bash Tests/run-migration-regressions.sh
bash Tests/run-mod-trash-regressions.sh

TEST_OUTPUT_DIR="$(mktemp -d "${TMPDIR:-/tmp/}starfruit-theme.XXXXXX")"
trap 'rm -rf "$TEST_OUTPUT_DIR"' EXIT
swiftc -whole-module-optimization -Onone -parse-as-library \
    Sources/DownloadManager.swift Sources/NativeModInstallTarget.swift \
    Tests/DownloadRegression.swift -o "$TEST_OUTPUT_DIR/download-regression"
"$TEST_OUTPUT_DIR/download-regression"
swiftc -whole-module-optimization -Onone -parse-as-library \
    Sources/StateCompatibility.swift Sources/NativeLocalization.swift \
    Sources/NativeThemeManager.swift Sources/StarfruitTheme.swift \
    Tests/ThemeRegression.swift -o "$TEST_OUTPUT_DIR/theme-regression"
"$TEST_OUTPUT_DIR/theme-regression"
