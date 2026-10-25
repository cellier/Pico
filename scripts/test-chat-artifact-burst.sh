#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
test_root="$(mktemp -d /tmp/PicoChatArtifactBurstTests.XXXXXX)"
trap 'rm -rf "$test_root"' EXIT
test_app="$test_root/PicoChatArtifactBurstTests.app"
mkdir -p "$test_app/Contents/MacOS" "$test_app/Contents/Resources/Backend"
cp tests/fixtures/chat_artifact_burst_worker.py "$test_app/Contents/Resources/Backend/worker.py"
PICO_TEST_APP="$test_app" python3 - <<'PY'
import os
import plistlib
import sys
from pathlib import Path
app = Path(os.environ['PICO_TEST_APP'])
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleExecutable': 'Test',
    'CFBundleIdentifier': 'com.pico.tests.artifact-burst',
    'CFBundleName': 'PicoChatArtifactBurstTests',
    'PicoArtifactBurstFixture': True,
    'TelosPython': sys.executable,
}))
PY
sdk="${TELOS_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
[[ -d "$sdk" ]] || sdk="$(xcrun --sdk macosx --show-sdk-path)"
swiftc -D TELOS_TEST -whole-module-optimization -Onone -sdk "$sdk" \
    -target arm64-apple-macos14.0 -swift-version 5 -parse-as-library \
    Sources/*.swift tests/PicoChatArtifactBurstTests.swift \
    -o "$test_app/Contents/MacOS/Test" \
    -framework SwiftUI -framework AppKit -framework CoreText -framework EventKit \
    -Xlinker -weak_framework -Xlinker PaperKit \
    -Xlinker -weak_framework -Xlinker PencilKit
"$test_app/Contents/MacOS/Test"
