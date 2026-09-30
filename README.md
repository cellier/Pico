# Telos 0.4

Native macOS AI task app: SwiftUI/AppKit interface, Hermes Agent orchestration, DeepSeek V4.1 Flash, and macOS Harness app/system control.

## Use

Open `build/Telos.app`. Type a task in **Add a task** and press Return. The AI names it and starts work. Click a task to view its conversation, files and progress. Use **Add a comment** to continue the same task. The circular checkbox completes a task under **Completed**; it does not authorize a Mac operation. Click the selected task again to close details. Drag the native divider to resize both columns.

**Review action** opens a pending execution confirmation. Review the app, explanation, exact operation, and screenshot where applicable. **Approve once** authorizes that one action; **Deny** refuses it. Stop cancels a running or waiting task. Escape closes details; Command-N focuses new task input; Command-F opens search; Command-Q quits.

Click the Telos logo for **Mac Access**. The app checks its own Accessibility, Screen Recording and input-control permissions without prompting. Clicking the corresponding permission button explicitly requests the OS dialog and opens System Settings. **Show Telos in Finder** locates the app if you need to add it manually. Restart Telos after granting permissions, then use Check again. Apple Events automation permission is separately granted per target app.

## Capabilities

- Text reasoning, drafting, public text/HTML URL reading, task-local documents.
- Discover and open installed Mac apps, read their accessibility state, and inspect requested screenshots using DeepSeek vision.
- App-targeted keyboard, mouse and accessibility actions through [macOS Harness](https://github.com/browser-use/macos-harness).
- Reviewed AppleScript and Python execution through Harness for app/system tasks. Available Python primitives include `mac`, `Path`, `subprocess`; scripts can implement task-specific operations without installing another agent.
- Isolated conversation history, output folders and Hermes homes per task; local task records survive relaunch.

Actual capabilities depend on installed applications, signed-in accounts, OS permissions and what each app exposes. Never assume a message was sent or another task succeeded until the target state is checked. Telos has no durable background scheduler, automatic public website hosting, cross-device sync or local-model fallback. Scheduling inside a calendar/reminder app can be done through reviewed app automation; that is different from a Telos wake-up scheduler.

## Expanded task capabilities

- `open_url` uses macOS Launch Services and the default browser. Opening websites does not need Accessibility, Screen Recording or Apple Events. An accepted open request is distinct from checking rendered browser content.
- Search uses DDGS; public URL reading preserves JSON/plain text. Open-Meteo provides current weather and a three-day forecast for a specified city. Optional IP-based approximate location uses ipapi.co, requires exact user approval, and may resolve to a VPN exit.
- User-editable `SOUL.md` is loaded through Hermes identity. Every ask builds a fresh runtime prompt while retaining task history, so old unavailable-tool statements and cached identities do not freeze the capability list.
- Cross-task notes live in a local SQLite store accessed through `telos_memory`. Only explicitly requested user memories should be saved. The native Soul / Memory / Skills sheet supports editing personality, reviewing and forgetting notes, and opening the skill folder.
- Native Hermes `skills_list` / `skill_view` load SKILL.md instructions. Five starter skills cover research, documents, websites, Mac tasks and memory. `install_skill` creates or updates a reviewed Markdown skill; it does not silently install dependencies or execute scripts. Additional support files can be placed in the shared skills folder.
- PDF, Word, Excel and PowerPoint are real binary files generated from structured input. `inspect_document` reads them back; PDFs additionally produce a page preview. Advanced generation and data work can use reviewed `run_python` with the installed document libraries.
- Website creation supports HTML/CSS/JS files, a Chromium screenshot, JavaScript error checks, vision inspection and ZIP packaging. Verification blocks external network and serves only the task workspace, so use local assets. A local webpage is not a public deployment.
- Search and memory deliberately use Telos-specific names to avoid collisions with Hermes built-in tool registrations. Custom code executes in a child process, so its printed output cannot impersonate approval events.

These are practical capabilities, not a promise that every website, app or document layout is supported. Installed-app UI control still needs macOS grants. Generic clicks, typing and arbitrary code remain reviewable because their effects depend on the target context. Ordinary URL opening, research, local structured artifact generation and previews run directly.

## Execution confirmation boundary

Discovery, observations, opening an installed app, scrolling and a narrow navigation-key allowlist run automatically. Generic clicks, text entry, accessibility changes, other keys and **every AppleScript/Python script** require confirmation. Model-provided “safe” labels cannot disable the gate.

Draft preparation and consequential final actions must be separate. Sending messages, deleting, purchasing, installing software, changing security/account settings and other commits should be reviewed only after the exact recipients, contents and targets are prepared. Unknown scripts are also reviewed because their behavior cannot be reliably classified from a label.

Approvals expire after five minutes and bind a random ID to the exact immutable action and observed target PID/state. Execution rechecks that state after confirmation. Denial, expiry, cancelled process or closed input fails closed. An old approval cannot authorize another action or survive a restart. Mutations from separate tasks are serialized. Scripts run in a separate subprocess with a 60-second timeout; Stop terminates worker descendants. The model cannot use app tools against Telos's own approval UI. No blanket “always allow” switch exists.

This is an approval gate, **not an OS sandbox or proof that a script is safe**. An approved script runs with your macOS user's privileges and may access other files/apps, so review its exact source as well as the explanation. Bounded AX/window fingerprints cannot prove a pixel-only dynamic interface unchanged. Interrupted scripts may have partially acted; inspect before retrying. Telos does not automatically authorize Browser Harness CDP or security dialogs.

## Privacy and storage

`~/Library/Application Support/Telos/` stores data. The directory is 0700; `config.json` with the DeepSeek key and atomic task/history JSON are 0600. Credentials are not bundled in source or the app. Task prompts, relevant app text and requested screenshots go to DeepSeek. Harness telemetry is disabled for Telos calls.

Each task has `files/`, `history.json`, `hermes/` and a private `mac-actions.jsonl` audit. Up to ten requested screenshot observations are retained under `mac-snapshots/` with mode 0600 for exact-operation review. Approvals use the live native UI-to-worker stdin channel, never a model-authored file or chat message.

## Build and validation

Apple Silicon, macOS 14+, Command Line Tools, Python 3.12 and uv:

```sh
./scripts/setup.sh
./scripts/build.sh
open build/Telos.app
.runtime/venv/bin/python -m unittest discover -s tests
```

The build selects the installed macOS 26.5 SDK to avoid the incomplete SwiftUI macro plugin in the local 27 SDK. The app is ad-hoc signed and depends on this checkout's Python environment; keep the directory in place. This is a local development build, not a notarized self-contained installer for other Macs.

Pinned engines:

- Hermes 0.21.5: `3094b5d0aa611531fa7c197f2495ab86602c2b6d`.
- macOS Harness 0.1.2: `b88e4d77403bbcac35752eef4f4dd72db3663fd6`.

The four September 25 Figma frames (163:8850, 160:4284, 162:8149, 163:8470) are the current UI reference. Instrument Serif is bundled from Google Fonts under OFL; SF system text and SF Symbols are native; Telos's logo is the original Figma asset. Corrected “Complected” to “Completed” and kept the first detail-list row visible below the header. Preview fixtures only run with `TELOS_PREVIEW` and never overwrite real tasks.

Validation details: `evidence/verification.md`, `evidence/mac-verification.md`. The live fixture is test-only, has no network/send action, and only updates a local status file. It must never be confused with a real email-send test.

Expanded verification: `evidence/capabilities-verification.md`. Hermes identity and skills conventions follow [the official file guide](https://hermes-agent.nousresearch.com/docs/user-guide/which-file-does-what) and [skills documentation](https://hermes-agent.nousresearch.com/docs/user-guide/features/skills).

## Interface refinement

Task titles are named in English regardless of prompt language; conversation replies retain the user language. Composer text and SF Symbols use 14 pt. Sent messages use 14 pt SF with an #EEE rectangular background and 12/8 pt padding. The main window is borderless with square corners and retains key/main-window support. Completion circles provide spring hover feedback, complete any task state (stopping a live run and invalidating pending approval first), and reopen completed tasks. List, detail and message transitions use native springs and respect Reduce Motion.

## September 25 interface and feeds

Native titled window, macOS 26 Liquid Glass buttons/input surfaces, SF 13 pt task rows, Instrument Serif greeting/editorial headings, and the provided message-tail asset. Older macOS uses native material fallbacks. A native NSSplitView supplies divider dragging with 300/320 pt minimum columns and persisted proportions. Sending a task or follow-up animates from composer to destination with a spring arc; Reduce Motion bypasses displacement.

Search matches task titles, summaries, full conversations and artifact names, including completed tasks. The Feed tab searches entry titles and bodies.

Ask in a normal task to create a feed and specify inclusion/exclusion rules, optional source URLs, and refresh frequency. Hermes uses manage_feed and publish_feed_items to populate the actual Feed tab. Follow-up tasks can modify rules and remove entries. Feed → menu → Manage feeds supports native editing, manual refresh, pause/resume and confirmed deletion. Records live in feeds.sqlite. Publishing checks rule revisions, uses transactions and deduplicates source URLs; removed entries stay hidden on later refreshes. Rule changes do not retroactively rewrite existing entries unless requested.

Automatic feeds refresh only while Telos is open, with a minimum interval of 15 minutes; unspecified schedules are manual. The app does not install a login daemon or claim to wake while closed. Daily feeds check once per local calendar day, including after a missed day when the app opens. Unsuccessful checks retry after 15 minutes; active or approval-waiting runs are never duplicated. Each feed reuses its refresh task. Competitor cards append by event batch, preserving earlier cards and read/hidden state. Empty checks retain history and duplicate events are skipped. Source/network failures remain visible in that task.

Verification: evidence/redesign-verification.md.


## Native Calendar (September 26)

The top-level views are Task / Calendar / Feed; Todo and Completed are filters within Task. Switching Todo / Completed changes only the task list; the greeting, composer and its draft stay in place.

Calendar uses EventKit directly. The Calendar tab's **Connect Calendar** requests macOS Full Access to events (the system permission name); Telos only reads events and never writes to Calendar or includes these events in agent prompts. All accounts synced into macOS Calendar are included. Denied access can be changed under System Settings → Privacy & Security → Calendars, or via Telos Settings.

The window includes today and the following six local calendar days. Ended, canceled, and declined events are excluded. Day groups show all-day events first; multi-day events appear on each overlapping day, with exclusive end dates. The menu bar uses the earliest day containing an upcoming event, prioritizes ongoing/upcoming timed events on that day, and falls back to all-day. Future days have a date label. The title truncates at 480 points of menu-bar width; the tooltip contains the full title. The logo rotates around its own center independently of the label, and the panel arrow remains anchored to the logo.

Calendar changes, app activation, wake, timezone/day changes and a one-minute timer refresh the list and menu label. Rebuilding retains the existing update-permission-reset behavior, which can require reconnecting Calendar.

Deterministic CalendarScheduleTests cover timed/all-day priority, ongoing/expired events, duplicate occurrences, seven-day limits, exclusive ends and DST. StatusActivityTests also cover label resizing and the 14-point icon's rotation center. Fixture previews: `calendar`, `calendar-empty`, `calendar-permission`, `calendar-denied` (use isolated TELOS_DATA_DIR and TELOS_SNAPSHOT). Fixtures do not establish real Calendar authorization or live-account access.

### Clipboard screenshots

While Telos is running, Option+A opens the native macOS screenshot selector in region mode. Drag and release to capture; press Space to switch to window mode and click a window. Escape cancels. Successful captures go directly to the clipboard with the system shutter sound; Telos does not save or upload them. The status-item context menu and Settings also offer Take Screenshot. Close repeated triggers are ignored while a capture is pending or active. If another app owns Option+A, Settings reports the conflict; release that shortcut and restart Telos, or use the menu entry. macOS may request Screen Recording permission.

Validation: `swiftc Sources/ScreenshotController.swift tests/ScreenshotTests.swift -o /tmp/telos-screenshot-tests -framework AppKit -framework Carbon && /tmp/telos-screenshot-tests` checks shortcut conflict/release and pending-capture cancellation without taking a screenshot. Physical region/window selection and pasting into another app require an interactive check.

### Hold-to-dictate

While Telos is running, hold the left mouse button still in an editable field for 0.55 seconds, speak after the tone, and release to insert the transcript. Text-selection dragging beyond 6 points cancels arming/recording. Escape cancels. Recording is capped at two minutes, with a 90-second transcription timeout. Local Telos editors work through NSTextView; external apps require Accessibility and must expose an editable accessibility text field. Secure fields are excluded. If focus/selection changes during transcription, the result is copied instead of inserted elsewhere. The feature can be disabled in Settings. Grant microphone and Accessibility from Settings → Enable microphone & global typing.

Run `./scripts/setup-speech.sh` once to install the isolated MLX Audio runtime and multilingual Qwen3-ASR-0.6B-4bit weights. Audio is recorded as a private temporary WAV, transcribed locally, and deleted on completion/cancellation. With Polish voice text enabled, only its transcript is sent to the configured DeepSeek provider for conservative editing; the audio is never uploaded. Provider failure/timeouts preserve the raw transcript. The microphone description and runtime path are embedded by the build script. No cloud transcription fallback is used. Mixed-language accuracy depends on microphone quality, accent, vocabulary and pronunciation; synthetic smoke tests do not establish real-world accuracy.

Opening/closing the status panel retains the current page and scroll view. Initial Task presentation begins at the greeting/composer; double-click Task to return to the top.

Dictation validation (2026-09-26): Qwen3-ASR synthetic Mandarin and English samples transcribed correctly; a stitched bilingual sample returned “请帮我打开 Zoom Slides，然后 Review this presentation.”, preserving English. The system Tink tone alone and silent PCM returned no text. Initial model load took about 4 seconds in this test; this is not a real microphone or cross-app latency/accuracy benchmark. The earlier Whisper trial was rejected because it lost/translated English in the mixed sample. Physical hold-to-record, microphone permissions and third-party input-field insertion remain interactive validation items.

Cross-app dictation insertion uses a real Command-V with the transcript on the clipboard, rather than trusting an AX setter return code or Unicode event delivery. Telos verifies the expected UTF-16 selection replacement against the field's exposed value before reporting Inserted. Unsupported/read-protected values report “Text copied — paste not confirmed”; no automatic retry avoids duplicate insertion. Focus changes skip automatic paste. The transcript stays on the clipboard for manual recovery.

Dictation refinement: the text fields focus on mouse-down, expose I-beam hit targets over padding, and show hover/focus/pressed feedback. A common-run-loop timer observes a 0.55-second stationary hold even during native text selection tracking, and continues watching release/drag while recording. The local ASR worker stays warm between utterances. Transcript polishing removes filler/repetition, respects explicit corrections and preserves negatives/numbers/mixed English; it has no tools, a short network timeout and a raw-text fallback. Disable Polish voice text in Settings for local-only transcription.

## Zoom meeting tasks (macOS 26)

In Settings, choose a meeting speech mode and click **Enable Zoom meetings**. Automatic detection is enabled by default unless you explicitly turn it off. Use Set up meeting access to grant the required permissions; missing permissions and detection state appear in Settings. Microphone, Screen & System Audio Recording, and Accessibility are required. Apple speech assets are prepared when selecting Apple mode; mixed Chinese/English uses the existing local Qwen runtime. Audio stays local and is not written to recording files. When a meeting finishes, its transcript is sent to the configured DeepSeek provider for evidence-bound suggestions.

Meeting detection uses enabled Zoom meeting controls (leave/end, mute, participants/share), with a start debounce and a 30-second end debounce. A running Zoom process or silence alone is not sufficient. Unavailable Accessibility state is treated as unknown. ScreenCaptureKit captures Zoom application audio separately from the system-default microphone; default-input device changes update capture configuration. A microphone selected only inside Zoom may differ from the macOS default input.

A meeting appears as one task. Its detail shows live Me/Others transcript and a Stop recording button. Completed meetings remain under Completed, including the full transcript, suggestions and decisions. Select up to five suggestions and click Create tasks; confirmed tasks stay pending until started, retain evidence, and link back to the meeting. No transcript instruction can create tasks automatically. Interrupted meetings preserve saved text and identify the interruption. Analysis can be retried from saved text.

Validation: native lifecycle simulation covers debounce, final-buffer delivery before persistence, shutdown during startup, restart recovery and corrupt-file isolation. Creation tests cover evidence, five-task limit and idempotence. Real local Qwen and Apple SpeechAnalyzer tests pass on generated audio, and live DeepSeek extraction passes on a synthetic transcript. Light/dark meeting views have been inspected. These tests do **not** establish real Zoom capture, AirPods/USB/Bluetooth routing, mid-call device switching, long-call stability or real-world recognition accuracy; those hardware scenarios remain to be tested. Teams and Google Meet detection are not implemented in this Zoom-first slice.
