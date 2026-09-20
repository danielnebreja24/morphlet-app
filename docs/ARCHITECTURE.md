# Architecture

How Morphlet turns a lid angle into a fold on screen, and which of its
decisions are load-bearing. For the hardware APIs underneath this — HID feature
reports, the clamshell flag, display topology and `IOSurface` — see
[HARDWARE.md](HARDWARE.md).

## The pipeline

```
LidAngleSensor ──angle°──► AppCoordinator ──progress 0…1──► OverlayWindowController
   (30 Hz HID)                  │                              │  (CADisplayLink,
                                │                              │   eases + smoothsteps)
DisplayEnvironment ──docked?────┤                              ▼
StyleModel ──────────prefs──────┘                          FoldLayerView
                                │                          (CALayer transform,
                                ▼                           blur, gradients)
                     ScreenCaptureController                    ▲
                     (60 fps built-in panel) ──IOSurface──► SurfaceMailbox
```

`AppCoordinator` ([`MorphletApp.swift`](../Morphlet/MorphletApp.swift)) owns
every piece and is the only place they meet. Three publishers funnel into one
`refresh()`: the sensor angle, the enabled preference, and the docked flag.
`refresh()` recomputes from scratch each time rather than tracking transitions,
which is why there is no state machine to get out of sync.

## Modules

### LidAngleSensor

The angle comes from a HID **feature report**, not from input events — the
sensor does not stream. The app matches Apple's vendor ID `0x05AC` with usage
page `0x20` (Sensor) / usage `0x8A` (Orientation), then requests feature report
ID 1, which returns `[reportID, angleLow, angleHigh]`: a 16-bit little-endian
value in degrees. Polled at 30 Hz.

This is entirely public `IOHIDManager` API — no private symbols, no bridging
header. It is the same technique the open-source lid-angle tools use.

`openSensor()` deliberately takes one plausible reading (0–360°) before
committing to this path, so a matching-but-unreadable device falls through to
the fallback instead of publishing nothing forever. After 15 consecutive failed
reads at runtime — sensor asleep, device removed — it tears the HID path down
and switches to polling `AppleClamshellState` at 5 Hz, mapping closed to 5° and
open to 100°. Publishing stale data indefinitely would be worse than coarse
data.

### LoginItem

A thin wrapper over `SMAppService.mainApp`, deliberately outside `StyleModel`:
the authoritative state lives in the system, not in `UserDefaults`. The user can
disable the login item in System Settings, and macOS can independently move a
registration into `.requiresApproval`, so `LoginItem` always re-reads `status`
rather than caching a preference that could quietly disagree with reality. The
menu refreshes it on open for the same reason.

Registration needs a signed app in a stable location — it fails from inside
`build/`, so test it from `/Applications`.

### StyleModel

Six persisted preferences, and `progress(forAngle:)`, which maps degrees to
0…1: `0` at or above `startAngle`, `1` at or below `closedAngle`, linear
between, always clamped. If the two angles are equal or inverted it falls back
to a hard threshold rather than dividing by zero or going negative.

Each property writes to `UserDefaults` from `didSet` rather than using
`@AppStorage`. That is not an oversight: `@AppStorage` is a `DynamicProperty`
designed for use inside SwiftUI `View` structs and does not drive a class's
`objectWillChange`. This model must be a plain `ObservableObject` so the
coordinator, the menu bar and Settings can share one instance.

### Displays

`NSScreen.main` is **not** safe here — with an external monitor attached it is
often the external one. Everything that must land on the MacBook's own panel
goes through `Displays.builtInDisplayID` / `builtInScreen`, which filter on
`CGDisplayIsBuiltin`. Both return `nil` when the panel is offline, and callers
are expected to handle that.

`DisplayEnvironment` publishes `isClamshellDocked` — an external display is
active *and* the lid is closed or the built-in panel is gone. It listens for
`didChangeScreenParametersNotification` and also re-checks on a 2-second timer,
because the clamshell flag can update slightly after the display-change
notification fires.

`deviceCornerRadius` is a proportion of panel height (`0.013`) tuned by eye.
macOS does not expose the panel's real corner radius.

### ScreenCaptureController

Captures the built-in display at native Retina resolution (`display.width ×
backingScaleFactor`) in Display P3 at 60 fps, and hands each frame's `IOSurface`
to the renderer. Frames arrive on a background queue; only complete frames carry
new pixels, so idle repeats are filtered on `SCFrameStatus == .complete`.

Permission failures are reported through `permissionDenied` rather than thrown,
because `SCShareableContent.current` and `SCStream.startCapture()` both fail in
permission-shaped ways that the UI wants to present identically.

`start(excluding:)` calls `stop()` first so repeated starts cannot leak streams.

### SurfaceMailbox

A lock-guarded single-slot handoff from the capture queue to the main thread.
Only the newest frame matters, so `put` overwrites and `takeFresh()` returns a
frame only if one arrived since the last call. Note the double optional: the
outer level means "is there news", the inner means "the news is: no surface".

### OverlayWindowController

A borderless, click-through window at `.screenSaver` level on the built-in
panel, with `[.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]` so it
follows the user across Spaces and over full-screen apps.

A `CADisplayLink` drives everything once per display frame. The sensor reports
whole degrees ~30 times a second, so the target arrives in visible steps; the
link eases `current` toward `target` with a 60 ms exponential time constant
(`1 - exp(-dt/τ)`, which is frame-rate independent), snapping to the target
inside 0.0005. `dt` is clamped to 0.1 s so a stalled frame cannot produce a jump.

### FoldLayerView

Pure Core Animation — the captured `IOSurface` goes straight into
`contentLayer.contents` with no per-frame image conversion, and tilt, blur,
glass, sheen and shade are all layer properties, so the GPU composites the whole
effect at refresh rate.

Layer stack, all children of `planeLayer` (anchored at the bottom edge, which is
the hinge):

| Layer        | Role                                                          |
| ------------ | ------------------------------------------------------------- |
| `contentLayer` | The captured desktop, with `CIGaussianBlur`                  |
| `glassLayer`   | Blue wash + highlight, `screenBlendMode`                     |
| `tintLayer`    | Violet tint, `screenBlendMode`                               |
| `sheenLayer`   | Travelling specular band, `overlayBlendMode`; slides with the fold |
| `shadeLayer`   | Darkening, heaviest toward the receding top edge             |
| `cornerMask`   | `CAShapeLayer` mask; top corners rounder than the bottom     |

`apply(eased:ramp:...)` takes two amounts. `eased` (smoothstepped) drives the
visuals; `ramp` (smoothed but un-eased) drives only the corner rounding, so the
corners round early in the close rather than lagging behind the tilt.

## Invariants

Each of these exists because of a specific visible failure. Changing any one of
them without understanding the failure will reintroduce it.

**Show the overlay before starting capture.** `AppCoordinator.refresh()` calls
`overlay.show()` and only then `capture.start(excluding:)`. ScreenCaptureKit can
only exclude a window that is already on screen; get the order wrong and the
overlay mirrors itself into an infinite feedback loop.

**`config.showsCursor = false`.** macOS always draws the real cursor above every
window. Baking one into the mirror too shows *two* — a ghosted double image as
soon as the fold tilts.

**Capture starts 15° early.** `warmupMargin` begins capture before the effect
does, so a live frame is ready the instant the fold starts. The overlay stays
transparent through the pre-warm.

**Teardown waits for flat.** Hiding the window the moment the lid opens past the
start angle would cut a half-folded mirror off mid-animation. `relax()` instead
eases the target to 0 and waits for `onSettledFlat` before hiding and stopping
capture — unless it is already flat, or the built-in panel is gone, in which case
there is nothing to cut off.

**The black behind the fold is the view's own `backgroundColor`,** not a sibling
layer. Core Animation depth-sorts 3D-transformed siblings, so a flat black layer
at z = 0 would draw *over* the receding plane. It also stays clear until the
mirror is fully opaque, or it would darken the real screen through the fading
plane.

**The swap happens while the fold is flat.** Below `visibleThreshold` (0.0005)
the plane is hidden and the live desktop shows through the window; the mirror
then fades in over `fadeRange` (0.0035) while still at an essentially identity
transform. This is what makes the handoff between the real desktop and the
mirror invisible in both directions.

**Target the built-in panel explicitly.** See `Displays` above.

## Tuning constants

All in `FoldLayerView.apply` unless noted.

| Constant | Value | Meaning |
| --- | --- | --- |
| `warmupMargin` | 15° | Pre-warm zone above the start angle (`MorphletApp.swift`) |
| `smoothingTime` | 0.06 s | Easing time constant (`OverlayWindowController`) |
| rotation | `eased × silk × 52°` | Maximum tilt |
| `m34` | `-0.42 / max(w, h)` | Perspective strength |
| blur radius | `eased × frost × 24 × scale` | Quantised to 0.1 to avoid rebuilding the filter every frame |
| `visibleThreshold` | 0.0005 | Below this the live desktop shows through |
| `fadeRange` | 0.0035 | Mirror fade-in, masking the swap |
| corner radius | `deviceCornerRadius × min(ramp / 0.08, 1)` | Top × 1.4, bottom × 0.8 |

## Known rough edges

- Logging is `print`, not `os.Logger`, and some of it is `#if DEBUG`-gated.
  Release builds are quiet, but `print` still isn't the right tool for a
  shipping app — there is no way to read it back from a user's machine.
- There is no update mechanism (no Sparkle), so a shipped build cannot be
  fixed in place.
- `SWIFT_STRICT_CONCURRENCY = minimal`. `SurfaceMailbox` is
  `@unchecked Sendable` with a manual lock; raising the setting will surface
  real work across the capture/main boundary.
- There are no tests and no test target.
