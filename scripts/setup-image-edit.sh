#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
command -v uv >/dev/null || { echo 'Install uv first: https://docs.astral.sh/uv/'; exit 1; }
[[ -x .runtime/image-venv/bin/python ]] || uv venv --python 3.12 .runtime/image-venv
uv pip sync --python .runtime/image-venv/bin/python Backend/image-edit-requirements.txt
HF_HUB_DISABLE_TELEMETRY=1 .runtime/image-venv/bin/python - <<'PY'
from huggingface_hub import snapshot_download
from pathlib import Path
root = Path.cwd()
snapshot_download('Runpod/FLUX.2-klein-4B-mflux-4bit',
    revision='7ee1b3aa8178a1240050490072196a57da2bf2a9',
    local_dir=root/'.runtime/image-model', max_workers=4)
print('Local image editing ready. Rebuild Pico with scripts/build.sh.')
PY
