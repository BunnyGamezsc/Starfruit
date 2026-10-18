#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_OUTPUT_DIR="$(mktemp -d "${TMPDIR:-/tmp/}starfruit-regression.XXXXXX")"
trap 'rm -rf "$TEST_OUTPUT_DIR"' EXIT
xcrun clang Tests/InputRegression.c -o "$TEST_OUTPUT_DIR/input-regression" \
    -framework ApplicationServices -framework CoreGraphics -framework CoreFoundation -framework Carbon
"$TEST_OUTPUT_DIR/input-regression"
swiftc Sources/NexusClient.swift Sources/NexusChangelog.swift \
    Tests/NexusFixtureStubs.swift Tests/NexusRegression.swift -o "$TEST_OUTPUT_DIR/nexus-regression"
"$TEST_OUTPUT_DIR/nexus-regression"
