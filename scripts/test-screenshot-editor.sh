#!/bin/bash
set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/telos-paperkit-tests.XXXXXX")"
trap 'rm -rf "$work"' EXIT

swiftc -swift-version 5 -parse-as-library \
  Sources/ScreenshotMarkupDocument.swift tests/ScreenshotMarkupDocumentTests.swift \
  -o "$work/document-tests"
"$work/document-tests"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "SKIP: AppKit/PaperKit compilation, rendering, and UI checks require a Mac."
  exit 0
fi
major="$(sw_vers -productVersion | cut -d. -f1)"
if (( major < 26 )); then
  echo "ERROR: native PaperKit tests require macOS 26 or later." >&2
  exit 1
fi
sdk="${TELOS_SDK:-$(xcrun --sdk macosx --show-sdk-path)}"
sources=(Sources/ScreenshotMarkupDocument.swift Sources/ScreenshotEditor.swift Sources/ScreenshotController.swift)
flags=(-sdk "$sdk" -target "$(uname -m)-apple-macos26.0" -swift-version 5 -parse-as-library -D TELOS_REQUIRE_PAPERKIT)
frameworks=(-framework AppKit -framework Carbon -framework ImageIO -framework UniformTypeIdentifiers -framework PaperKit)
xcrun swiftc "${flags[@]}" "${sources[@]}" tests/ScreenshotEditorTests.swift "${frameworks[@]}" -o "$work/editor-tests"
"$work/editor-tests"
# Existing capture tests cancel before screencapture launches; they do not take a screenshot.
xcrun swiftc "${flags[@]}" "${sources[@]}" tests/ScreenshotTests.swift "${frameworks[@]}" -o "$work/capture-tests"
"$work/capture-tests"
echo "Native model/rendering checks finished. Run the UI acceptance checklist in docs/SCREENSHOT_EDITOR.md."
