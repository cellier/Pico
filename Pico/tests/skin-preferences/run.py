from pathlib import Path
import subprocess

root=Path(__file__).resolve().parents[2]
source=(root / "main.swift").read_text()
# Execute the production preference type in isolation: no AppKit or running app.
start=source.index("enum PetSkin:")
end=source.index("\nclass PetPanel:",start)
tests=Path(__file__).with_name("PreferenceTests.swift").read_text()
subprocess.run(["swift", "-"],input="import Foundation\n"+source[start:end]+"\n"+tests,text=True,check=True)
