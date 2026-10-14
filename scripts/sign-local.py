#!/usr/bin/env python3
"""Keep a certificate-bound identity for local updates without changing system trust.

This identity is local to this checkout. Public releases need Developer ID signing.
Never replace a missing/corrupt keychain silently: doing so would invalidate TCC grants.
"""
import os
import json
import shlex
import subprocess
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
app = Path(sys.argv[1]).resolve()
identity = os.environ.get("TELOS_CODESIGN_IDENTITY")
if identity:
    subprocess.run(["codesign", "--force", "--deep", "--sign", identity, str(app)], check=True)
    sys.exit(0)

directory = root / ".runtime" / "local-signing"
if not directory.is_dir():
    raise RuntimeError("Signing is not configured. Select an existing identity with TELOS_CODESIGN_IDENTITY; builds never create keychains.")
keychain = directory / "Telos.keychain-db"
password_file = directory / "keychain-password"
active = directory / "active-keychain.json"
if active.exists():
    settings = json.loads(active.read_text())
    for field in ("keychain", "password_file"):
        name = settings[field]
        if not isinstance(name, str) or Path(name).name != name or name in ("", ".", ".."):
            raise RuntimeError("Invalid active signing keychain configuration")
    keychain = directory / settings["keychain"]
    password_file = directory / settings["password_file"]
    if not keychain.is_file() or not password_file.is_file():
        raise RuntimeError("Active signing keychain or credential missing; restore the saved identity")

def run(args):
    try:
        result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
    except subprocess.TimeoutExpired:
        raise RuntimeError("Local signing timed out during " + " ".join(args[:2]) + "; no retry performed.") from None
    if result.returncode:
        detail = result.stderr.decode(errors="replace").strip()
        for index, arg in enumerate(args[:-1]):
            if arg in ("-p", "-P", "-k"):
                detail = detail.replace(str(args[index + 1]), "[redacted]")
        raise RuntimeError("Local signing failed during " + " ".join(args[:2]) + ": " + detail[:500])
    return result.stdout

if not password_file.is_file():
    raise RuntimeError("Signing credential missing; restore it explicitly. Build will not create a new identity.")
password = password_file.read_text()
if not keychain.exists():
    raise RuntimeError("Signing keychain is missing; restore it instead of creating a new identity.")
chains = shlex.split(run(["security", "list-keychains", "-d", "user"]).decode())
if str(keychain) not in chains:
    raise RuntimeError("Configured signing keychain is not registered; build will not change the system search list.")
run(["security", "unlock-keychain", "-p", password, str(keychain)])
fingerprint = run(["openssl", "x509", "-in", str(directory / "certificate.pem"), "-noout",
                   "-fingerprint", "-sha1"]).decode().strip().split("=")[-1].replace(":", "")
subprocess.run(["codesign", "--force", "--deep", "--keychain", str(keychain), "--sign",
                fingerprint, str(app)], check=True)
