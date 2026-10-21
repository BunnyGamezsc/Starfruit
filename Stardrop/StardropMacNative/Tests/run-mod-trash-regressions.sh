#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_OUTPUT_DIR="$(mktemp -d "${TMPDIR:-/tmp/}starfruit-trash-regression.XXXXXX")"
trap 'rm -rf "$TEST_OUTPUT_DIR"' EXIT
swiftc Sources/ModModels.swift Sources/NativeModTrash.swift Tests/ModTrashRegression.swift \
    -o "$TEST_OUTPUT_DIR/mod-trash-regression"
"$TEST_OUTPUT_DIR/mod-trash-regression"
