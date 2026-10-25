#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
command -v uv >/dev/null || { echo 'Install uv first: https://docs.astral.sh/uv/getting-started/installation/'; exit 1; }
mkdir -p .runtime
python3 scripts/runtime-checkout.py hermes-agent
python3 scripts/runtime-checkout.py macos-harness
uv venv --python 3.14 --allow-existing .runtime/venv
uv pip install --python .runtime/venv/bin/python -e .runtime/hermes-agent
uv pip install --python .runtime/venv/bin/python -e .runtime/macos-harness
uv pip install --python .runtime/venv/bin/python -r Backend/requirements.txt
python3 scripts/runtime-checkout.py hermes-agent --stamp
python3 scripts/runtime-phone.py
python3 scripts/setup-xurl.py
.runtime/venv/bin/python -m playwright install chromium
python3 scripts/configure.py
python3 scripts/configure-presentations.py
./scripts/build.sh
