from pathlib import Path
import subprocess

root=Path(__file__).resolve().parents[2]
source=(root / "main.swift").read_text()
# Run the production geometry helper without launching Pico or touching real preferences.
start=source.index("enum PetScreenFacing {")
end=source.index("\nenum PetVisualState {",start)
tests=Path(__file__).with_name("native-direction-tests.swift").read_text()
subprocess.run(["swift", "-"],input="import Cocoa\n"+source[start:end]+"\n"+tests,text=True,check=True)
