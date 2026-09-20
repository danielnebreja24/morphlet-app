# Morphlet

A macOS menu-bar app that plays a liquid-glass fold over your live desktop as
the MacBook lid closes. It reads the real hinge angle, so the effect tracks the
lid continuously instead of snapping between open and closed.

Three knobs shape the effect, all 0–100%:

| Knob      | Effect                                           |
| --------- | ------------------------------------------------ |
| **Silk**  | Perspective tilt — the top edge recedes           |
| **Frost** | Blur, glass tint and sheen                        |
| **Shade** | Darkening, heaviest at the edge that folds away   |

The effect ramps from 0% at the **start angle** (default 92°) to 100% at the
**closed angle** (default 30°) as the lid comes down. Both are adjustable.

## How it works

You cannot bend what is actually on screen, so Morphlet does a substitution.
While the lid is open you are looking at your real desktop. The moment the fold
begins, Morphlet slips a full-screen mirror of that desktop in front of it and
folds *the mirror* — your real desktop is untouched underneath.

The whole trick is making that swap invisible:

- **The mirror is warm before it is needed.** Capture starts 15° before the
  effect does, so a live frame is ready the instant the fold begins.
- **The swap happens while the mirror is flat.** Below a tiny threshold the
  mirror is hidden and the live desktop shows through; it then fades in while
  still at an identity transform, so it is pixel-identical to what it replaces.
- **Teardown waits.** Opening the lid eases the fold back to flat before the
  window is hidden, so a half-folded mirror is never cut off mid-animation.

Three clocks run independently and never block each other: the lid sensor is
polled at 30 Hz, ScreenCaptureKit produces frames at 60 fps, and a display link
renders at your screen's refresh rate, easing between the sensor's coarse
whole-degree steps. Captured frames go straight from the compositor into a
`CALayer` as an `IOSurface` — never converted, never copied through main
memory — so tilt, blur and shade are composited entirely on the GPU.

[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) covers the design in full,
including the invariants that each exist because of a specific visible bug.
[`docs/HARDWARE.md`](docs/HARDWARE.md) covers how the app talks to the lid
sensor, the displays and the framebuffer.

## Privacy

Morphlet needs Screen Recording permission, because the fold is a live mirror
of your desktop and there is no way to bend what is on screen without first
being able to see it.

**Nothing leaves your Mac.** There is no networking code in the app at all, and
no image data is ever written to disk. Captured frames live in GPU memory and
are discarded. The only things stored anywhere are five preference values: the
three effect sliders and the two trigger angles.

Capture only runs while the lid is on its way down. With the lid open past the
start angle, nothing is being captured.

## Requirements

- macOS 14.0 or later
- A MacBook whose hinge reports an angle. Most Apple silicon models do; to check
  a particular machine, run `swift scripts/probe-lid-sensor.swift`. Without a
  sensor the app still runs, but falls back to a coarse open/closed signal — see
  [Degraded mode](#degraded-mode).

## Build and install

Clone the repo and run:

```bash
./scripts/install.sh
```

This builds a Release copy, installs it to `/Applications`, then removes and
unregisters the build copy. Pass `CONFIG=Debug ./scripts/install.sh` for a debug
build — it is unoptimised and logs the lid angle 30 times a second, which is
useful while tuning the fold and wrong for everyday use.

Two details the script handles, and that are worth matching if you build with
Xcode directly:

- **Remove the build copy.** Xcode registers every build product with
  LaunchServices, so a leftover `build/Release/Morphlet.app` produces duplicate
  Spotlight hits and a second, separate entry in the Screen Recording permission
  list — and you end up granting permission to the copy you are not running.
- **Do not launch it from a terminal.** An app started from a shell has its
  permission prompts attributed to the terminal rather than to itself. Open
  Morphlet from Spotlight or Finder.

Morphlet is not notarized by Apple. A copy you build yourself runs without
complaint, but one downloaded from the internet is blocked on first launch —
open **System Settings ▸ Privacy & Security** and click **Open Anyway**.

## Using it

Morphlet is menu-bar only — no Dock icon and no main window. The menu bar
popover shows the current lid angle, a master **Enabled** toggle, a **Launch at
login** toggle, any degraded-mode notices, and links to Settings and Quit.
Settings holds the three effect sliders and the two trigger angles.

Since there is no Dock icon, pressing ⌘Space and typing "Morphlet" is the
quickest way to reopen it.

### Clamshell mode

With the lid closed on an external display there is nothing to fold, so the
effect suspends and the toggle greys out. The toggle *displays* as off while
docked but does not overwrite your saved preference — undock and it returns as
you left it.

### Launch at login

Backed by `SMAppService`, so the real state lives in System Settings ▸ General ▸
Login Items rather than in Morphlet's own preferences. If macOS puts the
registration into "requires approval", the menu offers a button that opens the
right pane. Registration expects the app in a stable location, so install it to
`/Applications` rather than running it out of `build/`.

### Degraded mode

If the lid-angle sensor is missing, or stops responding, Morphlet falls back to
the system's open/closed lid flag. That has no angle resolution, so the fold
snaps between flat and folded instead of tracking the hinge. The menu bar says
when this happens.

## Project layout

```
Morphlet/                 Swift sources and the asset catalog
  MorphletApp.swift         App entry, coordinator, menu bar and Settings UI
  LidAngleSensor.swift      Lid angle, with a coarse fallback
  LoginItem.swift           Launch at login
  StyleModel.swift          Persisted preferences; angle to effect progress
  Displays.swift            Built-in panel lookup, clamshell detection
  ScreenCaptureController.swift   Desktop mirror
  OverlayWindowController.swift   Overlay window and frame easing
  FoldLayerView.swift       Core Animation renderer
scripts/install.sh        Build and install to /Applications
scripts/probe-lid-sensor.swift   Standalone sensor diagnostic
docs/                     Architecture and hardware notes
branding/                 Glyph, lockup and app icon
```

The Xcode project is file-system synchronized, so adding or renaming a Swift
file under `Morphlet/` needs no project-file edit.

## Roadmap

A Windows version is planned but deferred. Most Windows laptops expose only an
open/closed switch rather than a hinge angle, so the first step there is finding
out whether the target hardware reports an angle at all.
