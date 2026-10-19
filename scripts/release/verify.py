"""No API credentials, original venv, user caches or network needed for these checks."""
import json, os, plistlib, shutil, subprocess, sys, tempfile
from pathlib import Path
app=Path(sys.argv[1]).resolve()
plist=plistlib.loads((app/'Contents/Info.plist').read_bytes())
assert not plist['TelosPython'].startswith('/') and not plist['TelosSpeechPython'].startswith('/')
res=app/'Contents/Resources'
with tempfile.TemporaryDirectory(prefix='Telos release check ') as temp:
    home=Path(temp)/'clean-home';home.mkdir()
    env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','HOME':str(home),'TMPDIR':temp,'TELOS_DATA_DIR':str(home/'data'),'HF_HUB_OFFLINE':'1','PYTHONDONTWRITEBYTECODE':'1','HERMES_HOME':str(home/'hermes')}
    script='''import os,sys,json,tempfile,importlib.metadata
from pathlib import Path
from hermes_cli.version_info import get_version_info
assert get_version_info().base_version == '0.22.0'
assert importlib.metadata.version('phone-harness') == '0.3.2'
sys.path.insert(0, str(Path(sys.prefix).resolve().parents[1]/'Backend'))
from phone_bridge import prepare_phone_home
assert prepare_phone_home(Path(os.environ['TELOS_DATA_DIR']), Path(os.environ['HERMES_HOME']))
from run_agent import AIAgent
import macos_harness, AppKit, ApplicationServices
import docx, openpyxl, pptx, reportlab, pymupdf
from playwright.sync_api import sync_playwright
assert sys.dont_write_bytecode
root=Path(sys.prefix).resolve()
bundle_root = root.parents[3]
assert all(Path(p).resolve().is_relative_to(bundle_root) for p in sys.path if p and Path(p).exists()), sys.path
with sync_playwright() as p:
    browser=p.chromium.launch(headless=True)
    page=browser.new_page();page.set_content('<title>Telos packaging test</title><h1>Ready</h1>')
    assert page.title()=='Telos packaging test'
    page.screenshot(path=os.path.join(os.environ['TMPDIR'],'browser.png'));browser.close()
print('PASS bundled Hermes, Harness, native bridges, document libraries and Chromium')
'''
    subprocess.run([str(res/plist['TelosPython']),'-c',script],cwd=temp,env=env,check=True,timeout=180)
    script='''import os,sys
from pathlib import Path
from mlx_audio.stt import load
p=Path(os.environ['TELOS_SPEECH_MODEL'])
assert (p/'model.safetensors').exists()
model=load(p)
print('PASS bundled offline speech model loads without user cache')
'''
    subprocess.run([str(res/plist['TelosSpeechPython']),'-c',script],cwd=temp,env=env,check=True,timeout=180)
# Refuse to ship personal credentials even if a packaging step accidentally copied one.
private=Path.home()/'Library/Application Support/Telos/config.json'
key=json.loads(private.read_text()).get('api_key','').encode() if private.exists() else b''
for p in app.rglob('*'):
    if not p.is_file() or p.is_symlink():continue
    if key and len(key)>10:
        with p.open('rb') as f:
            tail=b''
            while data:=f.read(1024*1024):
                assert key not in tail+data, f'Personal API key found in {p.relative_to(app)}'
                tail=data[-len(key):]
print('PASS relative interpreter paths and no personal API key in app bundle')
