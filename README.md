<img src="Assets/icon.svg" width="96" alt="Floaty icon">

# Floaty

A macOS screenshot tool that pins what you capture on top of everything else, right where you took it, and lets you annotate it in place.

Press a shortcut, drag a region like the built-in screenshot tool, and the capture stays floating above your other apps. Move it, resize it, mark it up, copy it, or drag it into another app.

## Features

- **Native-feeling capture.** Crosshair selection with a live size label; hold Space to move the selection, Esc to cancel.
- **Floats.** Each capture appears pixel-exact over the area it came from and stays above all windows, on every Space. Floats never take focus from the app you are working in.
- **Resize and scale.** Drag edges or corners (proportional by default, Shift to stretch, Option to resize from the center), pinch, or Cmd-scroll.
- **Annotation.** Arrows and lines that can be curved, rectangles, ellipses, text in five styles, pen, highlighter, pixelate, numbered steps, spotlight, and crop. Every mark stays editable and the original image is never modified.
- **Opacity.** Make a float see-through to overlay it on something else.
- **Output.** Copy the image or its file path, drag the file into another app, share it, or save a copy as PNG or JPEG.
- **History.** Every capture is saved to `~/Pictures/Floaty` and pruned after 30 days (configurable).

## Shortcuts

Global:

| Shortcut | Action |
|---|---|
| ⇧⌘2 | Capture a region |
| ⌥⇧⌘H | Hide or show all floats |

On a focused float:

| Shortcut | Action |
|---|---|
| ⌘C | Copy image (with annotations) |
| ⌥⌘C | Copy file path |
| ⌘S / ⇧⌘S | Save / Save As |
| O | Opacity slider |
| 0 | Original size |
| U or ⌘Z / ⇧U or ⇧⌘Z | Undo / redo |
| ⌘, | Settings |
| Esc or ⌘W | Close (the capture stays in history) |

Annotation tools (each key opens the toolbar on that tool):

| Key | Tool | Key | Tool |
|---|---|---|---|
| V | Select | P | Pen |
| A | Arrow | H | Highlighter |
| L | Line | B | Pixelate |
| R | Rectangle | N | Numbered step |
| E | Ellipse | S | Spotlight |
| T | Text | C | Crop |

While annotating: `1`–`8` pick a color, `[` and `]` change size, Shift constrains to 45° or squares, Delete removes the selected mark, and Esc steps back (tool → Select → deselect → close toolbar).

## Requirements

- macOS 15.2 or later
- Xcode command line tools with Swift 6

## Build

```sh
./scripts/setup-signing.sh   # once: creates a local self-signed certificate
./build.sh                   # builds build/Floaty.app, signs it, and launches it
```

The signing step is optional but recommended. macOS ties the Screen Recording permission to an app's signature, and an unsigned build would lose that permission every time it is rebuilt. Without the certificate, `build.sh` falls back to an ad-hoc signature.

## Permissions

- **Screen Recording** — required to capture the screen.
- **Accessibility** — optional; enables pinch-to-resize on floats.
- **Pictures folder** — to save captures to `~/Pictures/Floaty`.

## Notes

Floaty is an AppKit app with no dependencies. It uses ScreenCaptureKit for capture and Carbon hot keys for global shortcuts.

It calls two private window-server functions: one so cursor changes are honored while Floaty is in the background, and one for the blur behind a float while dragging. Both are looked up at runtime and skipped if unavailable, but they rule out the Mac App Store.

## Project layout

| File | Purpose |
|---|---|
| `AppDelegate.swift` | Menu bar item, hot keys, capture flow |
| `SelectionOverlay.swift` | Crosshair region selection |
| `ScreenCapturer.swift` | ScreenCaptureKit capture |
| `FloatWindow.swift` | The floating panel, its shadow, resize, opacity, undo |
| `Annotation.swift` | Annotation model and renderer |
| `AnnotationEditor.swift` | Mouse interaction and text editing |
| `AnnotationToolbar.swift` | Toolbar, buttons, hover labels |
| `HistoryStore.swift` | Saving and pruning captures |
| `Settings.swift` | Preferences and the settings window |

The app icon is `Assets/icon.svg`; after editing it, run `swift scripts/make-icon.swift` to regenerate `Assets/Floaty.icns`.

## License

MIT. See [LICENSE](LICENSE).
