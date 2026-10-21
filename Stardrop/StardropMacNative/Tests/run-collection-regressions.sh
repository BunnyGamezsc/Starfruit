#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_OUTPUT_DIR="$(mktemp -d "${TMPDIR:-/tmp/}starfruit-collection-regression.XXXXXX")"
trap 'rm -rf "$TEST_OUTPUT_DIR"' EXIT
swiftc Sources/ModModels.swift Sources/ProfileModels.swift Sources/CollectionModels.swift \
    Sources/CollectionReferenceMatcher.swift Sources/CollectionStorage.swift Tests/CollectionRegression.swift \
    Tests/ProfileRoundTripRegression.swift Tests/RevisionRegression.swift \
    -o "$TEST_OUTPUT_DIR/collection-regression"
"$TEST_OUTPUT_DIR/collection-regression"
