#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
out="${1:-$PWD/build/paperkit-tests}"
mkdir -p "$out"
sdk="${TELOS_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
xcrun swiftc -sdk "$sdk" -swift-version 5 -parse-as-library Sources/ScreenshotPaperKit.swift Sources/ScreenshotAnnotation.swift tests/PaperKitScreenshotTests.swift -o "$out/paperkit" -framework PaperKit -framework PencilKit
"$out/paperkit" "$out"
xcrun swiftc -sdk "$sdk" Sources/ScreenshotController.swift tests/ScreenshotTests.swift -o "$out/capture"
"$out/capture"
xcrun swiftc -sdk "$sdk" Sources/ScreenshotAnnotation.swift tests/ScreenshotAnnotationTests.swift -o "$out/annotation"
"$out/annotation" "$out"
.runtime/venv/bin/python -B -m unittest discover -s tests -p 'test_screenshot_annotation.py'
.runtime/image-venv/bin/python -B -m unittest discover -s tests -p 'test_local_image_edit.py'
