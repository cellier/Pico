`index.html` 由 `python3 bundle.py` 从本目录上级的角色代码和 `vendor/three.module.js` 生成，运行时不依赖 CDN。

`asr-mixed-check.wav` 是固定的合成测试语音，不是麦克风录音：

> 你好 Pico，帮我打开 Zoom Slides，review the project plan。

可在 macOS 用 `zsh scripts/generate-voice-fixture.sh` 重新生成。该脚本只使用本地 Tingting 系统语音；普通构建不需要重新生成。只有用户在 Pico 语音设置里点选付费识别测试时，才会将这段样本发给百炼。
