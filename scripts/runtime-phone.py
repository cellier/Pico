"""Install Telos's reviewed phone plugin through the official Hermes CLI."""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PIN = json.loads((Path(__file__).with_name('runtime-pins.json')).read_text())['phone-harness']


def shared_home():
    data = Path(os.environ.get('TELOS_DATA_DIR', str(Path.home()/'Library/Application Support/Telos')))
    return data / 'hermes'


def verified_plugin():
    home = shared_home()
    plugin = home / 'plugins/phone-harness'
    metadata = json.loads((home/'plugins/.install-metadata.json').read_text())
    row = metadata.get('phone-harness') or {}
    if row.get('revision') != PIN['commit'] or (row.get('catalog') or {}).get('pin') != PIN['commit']:
        raise RuntimeError('The phone plugin does not match the reviewed catalog commit. Run scripts/runtime-phone.py.')
    for name, digest in PIN['files'].items():
        if hashlib.sha256((plugin/name).read_bytes()).hexdigest() != digest:
            raise RuntimeError(f'The installed phone plugin has changed: {name}. Its files were left unchanged.')
    return plugin


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--stage', type=Path, help='Copy only verified public plugin files into a release bundle')
    args = parser.parse_args()
    env = dict(os.environ, HERMES_HOME=str(shared_home()), PHONE_HARNESS_TELEMETRY='0')
    python = str(ROOT/'.runtime/venv/bin/python')
    if args.stage is not None:
        plugin = verified_plugin()
        args.stage.mkdir(parents=True, exist_ok=True)
        for name in PIN['files']:
            shutil.copy2(plugin/name, args.stage/name)
    else:
        # Hermes's plugin manager may prepare its own managed environment.
        # Native Telos workers use this explicit interpreter instead.
        subprocess.run(['uv', 'pip', 'install', '--python', python, PIN['package']], check=True)
        try:
            verified_plugin()
            package, version = PIN['package'].split('==')
            valid = subprocess.run([python, '-c', 'import importlib.metadata,sys; assert importlib.metadata.version(sys.argv[1]) == sys.argv[2]', package, version],
                                   env=env, capture_output=True).returncode == 0
        except (OSError, ValueError, RuntimeError):
            valid = False
        if valid:
            command = ['plugins', 'enable', 'phone-harness']
        else:
            command = ['plugins', 'install', 'phone-harness', '--ref', PIN['commit'], '--yes-deps', '--enable']
        subprocess.run([python, '-m', 'hermes_cli.main', *command], env=env, check=True)
        verified_plugin()
