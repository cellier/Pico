# Telos

**把一句话，变成可以推进的任务。**

Telos 是一个原生 macOS 菜单栏 AI 工作助手。你可以输入目标、附上文件，让 Agent 开始研究、生成内容或操作 Mac；也可以回到任务详情继续追加要求。任务、未来七天的日程和订阅信息流集中在同一个轻量窗口中。

界面使用 SwiftUI / AppKit，任务执行由 Hermes Agent 与 DeepSeek 驱动，Mac 应用操作接入 macOS Harness。

> 开发构建与发行构建分开管理。自包含的 Apple Silicon 测试版安装包通过 [GitHub Releases](https://github.com/cellier/Telos/releases) 分发；是否已有成功产物请查看对应 Release。测试版要求 macOS 26，未经过 Developer ID 签名或 Apple 公证。详细安装说明见 [发行说明](docs/RELEASE.md)。

## 视频介绍

两种版本演示了任务、语音输入、日历、信息流和快捷键显示。点击封面或下方链接打开视频；如 GitHub 未提供在线播放，可在视频页面点击 **Download raw file** 下载观看。

| 中文原声 · 中文字幕 | English narration · 中英双语字幕 |
| --- | --- |
| [![中文介绍视频](docs/videos/telos-intro-zh.jpg)](docs/videos/telos-intro-zh.mp4) | [![English introduction](docs/videos/telos-intro-en-bilingual.jpg)](docs/videos/telos-intro-en-bilingual.mp4) |
| [观看 / 下载中文视频](docs/videos/telos-intro-zh.mp4) | [Watch / download English video](docs/videos/telos-intro-en-bilingual.mp4) |

字幕下载：[原声中文字幕](docs/videos/telos-intro-zh-original.srt) · [英文字幕](docs/videos/telos-intro-en.srt) · [中英双语字幕](docs/videos/telos-intro-bilingual.srt) · [中文翻译字幕](docs/videos/telos-intro-zh-translated.srt)。另附[英文配音稿](docs/videos/telos-intro-narration.txt)。

视频录制于 2026 年 10 月，展示当时的开发版；具体功能和实验性功能的限制以下文为准。

## 产品预览

以下图片来自真实应用的隔离预览模式，使用代码内置的示例任务、日程和会议片段，**不包含用户的真实任务或会议记录**。示例日期、问候语和日程仅用于展示布局；截图不代表外部操作或真实会议已完成端到端验证。

<table>
  <tr>
    <td align="center"><strong>Task · 从目标开始</strong></td>
    <td align="center"><strong>Calendar · Next 7 days.</strong></td>
  </tr>
  <tr>
    <td><img src="docs/images/list.png" alt="Telos 任务首页，包含日期时间、问候语、输入框和任务列表" width="360"></td>
    <td><img src="docs/images/calendar.png" alt="Telos 未来七天日程，按日期分组展示" width="360"></td>
  </tr>
  <tr>
    <td align="center"><strong>Meeting → Transcript → Todo</strong></td>
    <td align="center"><strong>跟随系统的深色模式</strong></td>
  </tr>
  <tr>
    <td><img src="docs/images/meeting.png" alt="会议详情中的待办建议、原文依据和完整转录" width="360"></td>
    <td><img src="docs/images/dark.png" alt="Telos 深色模式任务首页" width="360"></td>
  </tr>
</table>

## 能用 Telos 做什么

### 任务与持续对话

- 用自然语言创建任务，自动生成英文任务标题。
- 在任务详情继续追问、调整要求，保留该任务的对话与产物。
- 粘贴或拖入图片、文件；点击 `+` 打开系统文件选择器。
- 输入框中的附件可以移除，也可以通过键盘删除；单个附件上限为 50 MB。
- 点击 checkbox 完成任务，在 Completed 中按完成日期查看。
- 让 Agent 从当前对话创建新的首页任务；每次用户请求最多创建 5 个。
- 搜索任务、日程和 Feed；再次点击搜索图标可关闭搜索。

例如：

> 调研三个演示文稿工具，比较协作和导出能力，给我一份有来源链接的报告。
>
> 把这个文件整理成可编辑的 Excel 表格。
>
> 基于当前讨论，在首页创建三个后续任务。

### 截图后本地改图（开发版实验功能）

按 **Option+A** 截图，macOS 26 及以上默认进入 **PaperKit 标注**。顶部工具栏支持画笔、荧光笔、橡皮擦、文字、矩形、椭圆、箭头、对话框和星形；选择工具后可拖动对象、拖动边缘/四角控制点缩放（Shift 保持比例）、双击文字编辑，并可撤销/重做。画布右下角的 **− / 百分比 / +** 可缩放至适应尺寸的 25%–800%，点击百分比或按 **⌘0** 恢复适应窗口；支持触控板捏合、双指滚动平移和 **⌘+滚轮** 缩放。缩放不影响原图分辨率和导出位置。选中文字后，跟随对象的浮条提供颜色、Aa 和字号入口；Aa 弹出面板可调整粗体、斜体、下划线、字体、对齐、行距和列表。**Done** 菜单提供 **Copy Image**、**Save PNG** 和 **AI Edit**。当前 macOS 原生 PaperKit 远程视图存在输入问题，因此使用 AppKit 接收编辑手势，所有标注仍写入 PaperKit 模型，画布预览与导出统一调用 PaperKit 的绘制 API；没有静默降级到旧标注器。交互预览按对象缓存 PaperKit 图像，移动时仅更新显示位置，松手后再完成尺寸重绘；文字框蓝色边缘点调整宽度，绿色角点同步缩放字号和文本框。低于 macOS 26 会明确提示 PaperKit 不可用。

选择 **AI Edit → Local edit** 后，可输入修改指令，或在图上按住说话；生成后可撤销、继续修改、复制或保存。本地模式使用 FLUX.2 Klein 4B / 4-bit / mflux，截图与指令不上传。**Annotate** 保留原有标注功能，使用已配置的 AI 服务。

一次性安装（Apple Silicon、Python 3.12、uv）：

```sh
zsh scripts/setup-image-edit.sh
zsh scripts/build.sh
```

模型存放于 `.runtime/image-model`，运行环境为 `.runtime/image-venv`。下载固定版本后推理强制离线。此可选环境尚未纳入发布 DMG，当前在本机开发构建中可用。更新启动时不再主动重置系统权限；截图仍通过 macOS 正常授权流程获取屏幕录制权限。语音还需麦克风权限。原本地改图的模型性能验证见下表。PaperKit 更新已在本机验证系统截图进入编辑器、绘画、文字编辑和拖动、图形拖动与缩放、撤销重做、复制和 PNG 保存；本次没有重新运行完整的语音/AI 生成工作流。

独立 pipeline（不会覆盖输入）：

```sh
.runtime/image-venv/bin/python Backend/local_image_edit.py \
  --model-path .runtime/image-model \
  --input /absolute/path/screenshot.png \
  --instruction '把大标题改成红色，其他内容保持不变' \
  --output /absolute/path/edited.png
```

不传 `--input` 时作为 JSON-lines 常驻进程，逐行接收 `image`、`instruction`、`output`，返回 `stage` 或 `output` + `metrics`。窗口内复用权重，关闭或取消时终止进程。工作图约 1 MP、最长边 1536，按比例缩放并补边；输出恢复原始尺寸，但并非原始清晰度或像素保真。临时缓存限制 256 MiB；24 GiB 的 MLX memory limit 是分配器软限制，并非整个进程硬内存上限。

2026-10-01 本机实测（M5 Pro / 48 GB / macOS 26.7；mflux 0.20.0、MLX 0.32.2；其他日常应用仍打开）：

| 项目 | 观测 |
|---|---|
| 完整量化模型文件 | 4,619,704,367 bytes，4.62 GB / 4.30 GiB；下载约 4 分 48 秒 |
| Python 环境磁盘占用 | 约 1.1 GiB；不含共享 uv 缓存 |
| 800×1464 截图，内部 768×1392，4 steps | 首次 54.7 秒、同进程第二次 39.0 秒（各一次，非统计基准） |
| 应用内中文指令 | 38.7 秒；大标题成功变红 |
| MLX 峰值分配 | 14.37 GB（13.39 GiB）；不等同于整个系统内存 |
| 应用编辑进程 vmmap | physical footprint 峰值 11.7 GiB，编辑后空闲约 2.3 GiB；与 MLX 计量口径不同，不可相加 |
| 验证 | 实际推理、中文输入、PNG 保存（800×1464）、撤销恢复、取消并终止进程、Swift 构建及签名检查 |

质量边界：改标题颜色成功；另一条“仅 Task 标签背景变蓝”误改了整个页头。中英文细节会被重绘，不适合必须保留每个字和每个像素的精确编辑。未限制缓存的首次探索约 49/72 秒，并观察到系统 swap 大幅增长；限制缓存后复测如上，仍不能推断空载性能或整机内存需求。仅加箭头、说明时优先使用 Annotate。

本轮 FLUX Apple Silicon 编辑路径可运行，未实测 Qwen，因此没有两模型实测排名。Qwen-Image-2.1 是后续比较候选，而非静默回退路径。实现依据：[mflux FLUX.2 编辑说明](https://github.com/mflux-community/mflux/blob/main/src/mflux/models/flux2/README.md)、[量化模型](https://huggingface.co/Runpod/FLUX.2-klein-4B-mflux-4bit)。原始测试记录与图片仅存于本地忽略目录 `evidence/local-image-edit/`，不进入版本控制。

### 研究、文件与网页

Agent 的工具包括网页搜索、公开网页读取、天气查询、文档生成和本地网页制作。可生成 Markdown、CSV、PDF、Word、Excel、PowerPoint 等文件；网页可以使用 Playwright 在本地渲染、检查并打包。

公开网页访问不等于可以读取所有登录页面；网站限制、网络状况和工具执行结果仍会影响任务。生成本地网页也不等于已经部署到公网：公开发布需要另外配置托管服务及相应授权。

### 操作 Mac

通过 macOS Harness，Telos 可以发现和打开应用、读取辅助功能界面、检查截图，并执行键盘、鼠标、AppleScript 或 Python 操作。

当前开发版中，普通 Todo 会自动批准其任务内的工具操作，并在任务记录中显示自动批准结果；Feed 任务不启用此模式。系统权限、登录或身份验证仍可能需要用户处理。旧版或手动审批流程可以逐项批准具体步骤。

可用程度取决于目标应用、登录状态、系统权限以及应用是否暴露可操作的界面。Telos 的批准机制不是操作系统沙箱；脚本以当前 macOS 用户权限执行。

### Calendar · 未来七天

- 使用 EventKit 读取 macOS 系统日历中的日程。
- 按日期分组，省略没有日程的日期；跨天事件会出现在对应日期。
- 菜单栏显示近期日程，在当天选择中优先显示有具体时间的日程。图标右侧分两行显示：上方为日期／时间，下方为日程名称，使用较小字体以显示更多内容。日程区域最多占 320 点，并根据屏幕和菜单栏位置自动收窄；长标题显示省略号，空间不足时仅保留 Telos 图标，悬停仍可查看完整日程名称。
- 这是日历读取与展示功能，不会通过 Calendar 页面直接编辑系统日程。

### Feed · 按你的规则持续追踪

通过任务告诉 Agent 想追踪什么，即可创建 Feed；之后可以继续调整来源、内容范围和规则。

竞品 Feed 默认每天筛选最近 24 小时的相关内容，在同一批次中将同一竞品的新动态合并成一条，并依据事件与来源去重。RSS、Atom、JSON Feed 和网页中声明的订阅源先采集到本地候选库；普通博客链接须由 Agent 继续核实原文和日期。已有原始日期的候选可补查最近 7 天，卡片标明延迟发现，不用抓取时间冒充发布时间。卡片使用明确的新闻标题、正文、来源链接和可用配图，标题与正文均可选择复制。

AI 筛选和卡片发布在 **Telos 运行时** 调度。来源或搜索失败时，本次显示“检查不完整”，保留已经保存的卡片和候选，不推进成功刷新时间；15 分钟起指数退避、最长 6 小时后重试。没有新消息与检查失败分开记录。只有来源检查有成功证据、没有失败、候选处理完成且批次提交成功，才记作成功刷新。

可安装独立的本机采集服务，使 Telos 退出后仍检查已启用的定时 Feed。服务每 15 分钟检查哪些来源到期，正常来源每小时采集一次，失败来源分别退避；条件请求减少重复下载。本机休眠或关机期间不运行，下次运行补查订阅源仍保留的内容。后台采集不调用模型、不写任务列表、不自行发布卡片、不发送通知；下次打开 Telos 再核实、筛选和发布。不能保证每天都有匹配新闻。

```sh
python3 scripts/feed-collector-service.py install
python3 scripts/feed-collector-service.py status
# 停止独立采集，保留候选与历史
python3 scripts/feed-collector-service.py uninstall
# 手动采集一次（不发布卡片）
.runtime/venv/bin/python -B Backend/feed_collection.py
```

此服务从已构建的 app 读取 Python 和采集器路径；移动开发包后需要重新安装服务。数据保存在 feeds.sqlite 的来源、候选、刷新运行表内，日志为 feed-collector.log，沿用本机用户的数据目录。

Feed 实施顺序与验收条件：

| 阶段 | 交付 | 验收条件 | 当前状态 |
| --- | --- | --- | --- |
| 1. 可靠采集与真实状态 | 独立采集、持久候选、失败退避、历史去重、延迟发现 | 应用退出后仍有采集记录；失败不推进成功时间；旧卡片保持原样；原文读取失败的候选不能被排除或发布 | 已实现并完成本机验证 |
| 2. 关闭应用也能生成动态 | 独立 AI 筛选与发布进程、持久运行记录、单 Feed 排他执行 | 退出应用后新候选仍可生成卡片；重新打开能看到；与前台刷新并发时不重复发布；中断可恢复 | 下一阶段 |
| 3. 提升覆盖与相关性 | 每个关注竞品的一手来源、特殊站点适配、相关性反馈、通知频率控制 | 能逐竞品说明来源及最近检查结果；用实际新闻样本验证漏报、重复与无关内容；无新内容时不打扰 | 尚未实现 |
| 4. 关机期间继续工作 | 用户可选的云端调度、数据同步与跨设备通知 | 本机关机后仍可采集与处理，恢复后同步；服务成本、数据范围、删除与关闭方式明确 | 尚未实现 |

阶段 2 需将 Feed 工作与原生任务列表的写入分开，避免后台进程与前台竞争 `tasks.json`；卡片与运行状态继续由 SQLite 协调。通知应只针对核实后的相关新事件，并支持合并发送、静默时段与频率上限。阶段 4 涉及新增服务与数据同步，应在本地链路稳定后单独设计和启用。

### 会议 → 转录 → 待办（开发中）

会议功能目前以 Zoom 桌面应用为检测对象，需要 macOS 26 及相关权限。开启会议监测并准备语音模型后，Telos 会检测会议状态，将会议关联到任务，并区分本机麦克风与会议应用音频的转录来源。

中英文混说使用本地 Qwen ASR；选择受支持的单一语言时可使用 Apple 本地语音能力。转录保存后，DeepSeek 可以分析文字并提出带原文依据的待办建议。用户选择建议后才创建任务，一次最多 5 个，已创建的建议不会重复生成任务。

**验证边界：**仓库包含会议生命周期、恢复和任务创建测试，但不代表所有 Zoom 版本、耳机切换、音频设备和真实会议场景都已验证。检测、授权、音频捕获、转录和待办提取是不同环节，任一环节未就绪都会影响结果。

### 语音输入与截图

- **长按语音输入：**在可编辑输入框内按住鼠标左键，听到提示后说话，松开结束；支持中英文混说。本地转录后，可调用 DeepSeek 整理文字。跨应用插入依赖辅助功能能力，不保证适配所有自绘编辑器；只读文本与密码框不应触发。
- **区域截图：**按 `Option + A`，拖选区域，松开后复制到剪贴板。
- **窗口截图：**进入截图模式后按空格切换窗口选择，再点击目标窗口。
- 截图时可以保留 Telos 窗口，便于截取应用自身内容。快捷键可能与其他截图工具冲突。

### Soul、Memory 与 Skills

Settings 中可访问 **Soul, Memory & Skills**：编辑 Agent 的身份指令、查看或删除持久笔记、管理共享 Skills。Hermes 可以发现和读取 `SKILL.md`；持久记忆应在用户明确要求时保存。

Skill 是工作指令与资源，不会自动提供系统权限、账号访问或缺失依赖，也不能绕过操作审批。

## 菜单栏交互

点击菜单栏 Telos 图标展开窗口，再次点击或点击窗口外部收起。窗口围绕顶部小尾巴尖端展开与收回。正在执行任务时，菜单栏 logo 顺时针旋转并间歇停顿，对应任务的 checkbox 边框也会显示活动状态。

首页展示本机日期时间与问候语；再次打开窗口保留阅读位置，双击 Task 可回到顶部。任务详情使用底部滑出的页面，可点击上方遮罩或下拉 handle 关闭。Settings 在应用窗口内部打开，界面默认跟随系统浅色／深色模式。

| 操作 | 快捷键或入口 |
| --- | --- |
| 新建任务输入 | `Command + N` |
| 搜索 | `Command + F` 或左上角搜索图标 |
| 关闭搜索／详情 | `Escape` |
| 截图 | `Option + A`；菜单栏图标右键菜单也有入口 |
| Settings | 窗口右上角 Telos logo |
| 演示按键显示 | Settings → Show keystrokes，默认开启 |
| 退出 | `Command + Q` 或菜单栏右键菜单 |

演示按键显示会在当前鼠标所在屏幕底部显示最近按下的键或快捷键（如 `⌘C`、`⇧Tab`、方向键），按住期间持续显示，松开所有键后约 1.6 秒消失；切换应用仍有效，显示层不拦截点击或抢走输入焦点。首次开启会申请 macOS 的 Input Monitoring／输入监控权限，授权后自动开始；设置中的开关会保留到下次启动。显示仅在本机内存中短暂存在，不保存、上传按键记录；系统安全输入或 Telos 密码输入期间暂停。

## 安装发行测试版

在 [Releases](https://github.com/cellier/Telos/releases) 下载 DMG，拖入 Applications 后打开，并在 Settings 填入自己的 DeepSeek Key。私有仓库的下载需要仓库访问权限。

发行包包含可随应用移动的 Python、Hermes、macOS Harness、Chromium 和本地中英文语音模型，不需要源码目录或开发工具。未公证测试版首次打开可能被系统阻止，见 [安装及限制](docs/RELEASE.md)。源码开发构建仍使用下述 `.runtime` 环境，两者不要混淆。

## 从源码运行

### 环境要求

| 项目 | 当前要求 |
| --- | --- |
| 硬件 | Apple Silicon Mac；现有构建目标为 `arm64` |
| macOS | 构建最低目标为 macOS 14；Liquid Glass 与会议功能需要 macOS 26，完整体验建议使用 macOS 26 |
| 编译工具 | Apple Command Line Tools；当前脚本使用 `/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk` |
| Python | Python 3.12 环境，由 `uv` 创建 |
| 依赖工具 | Git、[uv](https://docs.astral.sh/uv/) |
| 模型服务 | 可用的 DeepSeek API Key；任务执行与模型整理需要网络 |

构建脚本优先使用本机验证过的 SDK，找不到时使用当前 Xcode / Command Line Tools 的 SDK；也可通过 `TELOS_SDK` 指定。最低部署版本不等于已经在所有旧版本系统上完成验证。

### 1. 获取源码

```sh
git clone git@github.com:cellier/Telos.git
cd Telos
```

仓库当前为私有，需要相应 GitHub 权限。也可以使用已经配置凭据的 HTTPS 克隆方式。

### 2. 安装依赖并构建

```sh
./scripts/setup.sh
```

该脚本会：

1. 下载固定提交版本的 Hermes Agent 与 macOS Harness。
2. 创建 `.runtime/venv` 并安装后端依赖。
3. 安装 Playwright Chromium。
4. 通过隐藏输入提示配置 DeepSeek Key；已有本地配置时保留原配置。
5. 构建并 ad-hoc 签名 `build/Telos.app`。

### 3. 安装可选的本地语音环境

需要语音输入或中英文混合会议转录时运行：

```sh
./scripts/setup-speech.sh
```

脚本创建 `.runtime/speech-venv`，安装 `mlx-audio==0.5.6` 并下载 `mlx-community/Qwen3-ASR-0.6B-4bit`。首次准备模型需要网络、磁盘空间和一定时间。

### 4. 打开应用

```sh
open build/Telos.app
```

Telos 是菜单栏应用，请从屏幕顶部的图标打开窗口。后续只修改源码时，可重新构建：

```sh
./scripts/build.sh
open build/Telos.app
```

重新构建后应先退出旧进程，再打开新版本。当前 `.app` 包含指向此 checkout 下 Python 环境的路径，**不要只复制 `.app` 到另一台电脑，也不要随意移动或删除源码目录**。这不是自包含安装包。

## API 配置与系统权限

DeepSeek Key 可通过首次安装提示或 Settings 中的输入框配置，保存在本机：

```text
~/Library/Application Support/Telos/config.json
```

默认服务地址为 `https://api.deepseek.com`，当前默认模型标识为 `deepseek-flash`。实际可用模型与账号服务能力以服务端为准。仓库不包含可用密钥；不要把真实配置复制进提交。

| 权限 | 用途 |
| --- | --- |
| Accessibility／辅助功能 | 读取和操作 Mac 应用、跨应用语音输入、Zoom 状态检测 |
| Input Monitoring／输入监控 | 跨应用显示演示按键，仅监听，不拦截或改变按键 |
| Screen Recording／屏幕录制 | 截图、屏幕观察及会议应用音频捕获 |
| Microphone／麦克风 | 语音输入与会议中的本人音频 |
| Calendar／日历完整访问 | 读取未来七天日程 |
| Automation／自动化 | 系统按目标应用分别请求的 Apple Events 授权 |
| Speech Recognition／语音识别 | 使用 Apple 语音路径时按系统要求授权 |

在 Settings 中检查权限状态；如果系统要求手动添加应用，可以使用 **Show Telos in Finder** 定位当前构建。权限开启后可能需要重启应用。

**当前开发版更新行为：**每次新构建首次启动会尝试重置 `com.telos.mac` 的系统权限，再提示重新授权；同一构建反复启动不会重复重置。更新后可能需要重新连接 Calendar。该机制仅针对 Telos，不重置其他应用的权限。

## 数据、隐私与批准范围

主要应用数据位于 `~/Library/Application Support/Telos/`，包含任务记录、附件、会话历史、Feed、记忆与会议转录。任务工作目录按任务隔离。API 配置采用本地文件保存及访问权限限制，**不是 Keychain 加密存储**。

| 数据 | 处理方式 |
| --- | --- |
| 任务文字、工具结果、相关应用文本 | 执行任务时可能发送到 DeepSeek |
| 任务需要的截图或图片内容 | 按具体工具和模型能力处理，可能发送到模型服务 |
| 语音识别 | 支持的语音路径在本机识别；文字润色可发送到 DeepSeek |
| 会议待办分析 | 使用转录文字调用 DeepSeek；本地识别不等于分析也完全离线 |
| 网页搜索与 Feed | 会访问搜索服务和对应内容来源 |
| Mac 操作审批 | 绑定具体操作／计划；拒绝、取消、过期或目标状态变化会阻止继续执行 |

本地任务数据不会因为提交代码而自动上传到 GitHub。`.gitignore` 排除了运行环境、构建产物、日志、验证记录和常见本地配置文件；产品截图单独存放于 `docs/images/`。

## 项目结构与技术栈

```text
Sources/                 SwiftUI / AppKit 界面、状态管理和原生系统集成
Backend/                 Hermes 执行、Mac 工具、Feed、语音整理与会议分析
Resources/               应用内字体、图标及预览资源
assets/                  应用图标源资源
scripts/                 安装、构建和本地配置脚本
tests/                   Swift 与 Python 回归测试
docs/images/             README 产品截图（示例数据）
.runtime/                本地 Python 环境及引擎源码，不提交
build/                   本地应用构建结果，不提交
```

- **界面：**SwiftUI、AppKit、SF 系统字体、SF Symbols、Instrument Serif。
- **Agent：**[Hermes Agent](https://github.com/NousResearch/hermes-agent)，固定提交 `3094b5d0aa611531fa7c197f2495ab86602c2b6d`。
- **Mac 控制：**[macOS Harness](https://github.com/browser-use/macos-harness)，固定提交 `b88e4d77403bbcac35752eef4f4dd72db3663fd6`。
- **系统集成：**EventKit、ScreenCaptureKit、AVFoundation、Speech、Accessibility。
- **文档与网页：**python-docx、openpyxl、python-pptx、ReportLab、PyMuPDF、Playwright 等，版本见 `Backend/requirements.txt`。

## 开发与验证

Python 后端测试：

```sh
.runtime/venv/bin/python -m unittest discover -s tests
```

Swift 测试是独立入口，按需编译运行。例如检查窗口动画与滚动位置：

```sh
swiftc -D TELOS_TEST \
  -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  -target arm64-apple-macos14.0 -swift-version 5 -parse-as-library \
  Sources/*.swift tests/PanelScrollTests.swift \
  -o /tmp/telos-panel-tests \
  -framework SwiftUI -framework AppKit -framework CoreText -framework EventKit

TELOS_PREVIEW=list TELOS_PREVIEW_PIN=1 \
TELOS_DATA_DIR="$(mktemp -d /tmp/telos-test.XXXXXX)" \
/tmp/telos-panel-tests
```

原生 UI 测试需要 macOS 图形会话。不同测试有各自的数据与运行要求，不应把预览参数机械地加到所有测试上，也不要对个人真实数据目录运行测试。

生成隔离产品预览：

```sh
TELOS_PREVIEW=list TELOS_PREVIEW_APPEARANCE=light \
TELOS_PREVIEW_ANCHOR=0.5 TELOS_SNAPSHOT=/tmp/telos-home.png \
TELOS_DATA_DIR="$(mktemp -d /tmp/telos-preview.XXXXXX)" \
build/Telos.app/Contents/MacOS/Telos
```

可用预览包括 `list`、`detail`、`calendar`、`feed`、`meeting`、`meeting-live`、`settings`、`completed`、`search` 等。预览用于界面检查，不能代替真实工具执行、权限验证或真实会议测试。

## 常见问题

**打开后为什么没有普通应用窗口？**  
Telos 常驻菜单栏，点击顶部 logo 展开。右键图标可以打开 Settings、截图或退出。

**为什么 Agent 无法执行某些操作？**  
先检查 API 配置、网络、目标应用登录情况，以及具体工具所需的权限。网页打开和本地文件生成与辅助功能授权是不同能力；权限显示 Ready 也不代表所有应用都能被可靠操作。

**为什么会议开始后没有反应？**  
在 Settings 检查会议监测开关、权限和语音模型准备状态；当前只实现 Zoom 检测路径。检测到会议、开始捕获音频、出现转录文字和生成建议分别需要验证。

**为什么 Feed 暂时没有新内容？**  
先看 Feed 的来源检查状态。“检查不完整”表示来源、搜索或候选核实失败，系统保留候选并安排重试；不能据此断言没有新闻。来源全部正常但没有符合规则的内容、或内容已被去重，也会没有新增卡片。来源需指向实际发布页或 RSS/Atom/JSON Feed；已有历史和阅读状态会保留。

**为什么语音输入没有把文字放进其他应用？**  
目标必须是可编辑输入框，并允许辅助功能访问。密码框、只读文本、特殊自绘编辑器可能不支持；也应检查本地语音环境和麦克风授权。

**能直接把构建包发给别人吗？**  
请使用 Releases 中通过打包检查的 DMG；`scripts/build.sh` 单独生成的开发包仍依赖 checkout。发行测试版尚未公证，也没有覆盖所有硬件和真实会议场景。不要在发行包中携带个人 API Key 或用户数据。

## 当前边界

尚未提供跨设备同步、App Store 发行、经过 Apple 公证的安装包、通用的公网网站发布服务或所有会议应用的支持。日常 Agent 推理依赖配置的 DeepSeek 服务，不能因为存在本地语音模型就视为完全离线应用。

仓库中的测试与预览是开发验证的一部分；真实 Mac 操作、外部发送、复杂网站访问和会议音频能力仍应以实际执行结果为准。

## 字体与第三方许可

Instrument Serif 随项目附带，其 SIL Open Font License 见 [Resources/OFL.txt](Resources/OFL.txt)。其他第三方依赖遵循各自许可证。仓库目前没有为 Telos 自身声明开源许可证；GitHub 上可见或可克隆不等于获得任意再分发授权。

## 构建与发布 DMG

```sh
./scripts/release/prepare.sh
python3 scripts/release/package.py
```

安装包与 SHA-256 校验文件写入 `dist/`，不会提交到源码仓库。打包检查涵盖运行路径、外部符号链接、动态库依赖、干净用户目录下的核心导入、Chromium、本地语音模型及开发者 API Key 排除。该检查不替代真实硬件和权限验证。

推送 `v*-preview.*` 标签会触发 `.github/workflows/release.yml`，在 GitHub 的 Apple Silicon macOS runner 上重建、检查并发布预发行版。工作流使用 GitHub 自动提供的令牌，权限限定在仓库内容；不需要存放个人 GitHub Token 或 DeepSeek Key。构建可能消耗私有仓库的 Actions 配额。

### Todo automatic approval

Todo runs launched by the native app automatically approve Telos tool actions, scripts and work plans. Each automatic decision is recorded in the task conversation. Feed refreshes retain their existing restricted tool set and interactive approval policy. Stop still terminates the worker and its children; current-target validation and result verification remain enabled. macOS permission and authentication dialogs are handled by the operating system. Existing in-flight runs keep their original policy until restarted.

### Professional presentations

Todo presentation requests use the bundled `telos-presentations` skill and four dedicated tools: `presentation_guide`, `create_presentation`, `review_presentation`, and `finalize_presentation`. The old `.pptx` branch of `create_office_file` routes through the same draft workflow. A brief, requested total count and per-slide purpose precede design. Nine editable compositions cover cover/closing, statement, points, comparison, metrics, native charts/tables and sourced images, with executive/editorial/scientific themes and optional brand colors.

The builder uses the installed document runtime's Artifact Tool, validates the exported OOXML package, imports it back, renders every slide, and verifies native objects. The configured vision provider reviews every slide and the narrative. Finalization requires all reviews to pass for the same unchanged draft. Runtime/reviewer failures remain explicit draft limitations. This does not establish that cited facts are true or that a file has been tested in PowerPoint. Strict preservation of an uploaded template requires a separate source-preserving editing workflow.

Run `python3 scripts/configure-presentations.py` after installing/moving the local document runtime, then rebuild. This locates existing dependencies without modifying or vendoring their packages; the current desktop setup depends on the installed Presentations runtime. For verification: `python -m unittest discover -s tests -p 'test_presentations.py'`. Public design-workflow references: [Anthropic pptx](https://github.com/anthropics/skills/tree/main/skills/pptx) and [OpenAI Slides workflow mirrored by JetBrains](https://github.com/JetBrains/skills/tree/main/slides). Telos ships its own instructions and code, not copied third-party skill implementations.


### Prompt-driven presentation styles

The bundled user-supplied library contains 155 style references (84 structured and 71 image-native), including their original visual specifications and 950 preview images. `presentation_styles` uses the actual audience, purpose and aesthetic prompt to recommend three real catalog entries and automatically resolve the best one by default. When the user asks to compare options, recommendation mode exposes three preview artifacts and waits for a choice. An explicit stable style ID is honored.

A resolved style is required before generation. The renderer applies its palette, heading family, text scale, spacing, alignment, accent rules and composition; visual review sees both generated slides and the style reference. Contrast is checked when adapting text colors. References requiring photography, collage, custom illustration or exact typography still require real assets/custom design; selecting a reference does not promise pixel-identical reproduction of all 155 styles. Source attribution is preserved in `Backend/style_library/SOURCE.md`. Original files on the Desktop are unchanged.


PPT imagery uses `presentation_assets` for bounded image search, primary-page image discovery, downloaded/user-supplied image verification, and SVG logo conversion. Each selected asset retains its source page, pixel dimensions, hash and actual visual-review verdict. Photos use the image/cover/closing layouts; optional logos are embedded proportionally in a consistent footer. Builds reject unverified or changed assets, exact duplicates, resized/recompressed duplicates and common center/corner crops. Verified brand logos may repeat as branding. Similarity detection is conservative rather than a guarantee for arbitrary transformations. Final per-slide review also checks relevance, wrong branding, watermarking and visual fit. Search failures fall back to source-page discovery and remain explicit if unresolved.
