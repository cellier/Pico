#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
uv venv .runtime/speech-venv --python 3.12 --allow-existing
uv pip install --python .runtime/speech-venv/bin/python mlx-audio==0.5.6
HF_HUB_DISABLE_XET=1 .runtime/speech-venv/bin/python - <<'PY'
from huggingface_hub import snapshot_download
snapshot_download('mlx-community/Qwen3-ASR-0.6B-4bit')
PY
