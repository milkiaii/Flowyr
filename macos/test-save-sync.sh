#!/usr/bin/env bash
set -euo pipefail
FLOWYR_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
FLOWYR_TEST_ROOT="$FLOWYR_ROOT/build/macos-save-sync-tests"
mkdir -p "$FLOWYR_TEST_ROOT/Sources/Vita3K" "$FLOWYR_TEST_ROOT/Tests/SaveSyncTests"
cp "$FLOWYR_ROOT/ios/Vita3K/App/Localization.swift" "$FLOWYR_ROOT/ios/Vita3K/App/SaveSyncEngine.swift" "$FLOWYR_ROOT/ios/Vita3K/App/CloudSaveSync.swift" "$FLOWYR_TEST_ROOT/Sources/Vita3K/"
cp "$FLOWYR_ROOT/macos/CloudSaveBridge.swift" "$FLOWYR_TEST_ROOT/Sources/Vita3K/"
cp "$FLOWYR_ROOT/ios/Vita3K/InputTests/SaveSyncTests.swift" "$FLOWYR_TEST_ROOT/Tests/SaveSyncTests/"
cat > "$FLOWYR_TEST_ROOT/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "FlowyrSaveSyncTests", platforms: [.macOS(.v13)], targets: [
    .target(name: "Vita3K"),
    .testTarget(name: "SaveSyncTests", dependencies: ["Vita3K"])
])
SWIFT
swift test --package-path "$FLOWYR_TEST_ROOT"
