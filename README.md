# Telos

**把一句话，变成可以推进的任务。**

Telos 是一个原生 macOS 菜单栏 AI 工作助手。你可以输入目标、附上文件，让 Agent 开始研究、生成内容或操作 Mac；也可以回到任务详情继续追加要求。任务、未来七天的日程和订阅信息流集中在同一个轻量窗口中。

界面使用 SwiftUI / AppKit，任务执行由 Hermes Agent 与 DeepSeek 驱动，Mac 应用操作接入 macOS Harness。

> 开发构建与发行构建分开管理。自包含的 Apple Silicon 测试版安装包通过 [GitHub Releases](https://github.com/cellier/Telos/releases) 分发；是否已有成功产物请查看对应 Release。测试版要求 macOS 26，未经过 Developer ID 签名或 Apple 公证。详细安装说明见 [发行说明](docs/RELEASE.md)。

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

### 研究、文件与网页

Agent 的工具包括网页搜索、公开网页读取、天气查询、文档生成和本地网页制作。可生成 Markdown、CSV、PDF、Word、Excel、PowerPoint 等文件；网页可以使用 Playwright 在本地渲染、检查并打包。

公开网页访问不等于可以读取所有登录页面；网站限制、网络状况和工具执行结果仍会影响任务。生成本地网页也不等于已经部署到公网：公开发布需要另外配置托管服务及相应授权。

### 操作 Mac

通过 macOS Harness，Telos 可以发现和打开应用、读取辅助功能界面、检查截图，并执行键盘、鼠标、AppleScript 或 Python 操作。

读取和基础导航可以自动进行；修改、发送、删除、购买等操作会进入审核。相关操作可以组织成一个明确的工作计划，一次批准其中列出的具体步骤。新增或改变步骤仍需要确认，批准不是对整台 Mac 的永久授权。

可用程度取决于目标应用、登录状态、系统权限以及应用是否暴露可操作的界面。Telos 的批准机制不是操作系统沙箱；经过批准的脚本以当前 macOS 用户权限执行。

### Calendar · 未来七天

- 使用 EventKit 读取 macOS 系统日历中的日程。
- 按日期分组，省略没有日程的日期；跨天事件会出现在对应日期。
- 菜单栏显示近期日程，在当天选择中优先显示有具体时间的日程。
- 这是日历读取与展示功能，不会通过 Calendar 页面直接编辑系统日程。

### Feed · 按你的规则持续追踪

通过任务告诉 Agent 想追踪什么，即可创建 Feed；之后可以继续调整来源、内容范围和规则。

竞品 Feed 支持每天检查、覆盖最近 24 小时的相关内容，在同一批次中将同一竞品的新动态合并成一条，并依据事件与来源去重。卡片使用明确的新闻标题、正文、来源链接和可用配图，标题与正文均可选择复制。

刷新在 **Telos 运行时** 调度，不是独立于应用的后台服务。退出应用或电脑休眠期间不会持续拉取。刷新失败时保留已经保存的内容；内容数量受来源质量、发布时间和去重规则影响，不能保证每天都有新消息。

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
| 退出 | `Command + Q` 或菜单栏右键菜单 |

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
检查应用是否运行、API 与网络是否可用，以及来源和内容规则。最近 24 小时内没有合适动态，或新内容已被去重，也会导致没有新增卡片；已有内容应继续保留。

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
