#!/bin/bash
# Build and run the test harness against the fixtures.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
swiftc -swift-version 5 -o "$OUT/tests" \
    "$ROOT/Sources/Usage.swift" "$ROOT/Sources/Account.swift" "$ROOT/Tests/main.swift"
"$OUT/tests" "$ROOT/Tests/fixtures"
