# Pico · 桌面伙伴

这是 Pico 应用内置的桌面形象。打开 Pico 时会一起显示，也可以在 Pico Settings 中关闭或重新打开。按住它说话，松开后消息直接进入同一个 Chat；Pico 用表情和语音反馈进度。需要补充信息或确认操作时，可以从右键菜单打开对应对话或任务。

- **按住说话，移动拖动**：原地按住约半秒开始录音，松开提交；拖动可以调整桌面位置，点击会出现短暂的开心、眨眼和爱心表情。
- **三种皮肤**：默认是白气球，也可以右键切换经典 Pico 或粉色花朵。选择会保存，所有皮肤共享语音、任务和拖动交互。
- **轻轻望向屏幕中心**：根据所在屏幕与位置平滑调整朝向，保留聆听、思考、工作、回复等状态表情；尊重系统的“减少动态效果”。
- **紧凑的悬浮形象**：默认窗口为 143.36 × 143.36 点，角色、状态道具和点击区域按相同比例显示。拖动位置会保存，开关或重新打开后沿用；显示器断开时会回到可见屏幕。
- **中英文语音**：可使用百炼识别中英文混说，并朗读回复。复用 Pico Settings 中保存的百炼账号；云端识别失败会保留原录音交给 Pico 本地识别，取消后丢弃迟到结果。
- **安静的状态反馈**：识别中或语音输入失败时，通过 Pico 的表情和右键菜单显示状态，不再弹出遮挡桌面的悬浮提示。
- **右键设置**：切换皮肤、打开语音设置或会议代理、查看任务、停止任务、切换置顶、暂停动画和重置位置。

## 构建与运行

需要 macOS、Xcode Command Line Tools（Swift、系统框架及签名工具）和 Python 3。离线测试额外需要 Node.js。正常使用只需从主项目构建并打开 Pico：主构建会把角色一起放入 `Pico.app/Contents/Helpers/Pico Desktop.app`，由主应用管理显示、隐藏和退出，不需要分别安装或打开。

此目录仍保留独立开发构建方式，便于角色和语音的隔离验证：

```sh
zsh build.sh
open build/Sprout.app
```

界面名称为 Pico；为保留现有偏好，内部程序名与 Bundle ID 继续使用 `Sprout` / `local.original.sprout`。构建会重新生成 `assets/index.html`，以 `PicoDesktop.html` 装入角色资源；独立开发构建使用本机 ad-hoc 签名，主应用构建则会统一签名整个包。首次录音仍需本人在系统窗口授予麦克风权限。

Pico 优先寻找本仓库上级的 `build/Pico.app`，也支持同目录的 `Pico.app`、用户或系统“应用程序”目录以及系统登记的 Pico；保留旧版应用路径作为回退。自定义安装位置可在启动时指定：

```sh
PICO_APP_PATH="/path/to/Pico.app" build/Sprout.app/Contents/MacOS/Sprout
```

主应用托管启动时使用 `PICO_MANAGED_BY_MAIN=1`、`PICO_MAIN_PID`、`PICO_APP_PATH` 和 `PICO_COMPANION_ROOT`。角色会验证主应用仍在运行、使用其数据目录，不另建状态栏图标；主应用退出时角色也退出。右键“隐藏桌面 Pico”会同步关闭主应用的显示开关。即使主应用移动或改名，内置角色也会验证并使用其直接所属的应用包。

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

离线检查覆盖皮肤默认值与保存、状态和按住交互、表情恢复、多屏幕朝向、嵌套主应用定位与托管所有者校验、混合语言请求、共享账号读取与取消后的异步回调。它们不会启动 App、录音、播放语音、读取真实密钥或发起网络请求；外观和生命周期仍需运行 Pico 检查。

内置 Three.js r160，许可证保留在 [vendor/LICENSE](vendor/LICENSE)。
