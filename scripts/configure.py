"""Interactive local-only provider setup; never put a key in the source tree."""
import getpass, json, os
from pathlib import Path
root=Path.home()/'Library/Application Support/Telos'
root.mkdir(parents=True,exist_ok=True); os.chmod(root,0o700)
f=root/'config.json'
if f.exists():
    print('Using existing private Pico configuration.')
else:
    key=getpass.getpass('DeepSeek API key: ').strip()
    if not key: raise SystemExit('A key is required.')
    f.write_text(json.dumps({'api_key':key,'base_url':'https://api.deepseek.com','model':'deepseek-flash'}))
    os.chmod(f,0o600)
    print('Configuration saved privately.')
