# Talking to the hardware

Morphlet has four separate conversations with the Mac, each through a different
API family. None of them use private symbols — which matters, because private
API would both break on OS updates and block notarization.

| What we need | Layer | API |
| --- | --- | --- |
| Lid angle in degrees | HID device | `IOHIDManager` feature report |
| Lid open/closed (fallback) | Kernel property | `IORegistry` / `AppleClamshellState` |
| Which panel is the built-in one | Display topology | CoreGraphics `CGDisplayIsBuiltin` |
| The desktop's pixels | Framebuffer | ScreenCaptureKit → `IOSurface` |

## IOKit in one paragraph

macOS drivers publish themselves into the **IORegistry**, a live tree of every
device and driver in the system, each node carrying typed key/value properties.
User-space code never talks to hardware directly; it asks the kernel for a node
matching some description, gets back a Mach port, and reads properties or sends
requests through it. Two things in this project use that tree — the HID sensor
(via the HID family layered on top) and the clamshell flag (read straight off a
node). You can browse the whole thing yourself with `ioreg`.

## 1. The lid-angle sensor

### Finding it

The sensor is an **HID device**. HID describes what a device *means* using a
two-part code: a *usage page* (broad category) and a *usage* (specific role).
Morphlet matches on three properties:

```swift
kIOHIDVendorIDKey:        0x05AC   // Apple
kIOHIDDeviceUsagePageKey: 0x20     // Sensor
kIOHIDDeviceUsageKey:     0x8A     // Orientation
```

`IOHIDManagerSetDeviceMatching` turns that dictionary into a kernel query, and
`IOHIDManagerCopyDevices` returns whatever matched. Nothing here is
Morphlet-specific — this is the same public path any HID app uses for a mouse or
a gamepad.

### The part that surprises people

**The sensor does not send input events.** A mouse streams *input reports* at
you; this device sits silent. The angle is only available if you go and ask for
it, by requesting **feature report ID 1**:

```swift
IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &report, &length)
```

Feature reports are HID's mechanism for *state you query*, as opposed to *events
you receive* — think "current brightness" rather than "a key went down". That is
why `LidAngleSensor` runs a polling timer instead of installing a callback, and
it's the single detail that makes this whole app possible.

The reply is three bytes:

```
  byte 0    report ID (always 1, echoed back)
  byte 1    angle, low byte
  byte 2    angle, high byte
```

A 16-bit little-endian integer in degrees: `Int(report[1]) | (Int(report[2]) << 8)`.
0 is shut, ~90 is a right angle, 130+ is wide open.

### Verified on an M3 Pro, macOS 26.5

```
  Manufacturer         Apple
  Transport            SPU          ← Sensor Processing Unit, not USB
  VendorID             1452         ← 0x05AC
  ProductID            33028        ← 0x8104
  PrimaryUsagePage     32           ← 0x20, Sensor
  PrimaryUsage         138          ← 0x8A, Orientation
  ReportInterval       8000         ← microseconds, i.e. 125 Hz capable

  0°  01 00 00     ← lid closed
```

Run `swift scripts/probe-lid-sensor.swift` to reproduce this on any Mac; it
needs no permissions and no app bundle.

Note `ReportInterval = 8000 µs` — the hardware can sustain 125 Hz. Morphlet
polls at 30 Hz, which is a deliberate trade: the display link smooths between
samples anyway (see [ARCHITECTURE.md](ARCHITECTURE.md)), so a faster poll would
cost power without looking better.

### Robustness

`openSensor()` takes one reading and sanity-checks it (0–360°) before committing
to this path, so a device that matches but won't answer falls through to the
fallback instead of leaving the app silently dead. At runtime, 15 consecutive
failed reads tear the HID path down and switch over — sensors sleep, and
publishing a stale angle forever is worse than admitting coarse resolution.

## 2. The clamshell fallback

Completely different mechanism: no HID, just a property read off a kernel node.

```swift
IOServiceMatching("IOPMrootDomain")        // power management root
IORegistryEntryCreateCFProperty(service, "AppleClamshellState", ...)
```

`IOPMrootDomain` is the power-management root node; `AppleClamshellState` is a
boolean it publishes — true when the lid is shut. `Displays.clamshellClosed()`
tries `IOPMrootDomain` first, then `AppleDeviceManagementHIDEventService`, since
which node carries the flag has varied across models.

This is open/closed only, so degraded mode snaps between flat and folded rather
than tracking the hinge. It's also pure IOKit with no main-thread requirement,
which is why it can be called from the poll queue.

You can read it yourself:

```bash
ioreg -r -k AppleClamshellState | grep AppleClamshellState
```

## 3. Which display is the built-in one

CoreGraphics, not AppKit. `CGGetActiveDisplayList` enumerates every display
currently drawing, and `CGDisplayIsBuiltin(id)` identifies the internal panel.

This matters more than it sounds. **`NSScreen.main` is the screen with the key
window** — with an external monitor attached it is frequently the external one,
so using it would put the fold on the wrong display. Everything in `Displays`
goes through `CGDisplayIsBuiltin` instead, and `builtInDisplayID` returns `nil`
when the panel is off, which is what clamshell detection keys off.

The panel's physical corner radius is *not* exposed by any public API, so
`deviceCornerRadius` approximates it as 1.3% of panel height, tuned by eye.

## 4. The desktop's pixels

ScreenCaptureKit hands back each frame as a `CVPixelBuffer` wrapping an
**`IOSurface`** — a buffer that can be shared between processes and, crucially,
between CPU and GPU without copying.

That's what makes the effect cheap. The surface goes straight into
`contentLayer.contents`, so the captured desktop is never converted to an
`NSImage`, never round-trips through main memory, and is never drawn by the CPU.
The frame stays in GPU memory from the moment the compositor produced it to the
moment it's composited back out with a perspective transform on it.

Two hardware-adjacent details in the capture config:

- `colorSpaceName = .displayP3` and native-resolution `width`/`height` tagged
  with `backingScaleFactor`, so the mirror is pixel- and color-identical to the
  live panel at the instant of the swap. Any mismatch would show as a flash.
- `showsCursor = false`, because the cursor is drawn by the display hardware
  above every window. Capturing it would put a second, ghosted cursor inside the
  folding plane.

This path is what requires **Screen Recording** permission. Nothing is written
or transmitted — there is no networking or file-writing code in the app at all.

## Porting this

Only the sensor layer is Apple-specific, but it's the layer the whole idea rests
on. Most Windows laptops expose a lid **switch**, not an angle — the hinge-angle
sensor exists mainly on 2-in-1 and dual-screen machines. So the first step of a
Windows port is a probe equivalent to `scripts/probe-lid-sensor.swift` that
answers "does this hardware report an angle at all", before any UI work happens.
The rendering and easing design carries over; the input does not.
