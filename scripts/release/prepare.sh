#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/../.."
mkdir -p .runtime
if [[ ! -d .runtime/hermes-agent/.git ]]; then
 git clone https://github.com/NousResearch/hermes-agent.git .runtime/hermes-agent
 git -C .runtime/hermes-agent checkout 3094b5d0aa611531fa7c197f2495ab86602c2b6d
fi
if [[ ! -d .runtime/macos-harness/.git ]]; then
 git clone https://github.com/browser-use/macos-harness.git .runtime/macos-harness
 git -C .runtime/macos-harness checkout b88e4d77403bbcac35752eef4f4dd72db3663fd6
fi
uv venv --python 3.12.14 --allow-existing .runtime/venv
uv pip install --python .runtime/venv/bin/python -r scripts/release/main-requirements.txt
uv pip install --python .runtime/venv/bin/python --no-deps -e .runtime/hermes-agent -e .runtime/macos-harness
uv venv --python 3.12.14 --allow-existing .runtime/speech-venv
uv pip install --python .runtime/speech-venv/bin/python -r scripts/release/speech-requirements.txt
.runtime/venv/bin/python -m playwright install chromium
HF_HUB_DISABLE_XET=1 .runtime/speech-venv/bin/python - <<'PY'
from huggingface_hub import snapshot_download
snapshot_download('mlx-community/Qwen3-ASR-0.6B-4bit', revision='313d850181767edf09f00a9c289becca70e58cd0')
PY
