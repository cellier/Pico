#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
test_root="$(mktemp -d /tmp/PicoZoomCalendarStoreTests.XXXXXX)"
trap 'rm -rf "$test_root"' EXIT
sdk="${TELOS_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
[[ -d "$sdk" ]] || sdk="$(xcrun --sdk macosx --show-sdk-path)"
swiftc -D TELOS_TEST -whole-module-optimization -Onone -sdk "$sdk" \
    -target arm64-apple-macos14.0 -swift-version 5 -parse-as-library \
    Sources/*.swift tests/ZoomCalendarStoreTests.swift -o "$test_root/Test" \
    -framework SwiftUI -framework AppKit -framework CoreText -framework EventKit \
    -Xlinker -weak_framework -Xlinker PaperKit -Xlinker -weak_framework -Xlinker PencilKit
"$test_root/Test"
