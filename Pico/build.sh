#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
python3 bundle.py
app="${PICO_APP_OUTPUT:-$PWD/build/Sprout.app}"
APP_BUILD_TARGET="$app" python3 - <<'PYGUARD'
import os, subprocess
from pathlib import Path
binary = str(Path(os.environ["APP_BUILD_TARGET"]).resolve() / "Contents/MacOS/Sprout")
commands = subprocess.run(["ps", "-axo", "command="], capture_output=True, text=True, check=True).stdout.splitlines()
if any(line.strip() == binary or line.strip().startswith(binary + " ") for line in commands):
    raise SystemExit("Refusing to overwrite the running app. Build to a separate candidate path first.")
PYGUARD
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
swiftc -module-cache-path build/ModuleCache -O main.swift ApplicationLocator.swift CloudSpeech.swift CloudRecognition.swift SpeechText.swift -o "$app/Contents/MacOS"/Sprout -framework Cocoa -framework WebKit -framework AVFoundation -framework Security
cp assets/index.html "$app/Contents/Resources/PicoDesktop.html"
cp assets/asr-mixed-check.wav "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>local.original.sprout</string><key>CFBundleName</key><string>Pico</string><key>CFBundleDisplayName</key><string>Pico</string><key>CFBundleExecutable</key><string>Sprout</string><key>CFBundlePackageType</key><string>APPL</string><key>NSMicrophoneUsageDescription</key><string>Pico records only while you hold the character. Speech is recognized by Bailian when enabled, or locally by Pico.</string><key>LSUIElement</key><true/><key>NSHighResolutionCapable</key><true/></dict></plist>
PLIST
codesign --force --sign - "$app"
