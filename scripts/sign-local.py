#!/usr/bin/env python3
"""Keep a certificate-bound identity for local updates without changing system trust.

This identity is local to this checkout. Public releases need Developer ID signing.
Never replace a missing/corrupt keychain silently: doing so would invalidate TCC grants.
"""
import os
import secrets
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
directory.mkdir(parents=True, exist_ok=True, mode=0o700)
keychain = directory / "Telos.keychain-db"
password_file = directory / "keychain-password"

def run(args):
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise RuntimeError("Local signing failed during " + " ".join(args[:2]) + "; restore the signing identity if needed.")
    return result.stdout

def register_keychain():
    chains = shlex.split(run(["security", "list-keychains", "-d", "user"]).decode())
    if str(keychain) not in chains:
        run(["security", "list-keychains", "-d", "user", "-s", *chains, str(keychain)])

if not password_file.exists():
    if keychain.exists():
        raise RuntimeError("Existing signing keychain has no password file; restore the signing backup.")
    password_file.write_text(secrets.token_urlsafe(32))
    password_file.chmod(0o600)
    (directory / "certificate.conf").write_text("""[req]
distinguished_name=dn
x509_extensions=extensions
prompt=no
[dn]
CN=Telos Local Development
[extensions]
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
""")
    password = password_file.read_text()
    run(["openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes", "-x509", "-days", "3650",
         "-config", str(directory / "certificate.conf"), "-keyout", str(directory / "private.key"),
         "-out", str(directory / "certificate.pem")])
    (directory / "private.key").chmod(0o600)
    run(["openssl", "pkcs12", "-export", "-inkey",
         str(directory / "private.key"), "-in", str(directory / "certificate.pem"), "-out",
         str(directory / "identity.p12"), "-passout", "file:" + str(password_file)])
    (directory / "identity.p12").chmod(0o600)
    run(["security", "create-keychain", "-p", password, str(keychain)])
    register_keychain()
    run(["security", "unlock-keychain", "-p", password, str(keychain)])
    run(["security", "import", str(directory / "identity.p12"), "-k", str(keychain),
         "-P", password, "-T", "/usr/bin/codesign"])
    run(["security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s",
         "-k", password, str(keychain)])

password = password_file.read_text()
if not keychain.exists():
    raise RuntimeError("Signing keychain is missing; restore it instead of creating a new identity.")
register_keychain()
run(["security", "unlock-keychain", "-p", password, str(keychain)])
fingerprint = run(["openssl", "x509", "-in", str(directory / "certificate.pem"), "-noout",
                   "-fingerprint", "-sha1"]).decode().strip().split("=")[-1].replace(":", "")
subprocess.run(["codesign", "--force", "--deep", "--keychain", str(keychain), "--sign",
                fingerprint, str(app)], check=True)
