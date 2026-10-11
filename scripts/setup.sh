#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
command -v uv >/dev/null || { echo 'Install uv first: https://docs.astral.sh/uv/getting-started/installation/'; exit 1; }
mkdir -p .runtime
if [[ ! -d .runtime/hermes-agent/.git ]]; then
  git clone https://github.com/NousResearch/hermes-agent.git .runtime/hermes-agent
  git -C .runtime/hermes-agent checkout 3094b5d0aa611531fa7c197f2495ab86602c2b6d
fi
uv venv --python 3.12 .runtime/venv
uv pip install --python .runtime/venv/bin/python -e .runtime/hermes-agent
if [[ ! -d .runtime/macos-harness/.git ]]; then
  git clone https://github.com/browser-use/macos-harness.git .runtime/macos-harness
  git -C .runtime/macos-harness checkout b88e4d77403bbcac35752eef4f4dd72db3663fd6
fi
uv pip install --python .runtime/venv/bin/python -e .runtime/macos-harness
uv pip install --python .runtime/venv/bin/python -r Backend/requirements.txt
.runtime/venv/bin/python -m playwright install chromium
python3 scripts/configure.py
python3 scripts/configure-presentations.py
./scripts/build.sh
