"""Build a relocatable, credential-free Apple Silicon preview DMG."""
import hashlib, json, os, plistlib, shutil, subprocess, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
os.chdir(ROOT)
VERSION = '0.5.1'
DIST = ROOT / 'dist'
APP = DIST / 'stage/Telos.app'
RES = APP / 'Contents/Resources'
RUNTIME = RES / 'Runtime'
PINS = json.loads((ROOT / 'scripts/runtime-pins.json').read_text())

def run(*args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, **kwargs)

def ignore(directory, names):
    return [n for n in names if n in {'.git','__pycache__','.DS_Store'} or n.endswith('.pyc') or n.startswith('__editable__')]

for name, pin in PINS.items():
    if pin.get('kind') == 'plugin': continue
    run(sys.executable, ROOT/'scripts/runtime-checkout.py', name, '--check')
if '--skip-build' not in sys.argv: run('./scripts/build.sh')
DIST.mkdir(exist_ok=True)
if (DIST / 'stage').exists(): shutil.rmtree(DIST / 'stage')
shutil.copytree(ROOT / 'build/Telos.app', APP, symlinks=True, ignore=ignore)
runtime_sites = {}
for name, env in [('main','venv'), ('speech','speech-venv')]:
    source = ROOT / '.runtime' / env
    minor = subprocess.check_output([str(source/'bin/python'), '-c', 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")'], text=True).strip()
    if name == 'main' and minor != PINS['hermes-agent']['python']:
        raise RuntimeError(f'Hermes {PINS["hermes-agent"]["version"]} requires the reviewed Python {PINS["hermes-agent"]["python"]} runtime; found {minor}.')
    lib = f'lib/python{minor}'
    base = Path(subprocess.check_output([str(source/'bin/python'), '-c', 'import sys; print(sys.base_prefix)'], text=True).strip())
    target = RUNTIME / name
    shutil.copytree(base, target, symlinks=True, ignore=ignore)
    (target/lib/'EXTERNALLY-MANAGED').unlink(missing_ok=True)
    site = target / lib / 'site-packages'
    runtime_sites[name] = site
    shutil.copytree(source / lib / 'site-packages', site, dirs_exist_ok=True, symlinks=True, ignore=ignore)
    # No development-only path injection or installer provenance in distributed environments.
    for p in site.glob('*.pth'):
        if str(ROOT) in p.read_text() or '__editable__' in p.read_text(): p.unlink()
    for p in site.rglob('direct_url.json'): p.unlink()
    for p in (target/'bin').iterdir():
        if p.name not in {'python','python3',f'python{minor}'} and (p.is_file() or p.is_symlink()): p.unlink()
    (site/'sitecustomize.py').write_text('''import os, sys
sys.dont_write_bytecode = True
from pathlib import Path
root = Path(__file__).resolve().parents[4]
os.environ['PLAYWRIGHT_BROWSERS_PATH'] = str(root / 'browsers')
os.environ['TELOS_SPEECH_MODEL'] = str(root / 'models/Qwen3-ASR-0.6B-4bit')
os.environ['PYTHONDONTWRITEBYTECODE'] = '1'
os.environ['HF_HUB_OFFLINE'] = '1'
''')
# Hermes is distributed as a source checkout, not a wheel. Vendor only tracked
# files at the pinned commit; no .git metadata, local config or runtime history.
hermes = RUNTIME/'hermes'
hermes.mkdir(exist_ok=True)
source = ROOT/'.runtime/hermes-agent'
tracked = subprocess.check_output(['git','-C',str(source),'ls-files','-z']).decode().split('\0')
for name in filter(None, tracked):
    if name.split('/')[0] in {'.github', 'contributors', 'tests', 'docs', 'website'}: continue
    src=source/name
    if src.is_file():
        dst=hermes/name; dst.parent.mkdir(parents=True,exist_ok=True); shutil.copy2(src,dst)
pin = PINS['hermes-agent']
run(ROOT/'.runtime/venv/bin/python', source/'scripts/write_install_stamp.py',
    '--output', hermes/'install-stamp.json', '--commit', pin['commit'],
    '--base-version', pin['version'], '--display-version', pin['version'],
    '--distance', '0', '--source', 'build', '--update-mechanism', 'external')
run(sys.executable, ROOT/'scripts/runtime-phone.py', '--stage', RUNTIME/'plugins/phone-harness')
site=runtime_sites['main']
with (site/'sitecustomize.py').open('a') as f:
    f.write("import sys\nsys.path.insert(0, str(root / 'hermes'))\n")
run('uv','pip','install','--python',RUNTIME/'main/bin/python3','--no-deps','--reinstall',ROOT/'.runtime/macos-harness')
for p in RUNTIME.rglob('direct_url.json'): p.unlink()
for p in RUNTIME.rglob('__pycache__'): shutil.rmtree(p)
# Include the exact browser distribution expected by the pinned Playwright version.
browser_source = Path(os.environ.get('PLAYWRIGHT_BROWSERS_PATH', str(Path.home()/'Library/Caches/ms-playwright')))
for source in browser_source.iterdir():
    if source.is_dir() and source.name.startswith(('chromium-', 'chromium_headless_shell-', 'ffmpeg-')):
        shutil.copytree(source, RUNTIME/'browsers'/source.name, symlinks=True, ignore=ignore)
model_root = Path.home()/'.cache/huggingface/hub/models--mlx-community--Qwen3-ASR-0.6B-4bit/snapshots/313d850181767edf09f00a9c289becca70e58cd0'
shutil.copytree(model_root, RUNTIME/'models/Qwen3-ASR-0.6B-4bit', symlinks=False, ignore=ignore)
licenses = RES/'ThirdPartyNotices'; licenses.mkdir(exist_ok=True)
license_file = next(runtime_sites['speech'].glob('huggingface_hub-*.dist-info/licenses/LICENSE'))
shutil.copy2(license_file, licenses/'Apache-2.0.txt')
for name in ['hermes-agent','macos-harness']:
    shutil.copy2(ROOT/'.runtime'/name/'LICENSE',licenses/(name+'-LICENSE'))
(licenses/'README.txt').write_text('Python and bundled packages retain their license files and distribution metadata in Runtime.\nThe Qwen ASR model card and licensing information are in Runtime/models.\nChromium includes its upstream license resources.\n')
plist_path = APP/'Contents/Info.plist'
plist = plistlib.loads(plist_path.read_bytes())
plist.update(CFBundleShortVersionString=VERSION,CFBundleVersion='6',LSMinimumSystemVersion='26.0',TelosPython='Runtime/main/bin/python3',TelosSpeechPython='Runtime/speech/bin/python3')
plist_path.write_bytes(plistlib.dumps(plist))
# Fail on escaping links and developer-specific dynamic-library load paths.
for p in APP.rglob('*'):
    if p.is_symlink() and not p.exists(): raise RuntimeError(f'Broken symlink: {p.relative_to(APP)}')
    if p.is_symlink() and not p.resolve().is_relative_to(APP.resolve()): raise RuntimeError(f'External symlink: {p.relative_to(APP)}')
    if not p.is_file() or p.is_symlink(): continue
    with p.open('rb') as f: magic=f.read(4)
    if magic not in [b'\xcf\xfa\xed\xfe',b'\xce\xfa\xed\xfe',b'\xca\xfe\xba\xbe',b'\xca\xfe\xba\xbf']: continue
    # otool interprets parentheses in Chromium helper names as archive members.
    with tempfile.TemporaryDirectory(prefix='telos-macho-') as temp:
        inspect = Path(temp)/'binary'
        inspect.symlink_to(p.resolve())
        ids=[line.strip() for line in subprocess.check_output(['otool','-D',str(inspect)],text=True).splitlines() if not line.endswith(':')]
    if ids and ids[0].startswith('/'):
        run('install_name_tool','-id','@rpath/'+p.name,p)
    with tempfile.TemporaryDirectory(prefix='telos-macho-') as temp:
        inspect = Path(temp)/'binary'
        inspect.symlink_to(p.resolve())
        output=subprocess.check_output(['otool','-L',str(inspect)],text=True)
    for line in output.splitlines():
        if not line.startswith('\t'): continue
        dep=line.strip().split(' (')[0]
        if dep.startswith('/') and not dep.startswith(('/System/Library/','/usr/lib/')):
            # A dylib's own LC_ID_DYLIB is not an external dependency.
            if dep == str(p): continue
            raise RuntimeError(f'External dylib: {p.relative_to(APP)} -> {dep}')
    run('codesign','--force','--sign','-',p,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
# Resource-contained apps/frameworks must be signed inside-out explicitly.
for nested in sorted((p for p in RUNTIME.rglob('*') if p.is_dir() and not p.is_symlink() and p.suffix in {'.app','.framework'}), key=lambda p: len(p.parts), reverse=True):
    run('codesign','--force','--sign','-',nested)
run('codesign','--force','--sign','-',APP)
run('codesign','--verify','--deep','--strict',APP)
run(sys.executable,ROOT/'scripts/release/verify.py',APP)
run('codesign','--verify','--deep','--strict',APP)
os.symlink('/Applications', DIST/'stage/Applications')
shutil.copy2(ROOT/'docs/RELEASE.md',DIST/'stage/READ ME.txt')
dmg = DIST/f'Telos-{VERSION}-macOS-arm64.dmg'
if dmg.exists(): dmg.unlink()
run('hdiutil','create','-volname',f'Telos {VERSION}','-srcfolder',DIST/'stage','-format','UDZO',dmg)
run('hdiutil','verify',dmg)
digest=hashlib.sha256()
with dmg.open('rb') as f:
    for chunk in iter(lambda: f.read(1024*1024), b''): digest.update(chunk)
(DIST/'SHA256SUMS.txt').write_text(digest.hexdigest()+'  '+dmg.name+'\n')
print(f'RELEASE READY: {dmg} ({dmg.stat().st_size / 1024**2:.0f} MiB)')
