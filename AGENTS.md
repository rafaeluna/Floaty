# Floaty: context for coding agents

Floaty is a macOS menu bar app (AppKit, Swift, no dependencies) that captures a screen region and keeps it floating above other apps, with in-place annotation. User-facing behavior is described in `README.md`; this file covers how the code works and what has already been learned the hard way.

## Build, run, verify

```sh
./build.sh            # release build, bundle, sign, relaunch build/Floaty.app
./build.sh --no-run   # build and sign only
swift build -c release 2>&1 | grep -E "error|warning: "   # quick compile check
```

- SwiftPM executable target, Swift 5 language mode on a Swift 6 toolchain, deployment target macOS 15. Keep the build free of warnings.
- `build.sh` signs with the "Floaty Dev" self-signed identity if present (created by `scripts/setup-signing.sh`), else ad-hoc. The stable identity is what keeps Screen Recording and Accessibility grants across rebuilds. Do not change the bundle identifier (`app.floaty.Floaty`) casually; it resets permissions and preferences.
- There is no test target. The only automated check is the renderer self-test, which draws one of every annotation through the same code path as Copy:

  ```sh
  "$(swift build -c release --show-bin-path)/Floaty" --render-test out.png
  ```

  Look at the image after changing anything in `Annotation.swift`. `Assets/annotation-sample.png` in the README is this output.
- **You cannot verify interactive behavior yourself.** Selection, floats, cursors, gestures, focus, and the toolbar all need a person at the screen. After such changes, say plainly that it compiles and launches but is untested by hand, and tell the user what to try.
- NSLog output is not visible in `log show` for this app. To read it, run the binary directly from a terminal for a couple of seconds.

## Layout

| File | Responsibility |
|---|---|
| `main.swift` | Entry point; also the `--render-test` flag |
| `AppDelegate.swift` | Status item menu, global hot keys, capture flow, owns the list of floats |
| `HotKey.swift` | Carbon `RegisterEventHotKey` wrapper (no permissions needed) |
| `SelectionOverlay.swift` | One transparent panel per screen; crosshair, selection rectangle, size label |
| `ScreenCapturer.swift` | ScreenCaptureKit one-shot capture of a rect, excluding the overlay windows |
| `FloatWindow.swift` | `FloatController` (state, undo, export, toolbar hosting), `FloatPanel`, `ShadowPanel`, `FloatView` (mouse, keyboard, hover chrome, opacity slider) |
| `Annotation.swift` | `Annotation` model, geometry and hit testing, `AnnotationRenderer`, per-tool `StyleStore` |
| `AnnotationEditor.swift` | `AnnotationEditor` (tool state, create/move/handle drags) and `AnnotationCanvasView` (drawing, live text field) |
| `AnnotationToolbar.swift` | Toolbar panel and view, `ChipView` buttons, `TooltipPanel`, `KeycapView` |
| `HistoryStore.swift` | Saves PNGs and annotation sidecars, prunes old captures |
| `Settings.swift` | `Settings` (UserDefaults) and the settings window |
| `PinchTap.swift` | Event tap for pinch gestures (needs Accessibility) |
| `CursorControl.swift`, `WindowBlur.swift` | Private window-server calls, resolved with `dlsym` |
| `ImageExport.swift` | PNG encoding with DPI, pasteboard writing |

## Design rules that everything depends on

**Floaty is never the active app.** Every window is a borderless `.nonactivatingPanel`, and the app runs as an accessory (`LSUIElement`). This is what lets floats sit above other apps without disturbing their focus, and it has consequences throughout:

- There is no main menu, so nothing routes key equivalents. `FloatView.performKeyEquivalent` handles Cmd shortcuts by hand, including forwarding ⌘A/C/X/V/Z to the text field while a text annotation is being edited. A Cmd shortcut that is not handled there beeps.
- System tooltips do not appear, hence `TooltipPanel`. A tip string is the name, then two spaces, then the shortcut key, which is drawn as a keycap.
- Cursor changes from a background app are ignored unless `CursorControl` has enabled them. Any view that should show a specific cursor must set it itself; the float resets to the arrow when the pointer is outside its bounds.
- Trackpad gesture events are delivered to the active app, not to us. Pinch is read through a `CGEventTap` in `PinchTap`; a global `NSEvent` monitor does not receive it.
- `NSSharingServicePicker.show` and the share submenu in a context menu do not work from here. Popping up the picker's `standardShareMenuItem.submenu` as a menu does.
- Opening the settings window or a save panel does activate the app, deliberately.

**Coordinates.** Annotations are stored in image points with the origin at the top-left of the original capture, independent of float size, stretch, and crop. `FloatView` is not flipped; `AnnotationCanvasView` is. Convert with `FloatView.imagePoint(_:)` and `zoom`. Crop is non-destructive: `FloatController.crop` is a rect in the same space, the image layer is positioned so the cropped part fills the view, and removing the crop restores everything.

**One renderer.** `AnnotationRenderer.draw` is used for the live canvas and for `FloatController.renderedImage()` (copy, drag-out, save). Do not add a second drawing path; on-screen and exported output must match. Each mark is drawn inside a transparency layer so its fill and stroke share one shadow. Pixelate and spotlight are drawn beneath all other marks regardless of order.

**The original PNG is never modified.** Annotations and crop are saved to `.floaty/<name>.json` beside the PNG. A flattened `<name> (annotated).png` is written only on demand by `exportedFileURL()`. Nothing reads the sidecars back yet.

**Undo** is snapshot-based: `FloatController.Snapshot` holds frame, opacity, annotations, and crop. Call `recordUndo()` before a discrete change, or `recordUndo(coalescing:)` for continuous input such as pinch or scroll. Mouse drags are handled generically: `FloatView.mouseDown` stores a snapshot and `mouseUp` pushes it if anything changed, so editor code inside a drag should not record undo itself.

**The shadow is a separate click-through child window** (`ShadowPanel`), larger than the float, so that the shadow never intercepts clicks meant for apps underneath. Focus is shown only by shadow depth; there is no focus border. Both panels override `constrainFrameRect` to return the frame unchanged, otherwise macOS pushes them down from the menu bar and the shadow detaches. Any new child window that can extend past the float needs the same override.

**Private APIs** (`SetsCursorInBackground`, `CGSSetWindowBackgroundBlurRadius`) are looked up with `dlsym` and must fail soft. The window blur always fills the window's full rectangle, so `FloatView.squareCorners` squares off rounded corners while any blur is visible.

## Behaviors that were deliberately chosen

- A new float takes key focus; clicking elsewhere drops it. Losing focus hides the toolbar and slider, and regaining it restores the toolbar. The click that refocuses must not draw a mark (`justRestoredAnnotating`).
- A drag only counts as "moving" after 3pt of travel, so a click does not trigger the dim and blur.
- Esc backs out one level at a time: text edit → Select tool → deselect → close toolbar → close slider → close float.
- Proportional resize is the default; Shift stretches, Option resizes from the center. Pinch derives height from width with `stableAspect` so repeated small steps cannot drift the proportions.
- Tool keys work directly on a focused float and open the toolbar. Top-level keys that tools must not reuse: `O` (opacity), `U` (undo), `0` (original size).
- The mark just drawn stays selected so it can be adjusted without switching tools, except pen and highlighter strokes.

## Conventions

- AppKit only, no SwiftUI, no third-party packages.
- UI classes are main-actor; C callbacks hop with `MainActor.assumeIsolated`.
- Layer-backed drawing for anything that updates continuously. Wrap layer changes that must not animate in a `CATransaction` with actions disabled.
- Comments explain why something is the way it is, especially workarounds; they do not restate the code.
- New preferences go through `Settings`, and get a control in the settings window if a user would want to change them.

## Not built yet

Window and full-screen capture, loupe with color picker, OCR, click-through lock, collapse to thumbnail, history browser that reopens captures with their annotations, re-recordable shortcuts, rebindable tool keys, custom palette and font, a Gaussian blur alternative to pixelate.

## Repository

`main` is protected: no force pushes or deletion, and changes go through pull requests (the owner can push directly). Do not commit `build/`, `.build/`, or any certificate material.
