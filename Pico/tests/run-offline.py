"""Run deterministic Pico checks without UI, real credentials, or network requests."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
node = os.environ.get("NODE", "node")

def run(args, **kwargs):
    subprocess.run(args, cwd=root, check=True, **kwargs)

run([node, "--test", "tests/eyes/motion.test.cjs", "tests/skins/skin-interactions.test.cjs", "tests/screen-facing/facing.test.cjs"])
run(["python3", "tests/skin-preferences/run.py"])
run(["python3", "tests/screen-facing/run-native.py"])

with tempfile.TemporaryDirectory(prefix="pico-offline-tests-") as temporary:
    folder = Path(temporary)
    production = ["CloudSpeech.swift", "CloudRecognition.swift", "SpeechText.swift"]
    frameworks = ["-framework", "Cocoa", "-framework", "AVFoundation", "-framework", "Security"]
    for name, test, options in [
        ("recognition", "tests/recognition/RecognitionProtocolTests.swift", ["-parse-as-library"]),
        ("credentials", "tests/shared-credentials/main.swift", []),
    ]:
        output = folder / name
        run(["swiftc", "-module-cache-path", str(folder / "ModuleCache"), *options, *production, test, *frameworks, "-o", str(output)])
        run([str(output)])

print("PASS: offline Pico suite; no app launch, microphone, playback, real credentials, or network")
