# Pico · 桌面伙伴

Pico 是连接 Pico 的 macOS 桌面伙伴。按住它说出任务，松开后由 Pico 识别、执行并显示结果；Pico 用表情和语音反馈进度。需要补充信息或确认操作时，可以从右键菜单打开对应任务。

- **按住说话，移动拖动**：原地按住约半秒开始录音，松开提交；拖动可以调整桌面位置，点击会出现短暂的开心、眨眼和爱心表情。
- **三种皮肤**：默认是白气球，也可以右键切换经典 Pico 或粉色花朵。选择会保存，所有皮肤共享语音、任务和拖动交互。
- **轻轻望向屏幕中心**：根据所在屏幕与位置平滑调整朝向，保留聆听、思考、工作、回复等状态表情；尊重系统的“减少动态效果”。
- **紧凑的悬浮形象**：默认窗口为 143.36 × 143.36 点，角色、状态道具和点击区域按相同比例显示。
- **中英文语音**：可使用百炼识别中英文混说，并朗读回复。复用 Pico Settings 中保存的百炼账号；云端识别失败会保留原录音交给 Pico 本地识别，取消后丢弃迟到结果。
- **安静的状态反馈**：识别中或语音输入失败时，通过 Pico 的表情和右键菜单显示状态，不再弹出遮挡桌面的悬浮提示。
- **右键设置**：切换皮肤、打开语音设置或会议代理、查看任务、停止任务、切换置顶、暂停动画和重置位置。

## 构建与运行

需要 macOS、Xcode Command Line Tools（Swift、系统框架及签名工具）和 Python 3。离线测试额外需要 Node.js。先按主项目说明构建 Pico，然后在此目录运行：

```sh
zsh build.sh
open build/Sprout.app
```

界面名称为 Pico；为保留现有偏好和系统授权，内部程序名与 Bundle ID 继续使用 `Sprout` / `local.original.sprout`。构建会重新生成 `assets/index.html` 并使用本机 ad-hoc 签名。可将生成的 App 复制到“应用程序”；首次录音仍需本人在系统窗口授予麦克风权限。

Pico 优先寻找本仓库上级的 `build/Pico.app`，也支持同目录的 `Pico.app`、用户或系统“应用程序”目录以及系统登记的 Pico；保留旧版应用路径作为回退。自定义安装位置可在启动时指定：

```sh
PICO_APP_PATH="/path/to/Pico.app" build/Sprout.app/Contents/MacOS/Sprout
```

更新前请从右键菜单退出正在运行的 Pico。`build.sh` 会拒绝覆盖运行中的同一路径；可先构建独立候选版本：

```sh
PICO_APP_OUTPUT="$PWD/build/PicoCandidate.app" zsh build.sh
```

## 配置与数据

百炼账号在 Pico Settings 保存一次，Pico 只读 `~/Library/Application Support/Telos/bailian.json`；识别和朗读开关在 Pico 的语音设置中调整。关闭云端识别后由 Pico 使用本地模型。云端识别会发送录音，云端朗读会发送回复文字，付费试用按钮会明确标识。

桌面伙伴与主应用通过 `~/Library/Application Support/Telos/companion-v1/` 交换本机任务状态。皮肤等偏好保存在应用偏好域，日志写入 `~/Library/Logs/Pico/runtime.log`（可通过 `PICO_LOG_DIR` 改位置）。仓库不包含密钥、用户录音、任务记录或运行日志。固定识别测试音频的来源见 [assets/README.md](assets/README.md)。

## 源码与验证

`main.swift` 负责原生窗口和交互；`CloudRecognition.swift`、`CloudSpeech.swift`、`SpeechText.swift` 负责语音；`eyes.js`、`flower.js`、`orb.js`、`pet.js` 负责表情、三种皮肤与场景。`bundle.py` 将这些代码和 Three.js 打包成离线网页。主项目中的 `Sources/CompanionBridge.swift` 等文件负责 Pico 侧协议，无需复制到此目录。

```sh
python3 tests/run-offline.py
```

离线检查覆盖皮肤默认值与保存、状态和按住交互、表情恢复、多屏幕朝向、混合语言请求、共享账号读取与取消后的异步回调。它们不会启动 App、录音、播放语音、读取真实密钥或发起网络请求；外观仍需运行 Pico 检查。

内置 Three.js r160，许可证保留在 [vendor/LICENSE](vendor/LICENSE)。
