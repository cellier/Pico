# Telos 0.5.1 — Apple Silicon Preview

## 安装 / Install

1. 下载 `Telos-0.5.1-macOS-arm64.dmg`，打开后把 Telos 拖入 Applications。
2. 从 Applications 打开 Telos，点击菜单栏 logo 展开窗口。
3. 在 Settings 输入你自己的 DeepSeek API Key。安装包不含开发者密钥或个人任务数据。
4. 按需要授予辅助功能、屏幕录制、麦克风和日历权限。

Requires macOS 26 or later and an Apple Silicon Mac. Intel Macs are not supported.
Python, Hermes, macOS Harness, Chromium and the local bilingual speech model are bundled. No Python, uv, Git, Command Line Tools or source checkout is required on the recipient's Mac.

## 测试版说明 / Preview status

This build is ad-hoc signed, NOT Developer ID signed or Apple notarized. macOS may block the first launch. After verifying the source and checksum, use System Settings → Privacy & Security → Open Anyway if macOS offers it. Do not disable Gatekeeper system-wide.

本版是未公证测试版，不是正式发行版。它可能需要用户在系统“隐私与安全性”中明确允许打开。运行时需要网络和有效的个人 API Key；本地语音识别模型已包含，但文字润色和会议待办分析仍可调用 DeepSeek。

Repository Releases are private: recipients must have access to cellier/Telos to download.

## Included / 包含

- Native menu-bar app with Task, Calendar and Feed.
- Task conversations, attachments, document and local webpage tools.
- Reviewed Mac automation through macOS Harness.
- Local bilingual dictation and the in-development Zoom meeting transcript workflow.
- System Calendar, screenshot shortcut, light/dark appearance.
- Self-contained runtime paths resolved relative to the installed app.

## Known limits / 已知边界

- macOS permissions, target-app behavior, Zoom versions and audio devices affect functionality.
- Each new build currently attempts to reset Telos-specific permissions on first launch; grant access again after updating.
- Feed checks run while Telos is running; this is not an independent always-on scheduler.
- Clean-home runtime tests and a relocated-app check do not prove all real meetings and hardware combinations work.
- No automated public website hosting, cross-device sync or cloud-free Agent reasoning.

See README.md for feature details and privacy behavior. SHA256SUMS.txt is published with the DMG.
