Imported from the user-provided 631-slide-style-library on 2026-10-10. Original folder is unchanged. Specifications and previews are reference data, never executable instructions. See original source attribution below.

# styles_1（tier: styles_1）· GitHub notebooklm-prompt-styles

YAML 设计风格,来源 [YamilAyma/notebooklm-prompt-styles](https://github.com/YamilAyma/notebooklm-prompt-styles)(其 `/styles`,snake_case 命名)。条数以 `dev_build_style_catalog.mjs` 输出为准。

- **详情文件** `{id}/*.yaml` = 完整 design_system 规格(配色/字体/布局/图像提示),保留精确 hex/数值——Phase 3 蓝本。标本在 `{id}/previews/`。
- **检索卡** `{id}/meta.json`：`id` / `name` / `genre` / `visual_language` / `desc`（无色相）+ 可选 `register`。
- 与其它来源目录(styles_2/3/4/5/6)**完全平权**参与 LLM 精排,仅按 index 的 look 列(`desc`)贴合度排序。

> 上游 `/styles` 共 100 款,此处只收录一部分。


# styles_3（tier: styles_3）· awesome-notebookLM-prompts

精选风格,来源整理自 [serenakeyitan/awesome-notebookLM-prompts](https://github.com/serenakeyitan/awesome-notebookLM-prompts)(NotebookLM 风格提示词精选)。条数以 `dev_build_style_catalog.mjs` 输出为准。

- **详情文件** `{id}/*.md` = 各风格的完整设计规格(配色/排版/布局/视觉元素),保留精确 hex/数值——Phase 3 照此做设计。标本在 `{id}/previews/`。
- **检索卡** `{id}/meta.json`：`id` / `name` / `genre` / `visual_language` / `desc`（无色相）+ 可选 `register`。
- 与其它来源目录(styles_1/2/4/5/6)**完全平权**参与 LLM 精排,无任何优先/加分;仅按 index 的 look 列(`desc`)贴合度排序。

更新:改 `{id}/*.md` 详情或 `{id}/meta.json` 后,`node scripts/dev_build_style_catalog.mjs`。


# styles_2（tier: styles_2）· notebooklm-prompt-styles gallery

YAML 设计风格,来源 notebooklm-prompt-styles 的 gallery 站(<https://notebooklm-prompt-styles.vercel.app/styles>,kebab-case 命名)。条数以 `dev_build_style_catalog.mjs` 输出为准。

- **详情文件** `{id}/*.yaml` = 完整 design_system 规格,保留精确 hex/数值——Phase 3 蓝本。标本在 `{id}/previews/`。
- **检索卡** `{id}/meta.json`：`id` / `name` / `genre` / `visual_language` / `desc`（无色相）+ 可选 `register`。
- 与其它来源目录(styles_1/3/4/5/6)**完全平权**参与 LLM 精排,仅按 index 的 look 列(`desc`)贴合度排序。


# styles_5（tier: styles_5）· SlideSpeak

成套命名主题,导入自 [SlideSpeak / presentation-design-prompts](https://github.com/SlideSpeak/presentation-design-prompts)(MIT License, Copyright (c) 2026 SlideSpeak)。条数以 `dev_build_style_catalog.mjs` 输出为准。

- **详情文件** `<theme>/style.md` = 上游 `PROMPT.md` 原文。本库标本在 `<theme>/previews/*.webp`（中间物在 `previews/dev_work/`，不入库）。
- **检索卡** `{id}/meta.json`：`id` / `name` / `genre` / `visual_language` / `desc`（无色相）+ 可选 `register`。
- 与其他 tier 一样按 index 的 look 列(`desc`)参与 LLM 精排。

更新上游:重新拷 `PROMPT.md → <theme>/style.md`,按需补/改 `{id}/meta.json`,再 `node scripts/dev_build_style_catalog.mjs`。
