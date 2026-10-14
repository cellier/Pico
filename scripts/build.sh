#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
app="${TELOS_APP_OUTPUT:-$PWD/build/Telos.app}"
APP_BUILD_TARGET="$app" python3 - <<'PYGUARD'
import os, subprocess
from pathlib import Path
binary = str(Path(os.environ["APP_BUILD_TARGET"]).resolve() / "Contents/MacOS/Telos")
commands = subprocess.run(["ps", "-axo", "command="], capture_output=True, text=True, check=True).stdout.splitlines()
if any(line.strip() == binary or line.strip().startswith(binary + " ") for line in commands):
    raise SystemExit("Refusing to overwrite the running app. Build to a separate candidate path first.")
PYGUARD
mkdir -p "$app"/Contents/{MacOS,Resources}
mkdir -p build/AppIcon.iconset
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" assets/AppIcon.png --out "build/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  doubled=$((size * 2))
  sips -z "$doubled" "$doubled" assets/AppIcon.png --out "build/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o "$app/Contents/Resources/AppIcon.icns"
sdk="${TELOS_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
[[ -d "$sdk" ]] || sdk="$(xcrun --sdk macosx --show-sdk-path)"
diagnostic_flags=()
[[ "${TELOS_DIAGNOSTICS:-0}" == "1" ]] && diagnostic_flags=(-D TELOS_DIAGNOSTICS)
swiftc "${diagnostic_flags[@]}" -sdk "$sdk" -target arm64-apple-macos14.0 -swift-version 5 -O -parse-as-library Sources/*.swift -o "$app/Contents/MacOS/Telos" -framework SwiftUI -framework AppKit -framework CoreText -framework EventKit -Xlinker -weak_framework -Xlinker PaperKit -Xlinker -weak_framework -Xlinker PencilKit
cp Resources/* "$app/Contents/Resources/"
cp -R Backend "$app/Contents/Resources/"
if [[ -f .runtime/presentation-runtime.json ]]; then
  cp .runtime/presentation-runtime.json "$app/Contents/Resources/Backend/presentation-runtime.json"
fi
TELOS_APP_OUTPUT="$app" python3 - <<'PY'
import os, plistlib, shutil, uuid
from pathlib import Path
root=Path.cwd()
app=Path(os.environ["TELOS_APP_OUTPUT"])
for cache in app.rglob('__pycache__'):
    shutil.rmtree(cache)
plist={'CFBundleExecutable':'Telos','CFBundleIconFile':'AppIcon.icns','CFBundleIdentifier':'com.telos.mac','CFBundleName':'Telos','CFBundleDisplayName':'Telos','CFBundleShortVersionString':'0.5.0','CFBundleVersion':'5','TelosBuildID':str(uuid.uuid4()),'TelosScreenshotEngine':'PaperKit','LSUIElement':True,'CFBundlePackageType':'APPL','LSMinimumSystemVersion':'14.0','NSHighResolutionCapable':True,'NSMicrophoneUsageDescription':'Telos uses the microphone for hold-to-talk dictation and for meetings when you enable meeting capture. Speech uses Bailian when enabled, or local recognition otherwise.', 'NSCameraUsageDescription':'Telos shows your camera in screen recordings when you turn the camera on.', 'NSSpeechRecognitionUsageDescription':'Telos transcribes enabled meetings on this Mac and preserves their full transcript.','TelosSpeechPython':str(root/'.runtime/speech-venv/bin/python'),'TelosImagePython':str(root/'.runtime/image-venv/bin/python'),'TelosImageModel':str(root/'.runtime/image-model'),'NSCalendarsFullAccessUsageDescription':'Telos reads your next seven days of Calendar events to display them in the app and menu bar. It does not edit your calendar.','NSAppleEventsUsageDescription':'Telos operates apps to carry out tasks you approve.','TelosPython':str(root/'.runtime/venv/bin/python')}
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(plist))
PY
python3 scripts/sign-local.py "$app"

# Refresh this bundle only so Finder sees its embedded icon after rebuilding in place.
touch "$app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app"
