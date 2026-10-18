#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_OUTPUT_DIR="$(mktemp -d "${TMPDIR:-/tmp/}starfruit-migration.XXXXXX")"
trap 'rm -rf "$TEST_OUTPUT_DIR"' EXIT
swiftc -whole-module-optimization -Onone -parse-as-library \
    Sources/ModModels.swift Sources/ProfileModels.swift Sources/CollectionModels.swift \
    Sources/CollectionReferenceMatcher.swift Sources/CollectionStorage.swift \
    Sources/LegacyDataMigration.swift Sources/LegacyCollectionMigration.swift \
    Tests/MigrationRegression.swift -o "$TEST_OUTPUT_DIR/migration-regression"
"$TEST_OUTPUT_DIR/migration-regression"
