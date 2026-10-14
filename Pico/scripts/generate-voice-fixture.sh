#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
# Local synthetic speech only. No microphone recording, account or network call.
# Requires the macOS Tingting voice; a WAV is checked in so builds need not run this.
/usr/bin/say -v Tingting -r 165 --file-format=WAVE --data-format=LEI16@16000 \
  -o assets/asr-mixed-check.wav \
  '你好 Pico，帮我打开 Zoom Slides，review the project plan。'
