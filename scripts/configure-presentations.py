"""Locate the existing local presentation runtime without modifying its packages."""
import json, os
from pathlib import Path
root=Path(__file__).resolve().parents[1]
deps=Path(os.environ.get('TELOS_DOCUMENT_DEPENDENCIES',str(Path.home()/'.cache/codex-runtimes/codex-primary-runtime/dependencies')))
base=Path.home()/'.codex/plugins/cache/openai-primary-runtime/presentations'
skills=sorted(base.glob('*/skills/presentations'),key=lambda p:p.stat().st_mtime,reverse=True)
if not skills: raise SystemExit('Presentation skill runtime missing. Install the Presentations plugin or set up the local document runtime first.')
config={'node':str(deps/'node/bin/node'),'modules':str(deps/'node/node_modules'),'python':str(deps/'python/bin/python3'),'skill':str(skills[0])}
for key in ('node','modules','python','skill'):
 if not Path(config[key]).exists(): raise SystemExit('Missing presentation runtime: '+key)
(root/'.runtime').mkdir(exist_ok=True)
(root/'.runtime/presentation-runtime.json').write_text(json.dumps(config,indent=2))
print('Presentation runtime configured')
