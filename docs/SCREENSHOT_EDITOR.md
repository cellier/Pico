# PaperKit screenshot editor

## Scope

The repository's existing screenshot path was `Option-A -> macOS selection -> clipboard`.
This change adds a native AppKit editing window after a successful capture when
PaperKit is available. It does not replace a separate local, unpushed editor.

The original image is still copied immediately. The editor uses Apple's
`PaperMarkupViewController` and `MarkupToolbarViewController` for drawing,
text, shapes and selection. It starts in drawing mode and includes Fit, Undo,
Redo, Copy Image, Save PNG, and a More menu for editable copies.

Each capture gets its own editor window. `Space` still selects a window and
`Escape` still cancels the macOS capture UI. Cancellation does not open an
editor or replace the clipboard. The editor is independent of the menu-bar
panel's outside-click dismissal.

## Data and privacy

The original PNG is held separately from `PaperMarkup` and displayed using
`contentView`; it is not a selectable, movable annotation. The bitmap and
annotations are composed only in a temporary export model, at the screenshot's
original pixel dimensions, rather than by screenshotting the editor window.
Exports use an SDR sRGB PNG; this is not an HDR-preserving image pipeline.

A successful capture briefly uses a UUID-named, user-only temporary directory.
The capture process's termination handler removes it on success, failure or
normal cancellation. As with other temporary files, an abrupt app/system crash
can leave a temporary directory for the operating system to clean up.

There is no network request or automatic agent upload. AI edit instructions,
region masks, and AI-generated image replacement are deliberately not mixed
into the persistent annotation model by this change.

**Editable copies contain the unedited original screenshot.** They are saved
explicitly through More > Save Editable as `Screenshot.telosshot.json` and
contain original PNG bytes, serialized PaperKit markup, a flattened preview,
and the logical canvas size. Do not share an editable copy when the original
contains private information that was covered by a shape. Share the PNG instead.
The save dialog explains this distinction.

More > Open Editable opens a saved copy in a new window without replacing the
current work. Unsupported versions/markup are rejected without changing the
file; a flattened preview is retained in the file for future fallback support.
This version does not yet display that preview automatically for incompatible
markup and does not register a Finder file association.

Editable copies are **not autosaved**. Closing an edited window asks whether to
save an editable copy, discard edits, or cancel. The app's existing quit handler
is unchanged: save editable copies before quitting Telos. Crash recovery and
app-wide unsaved-document termination handling remain outside this first pass.

## Requirements and fallback

Runtime: macOS 26 or later. Build: a macOS SDK that exposes public PaperKit AppKit
APIs. `canImport(PaperKit)` is a compile-time check; the OS version alone does
not establish that the selected SDK includes the framework.

The app's deployment target is not raised. Builds without PaperKit, and older
runtime systems, keep the existing clipboard-only capture behavior. No private
API or Quick Look service is used. The test runner explicitly requires PaperKit
so an unavailable framework cannot produce a false-positive native test pass.

The current development build script prefers a fixed SDK path when it exists.
Select the intended Xcode/SDK explicitly while validating this feature:

```sh
TELOS_SDK="$(xcrun --sdk macosx --show-sdk-path)" bash scripts/test-screenshot-editor.sh
TELOS_SDK="$(xcrun --sdk macosx --show-sdk-path)" ./scripts/build.sh
```

The existing build compiles `Sources/*.swift`, so the new sources are included
without introducing a package manager or third-party dependency.

## Shortcuts in an editor window

- Command-S: save a flattened PNG.
- Shift-Command-S: save an editable copy.
- Shift-Command-C: copy the flattened image, preserving normal Command-C for text/selection.
- Command-W: close this editor, with an unsaved-edit prompt when appropriate.
- Command-Z / Shift-Command-Z: undo / redo; buttons are also available.

The key monitor only handles events for its own editor window and is removed
when that window closes. Save/open sheets keep their normal keyboard behavior.

## Validation

Portable tests: serialization, independent payloads, invalid/empty data,
unsupported document versions, dimension checks, and atomic save/reopen.

Native tests: capture arguments, zero-edit original preservation, 2x export
pixel dimensions, asymmetric corner colors to catch flips, image/markup
compositing, PaperKit serialization, and existing capture-controller tests.
The native runner does not take a screenshot or upload content.

```sh
bash scripts/test-screenshot-editor.sh
```

On Linux this runs only the portable tests and prints an explicit native skip.
A Swift syntax parse is not a macOS SDK type-check or UI test.

Before merging, build and run on a Mac with PaperKit and check:

1. Option-A captures a region; Space captures a window; Escape leaves clipboard untouched.
2. Pen, text, arrows/shapes, selecting/moving annotations, deletion, undo and redo work with a mouse/trackpad.
3. The original is not movable; resizing/Fit/zoom do not misalign annotations.
4. The toolbar fits at the minimum window size in both appearance modes.
5. PNG and clipboard images retain exact pixel dimensions and correct orientation on Retina and non-Retina displays.
6. Saving while a text box is being edited includes its latest characters; failed exports leave the editor intact.
7. More > Save Editable, close, then Open Editable restores independently editable annotations.
8. Repeated captures keep earlier editor windows; Command-W only closes the current editor.
9. Canceling a save sheet or the unsaved-edit dialog does not discard work.
10. Verify the fallback build/runtime still copies screenshots without trying to instantiate PaperKit.

## Apple API references

- https://developer.apple.com/documentation/paperkit
- https://developer.apple.com/documentation/paperkit/getting-started-with-paperkit
- https://developer.apple.com/documentation/paperkit/papermarkupviewcontroller
- https://developer.apple.com/documentation/paperkit/markuptoolbarviewcontroller
- https://developer.apple.com/documentation/paperkit/papermarkup
- https://developer.apple.com/videos/play/wwdc2025/285/

Use the macOS variants of the documentation and the installed SDK declarations.
This implementation intentionally avoids the newer element/adornment APIs.
