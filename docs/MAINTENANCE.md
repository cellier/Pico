# Telos / Pico 工程维护审查

日期：2026-10-13，仓库路径说明更新于 2026-10-14。范围：本机当前源码、实际构建入口、关键调用关系、诊断入口及生成物；不是全量安全审计或所有功能的重新验收。

## 唯一生产入口

- Telos：`Sources/`、`Backend/`、`Resources/`，由 `scripts/build.sh` 构建。
- Pico：仓库内 `Pico/` 中的 `main.swift`、`CloudSpeech.swift`、`CloudRecognition.swift`、`SpeechText.swift`、`pet.js`，由 `Pico/build.sh` 和 `Pico/bundle.py` 构建。此前独立 `sprout-pet` 目录的生产代码已纳入当前仓库；旧目录保留为本机工作副本。
- 两者通过 `companion-v1` 本地协议连接；Pico 的 `integration/` 不是 Telos 当前源码。
- 当前两个 App 都安装在各自 `build` 目录中。更新必须先构建到独立候选路径，验证、退出、备份再替换。构建脚本现在拒绝直接覆盖运行中的目标。

## 已清理

1. 日常签名脚本中的证书生成、创建钥匙串、导入身份、设置 ACL 和修改系统搜索列表操作全部移除。仅使用已存在的身份；缺失配置时报具体错误，不自动修复。现有专用钥匙串解锁与代码签名仍有用途，保留。
2. 删除没有生产调用的按构建版本重置全部权限逻辑及其过时测试。设置页显式“修复辅助功能权限”的入口仍保留。
3. Pico 会议云端诊断和音频回环诊断改为 `TELOS_DIAGNOSTICS` 编译开关，正常构建不包含入口。需要诊断构建时显式设置 `TELOS_DIAGNOSTICS=1`，并使用独立输出与隔离数据目录。测试能力没有丢弃。
4. 删除 Pico `integration/patch_telos.py`、`patch_language.py`、`patch_gesture.py`：修改已经合入当前源码，重新执行字符串替换脚本存在重复修改风险。
5. 删除 Pico 正常启动时的 GLB 导出、写回工程目录的消息处理和不再使用的 `GLTFExporter.js` 依赖。保留实时 Three.js 场景、动画、现有 GLB 产物和历史视觉版本。
6. 清理 10 个未运行、可重建的测试 App 或模块缓存，共计文件字节约 1.15 GB。详单保存在本机 `build/pico-meeting-work/maintenance-deleted.json`。

被修改或删除的维护代码在本次 `build/backups/maintenance-*` 中有清理前副本。没有 reset/clean 仓库，也没有覆盖其他尚未提交的功能修改。

## 明确保留

- `.runtime` 下的模型、Python 和签名资料：当前构建与安装版仍依赖，不能当缓存清理。
- `build/Telos.app`、Pico 的 `build/Sprout.app`：实际安装位置。
- `build/backups`、原钥匙串、发行包、历史视觉版本：存在恢复或交付价值，未按名称猜测删除。
- `Resources/dictation-mixed-check.wav`：设置页的显式语音识别测试仍使用。
- 原始任务、配置、长期记忆、会议记录、API Key：未清理。

## 后续维护风险

- Telos 的 `TelosApp.swift`、Pico 的 `main.swift` 承担过多职责，且部分代码过度压缩；后续按模块逐步拆分，避免一次性大改引入回归。
- Pico 生产代码和可复用测试现已纳入同一个 Telos Git 仓库。构建、日志、个人参考和历史 QA 不进入仓库；`Pico/README.md` 说明可移植构建入口。
- 仓库中的 Pico 已移除个人绝对 Telos 应用路径，支持 `TELOS_APP_PATH` 和已安装/仓库相邻应用查找；改变安装位置时仍应验证打开任务和会议入口。
- Telos 与 Pico 的签名策略不一致；Pico 当前沿用已有 ad-hoc 构建。不能为了“统一”未经说明更换签名身份或重置权限。
- 约 10 GB 的 Telos 回滚备份是主要剩余占用，宜在用户确认新版本稳定后制定保留数量；本轮保留恢复能力。
- 会议材料的云端语音、记忆工具调用和准确续讲仍需真实验证。代码编译或本地附件预览不构成端到端通过。

## 验证边界

两个工程正常构建与签名校验；签名流程测试覆盖已有身份、缺失配置、未注册钥匙串和非法路径，确认不会自动创建/导入/注册；材料解析回归测试通过。安装后另外检查 Telos 会议准备入口及 Pico 角色正常渲染。没有为清理工作进入会议、发送语音或更改钥匙串/系统权限。
