#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/../.."
mkdir -p .runtime
python3 scripts/runtime-checkout.py hermes-agent
python3 scripts/runtime-checkout.py macos-harness
uv venv --python 3.14 --allow-existing .runtime/venv
uv pip install --python .runtime/venv/bin/python -r scripts/release/main-requirements.txt
uv pip install --python .runtime/venv/bin/python --no-deps -e .runtime/hermes-agent -e .runtime/macos-harness
python3 scripts/runtime-checkout.py hermes-agent --stamp
python3 scripts/runtime-phone.py
uv venv --python 3.12.14 --allow-existing .runtime/speech-venv
uv pip install --python .runtime/speech-venv/bin/python -r scripts/release/speech-requirements.txt
.runtime/venv/bin/python -m playwright install chromium
HF_HUB_DISABLE_XET=1 .runtime/speech-venv/bin/python - <<'PY'
from huggingface_hub import snapshot_download
snapshot_download('mlx-community/Qwen3-ASR-0.6B-4bit', revision='313d850181767edf09f00a9c289becca70e58cd0')
PY
