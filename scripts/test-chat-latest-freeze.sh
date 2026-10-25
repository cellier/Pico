#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
test_root="$(mktemp -d /tmp/PicoChatLatestFreezeTests.XXXXXX)"
trap 'rm -rf "$test_root"' EXIT
sdk="${TELOS_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
[[ -d "$sdk" ]] || sdk="$(xcrun --sdk macosx --show-sdk-path)"
swiftc -D TELOS_TEST -sdk "$sdk" -target arm64-apple-macos14.0 \
    -swift-version 5 -parse-as-library Sources/*.swift tests/PicoChatLatestFreezeTests.swift \
    -o "$test_root/Test" -framework SwiftUI -framework AppKit -framework CoreText -framework EventKit \
    -Xlinker -weak_framework -Xlinker PaperKit -Xlinker -weak_framework -Xlinker PencilKit
# A native layout loop can starve a main-queue timer. Bound the child externally
# as well, and stop only this test process if its memory starts growing.
python3 - "$test_root/Test" "$test_root/output.log" <<'PY'
import subprocess
import sys
import time
from pathlib import Path

executable, output = sys.argv[1:]
reason = None
peak = 0
with open(output, 'w') as log:
    child = subprocess.Popen([executable], stdout=log, stderr=subprocess.STDOUT)
    started = time.monotonic()
    while child.poll() is None:
        reading = subprocess.run(['ps', '-p', str(child.pid), '-o', 'rss='], capture_output=True, text=True)
        rss = int(reading.stdout.strip() or '0')
        peak = max(peak, rss)
        if rss > 750_000:
            reason = 'test exceeded the 750 MB memory limit'
        elif time.monotonic() - started > 75:
            reason = 'test exceeded the external 75 second deadline'
        if reason:
            child.terminate()
            try:
                child.wait(timeout=2)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
            break
        time.sleep(0.1)
print(Path(output).read_text())
print('Peak RSS:', peak, 'KB')
if reason:
    print('FAIL:', reason)
sys.exit(1 if reason or child.returncode else 0)
PY
