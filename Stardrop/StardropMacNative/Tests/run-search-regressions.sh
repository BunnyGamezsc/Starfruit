#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_OUTPUT_DIR="$(mktemp -d "${TMPDIR:-/tmp/}starfruit-search.XXXXXX")"
trap 'rm -rf "$TEST_OUTPUT_DIR"' EXIT
swiftc Sources/NexusModSearch.swift Tests/SearchRegression.swift -o "$TEST_OUTPUT_DIR/search-regression"
"$TEST_OUTPUT_DIR/search-regression" "$@"
