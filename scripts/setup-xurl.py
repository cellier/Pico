#!/usr/bin/env python3
"""Install the reviewed official X CLI, never account credentials or OAuth."""
import hashlib
import io
from pathlib import Path
import platform
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
VERSION = '1.3.4'
ASSET = 'xurl_Darwin_arm64.tar.gz'
ARCHIVE_SHA256 = '7097f8b124fa0e82a56610b678f19f73f0f383f43bea7c8dc91b90ac13895181'
BINARY_SHA256 = 'd2469f67f6eebd65fe080279a6d73c0462b145889645c1c103dcc48c5f2bd029'


def main():
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise SystemExit('This Pico build supports the reviewed Apple Silicon X CLI only.')
    target = ROOT / '.runtime/xurl/bin/xurl'
    if target.is_file() and hashlib.sha256(target.read_bytes()).hexdigest() == BINARY_SHA256:
        print('The reviewed official X CLI is already installed. Account authorization is separate.')
        return
    url = f'https://github.com/xdevplatform/xurl/releases/download/v{VERSION}/{ASSET}'
    request = urllib.request.Request(url, headers={'User-Agent': 'Pico-Setup'})
    with urllib.request.urlopen(request, timeout=45) as response:
        archive = response.read(30_000_001)
    if len(archive) > 30_000_000 or hashlib.sha256(archive).hexdigest() != ARCHIVE_SHA256:
        raise SystemExit('The official X CLI archive did not match the reviewed digest. Nothing installed.')
    with tarfile.open(fileobj=io.BytesIO(archive), mode='r:gz') as bundle:
        members = [item for item in bundle.getmembers() if item.isfile() and Path(item.name).name == 'xurl']
        if len(members) != 1:
            raise SystemExit('The official X CLI archive had an unexpected layout.')
        binary = bundle.extractfile(members[0]).read(50_000_001)
    if hashlib.sha256(binary).hexdigest() != BINARY_SHA256:
        raise SystemExit('The official X CLI binary did not match the reviewed digest. Nothing installed.')
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_suffix('.pending')
    temporary.write_bytes(binary)
    temporary.chmod(0o755)
    temporary.replace(target)
    print(f'Installed official X CLI {VERSION}. Register the X developer app and complete OAuth yourself; no credentials were created or read.')


if __name__ == '__main__':
    main()
