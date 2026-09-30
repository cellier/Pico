#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p build/Telos.app/Contents/{MacOS,Resources}
mkdir -p build/AppIcon.iconset
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" assets/AppIcon.png --out "build/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  doubled=$((size * 2))
  sips -z "$doubled" "$doubled" assets/AppIcon.png --out "build/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o build/Telos.app/Contents/Resources/AppIcon.icns
swiftc -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk -target arm64-apple-macos14.0 -swift-version 5 -O -parse-as-library Sources/*.swift -o build/Telos.app/Contents/MacOS/Telos -framework SwiftUI -framework AppKit -framework CoreText -framework EventKit
cp Resources/* build/Telos.app/Contents/Resources/
cp -R Backend build/Telos.app/Contents/Resources/
python3 - <<'PY'
import plistlib, shutil, uuid
from pathlib import Path
root=Path.cwd()
for cache in (root/'build/Telos.app').rglob('__pycache__'):
    shutil.rmtree(cache)
plist={'CFBundleExecutable':'Telos','CFBundleIconFile':'AppIcon.icns','CFBundleIdentifier':'com.telos.mac','CFBundleName':'Telos','CFBundleDisplayName':'Telos','CFBundleShortVersionString':'0.5.0','CFBundleVersion':'5','TelosBuildID':str(uuid.uuid4()),'LSUIElement':True,'CFBundlePackageType':'APPL','LSMinimumSystemVersion':'14.0','NSHighResolutionCapable':True,'NSMicrophoneUsageDescription':'Telos uses the microphone for hold-to-talk dictation and for meetings when you enable meeting capture. Audio is transcribed locally.', 'NSSpeechRecognitionUsageDescription':'Telos transcribes enabled meetings on this Mac and preserves their full transcript.','TelosSpeechPython':str(root/'.runtime/speech-venv/bin/python'),'NSCalendarsFullAccessUsageDescription':'Telos reads your next seven days of Calendar events to display them in the app and menu bar. It does not edit your calendar.','NSAppleEventsUsageDescription':'Telos operates apps to carry out tasks you approve.','TelosPython':str(root/'.runtime/venv/bin/python')}
(root/'build/Telos.app/Contents/Info.plist').write_bytes(plistlib.dumps(plist))
PY
codesign --force --deep --sign - build/Telos.app

# Refresh this bundle only so Finder sees its embedded icon after rebuilding in place.
touch build/Telos.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$PWD/build/Telos.app"
