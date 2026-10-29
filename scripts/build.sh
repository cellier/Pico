#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
app="${PICO_APP_OUTPUT:-${TELOS_APP_OUTPUT:-$PWD/build/Pico.app}}"
APP_BUILD_TARGET="$app" python3 - <<'PYGUARD'
import os, plistlib, subprocess
from pathlib import Path
target = Path(os.environ["APP_BUILD_TARGET"]).resolve()
binaries = {str(target / "Contents/MacOS" / name) for name in ("Pico", "Telos")}
info = target / "Contents/Info.plist"
if info.exists():
    executable = plistlib.loads(info.read_bytes()).get("CFBundleExecutable")
    if executable: binaries.add(str(target / "Contents/MacOS" / executable))
commands = subprocess.run(["ps", "-axo", "command="], capture_output=True, text=True, check=True).stdout.splitlines()
if any(line.strip() == binary or line.strip().startswith(binary + " ") for binary in binaries for line in commands):
    raise SystemExit("Refusing to overwrite the running app. Build to a separate candidate path first.")
PYGUARD
mkdir -p "$app"/Contents/{MacOS,Resources}
mkdir -p build/AppIcon.iconset
swift scripts/build-app-icon.swift assets/PicoAppIcon.png build/PicoAppIcon.png
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" build/PicoAppIcon.png --out "build/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  doubled=$((size * 2))
  sips -z "$doubled" "$doubled" build/PicoAppIcon.png --out "build/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
icon_name="$(python3 -c 'import hashlib; from pathlib import Path; print("PicoAppIcon-" + hashlib.sha256(Path("assets/PicoAppIcon.png").read_bytes()).hexdigest()[:12] + ".icns")')"
iconutil -c icns build/AppIcon.iconset -o "$app/Contents/Resources/$icon_name"
sdk="${TELOS_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
[[ -d "$sdk" ]] || sdk="$(xcrun --sdk macosx --show-sdk-path)"
diagnostic_flags=()
[[ "${TELOS_DIAGNOSTICS:-0}" == "1" ]] && diagnostic_flags=(-D TELOS_DIAGNOSTICS)
swiftc "${diagnostic_flags[@]}" -sdk "$sdk" -target arm64-apple-macos14.0 -swift-version 5 -O -parse-as-library Sources/*.swift -o "$app/Contents/MacOS/Pico" -framework SwiftUI -framework AppKit -framework CoreText -Xlinker -weak_framework -Xlinker PaperKit -Xlinker -weak_framework -Xlinker PencilKit
# The desktop character ships inside Pico; it is never a separate user install.
# Its existing bundle identifier preserves saved skins and voice preferences.
PICO_APP_OUTPUT="${app:A}/Contents/Helpers/Pico Desktop.app" zsh Pico/build.sh
python3 scripts/build-pico-avatar.py
cp -R Resources/. "$app/Contents/Resources/"
cp -R Backend "$app/Contents/Resources/"
if [[ -f .runtime/presentation-runtime.json ]]; then
  cp .runtime/presentation-runtime.json "$app/Contents/Resources/Backend/presentation-runtime.json"
fi
TELOS_APP_OUTPUT="$app" TELOS_APP_ICON="$icon_name" python3 - <<'PY'
import os, plistlib, shutil, uuid
from pathlib import Path
root=Path.cwd()
app=Path(os.environ["TELOS_APP_OUTPUT"])
for cache in app.rglob('__pycache__'):
    shutil.rmtree(cache)
plist={'CFBundleExecutable':'Pico','CFBundleIconFile':os.environ['TELOS_APP_ICON'],'CFBundleIdentifier':'com.telos.mac','CFBundleName':'Pico','CFBundleDisplayName':'Pico','CFBundleShortVersionString':'0.6.0','CFBundleVersion':'7','TelosBuildID':str(uuid.uuid4()),'TelosScreenshotEngine':'PaperKit','LSUIElement':False,'CFBundlePackageType':'APPL','LSMinimumSystemVersion':'14.0','NSHighResolutionCapable':True,'NSMicrophoneUsageDescription':'Pico uses the microphone for hold-to-talk dictation and for meetings when you enable meeting capture. Speech uses Bailian when enabled, or local recognition otherwise.', 'NSCameraUsageDescription':'Pico shows your camera in screen recordings when you turn the camera on.', 'NSSpeechRecognitionUsageDescription':'Pico transcribes enabled meetings on this Mac and preserves their full transcript.','TelosSpeechPython':str(root/'.runtime/speech-venv/bin/python'),'TelosImagePython':str(root/'.runtime/image-venv/bin/python'),'TelosImageModel':str(root/'.runtime/image-model'),'NSAppleEventsUsageDescription':'Pico operates apps to carry out tasks you approve.','TelosPython':str(root/'.runtime/venv/bin/python')}
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(plist))
PY
python3 scripts/sign-local.py "$app"

# Refresh this bundle only so Finder sees its embedded icon after rebuilding in place.
touch "$app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app"
