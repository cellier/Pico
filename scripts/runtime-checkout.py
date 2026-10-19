"""Reconcile a runtime checkout with its reviewed pin, preserving local edits."""
import argparse
import json
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PINS = json.loads((Path(__file__).with_name('runtime-pins.json')).read_text())
CHECKOUTS = {name: pin for name, pin in PINS.items() if pin.get('kind') != 'plugin'}


def git(path, *args):
    return subprocess.check_output(['git', '-C', str(path), *args], text=True).strip()


def ensure_checkout(name, runtime=None, check=False):
    pin = CHECKOUTS[name]
    runtime = Path(runtime) if runtime is not None else ROOT / '.runtime'
    target = runtime / name
    if target.exists():
        if not (target / '.git').exists():
            raise RuntimeError(f'{target} is not a Git checkout; it was left unchanged.')
        if git(target, 'remote', 'get-url', 'origin').removesuffix('/') != pin['repository']:
            raise RuntimeError(f'{target} has an unexpected origin; it was left unchanged.')
        if git(target, 'status', '--porcelain', '--untracked-files=all'):
            raise RuntimeError(f'{target} has local changes; preserve them before updating the runtime.')
        if git(target, 'rev-parse', 'HEAD') == pin['commit']:
            return target
        if check:
            raise RuntimeError(f'{name} is not at the reviewed commit {pin["commit"]}. Run scripts/setup.sh.')
        subprocess.run(['git', '-C', str(target), 'fetch', '--depth=1', 'origin', pin['commit']], check=True)
        subprocess.run(['git', '-C', str(target), 'checkout', '--detach', pin['commit']], check=True)
    else:
        if check:
            raise RuntimeError(f'{target} is missing. Run scripts/setup.sh.')
        runtime.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix=f'.{name}-', dir=runtime) as temp:
            staged = Path(temp) / name
            subprocess.run(['git', 'clone', '--no-checkout', pin['repository'], str(staged)], check=True)
            subprocess.run(['git', '-C', str(staged), 'checkout', '--detach', pin['commit']], check=True)
            staged.rename(target)
    if git(target, 'rev-parse', 'HEAD') != pin['commit']:
        raise RuntimeError(f'{name} did not resolve to its reviewed commit.')
    return target


def stamp_checkout(name, checkout, runtime=None):
    pin = CHECKOUTS[name]
    if not pin.get('version'):
        raise RuntimeError(f'{name} does not define a Hermes version stamp.')
    runtime = Path(runtime) if runtime is not None else ROOT / '.runtime'
    subprocess.run([str(runtime/'venv/bin/python'),
                    str(Path(checkout)/'scripts/write_install_stamp.py'),
                    '--output', str(Path(checkout)/'install-stamp.json'),
                    '--commit', pin['commit'], '--base-version', pin['version'],
                    '--display-version', pin['version'], '--distance', '0',
                    '--source', 'build', '--update-mechanism', 'external'], check=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('name', choices=CHECKOUTS)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--check', action='store_true', help='Verify without downloading or changing files')
    mode.add_argument('--stamp', action='store_true', help='Write the official version stamp using the installed main Python environment')
    args = parser.parse_args()
    try:
        checkout = ensure_checkout(args.name, check=args.check or args.stamp)
        if args.stamp:
            stamp_checkout(args.name, checkout)
        print(checkout)
    except (RuntimeError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'{error}\n')
