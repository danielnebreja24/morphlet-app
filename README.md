# Morphlet

A macOS menu-bar app that plays a liquid-glass fold over the live desktop as the
MacBook lid closes. It reads the real hinge angle from the lid-angle sensor, so
the effect tracks the lid continuously rather than snapping at open/closed.

Three knobs shape the effect, all 0–100%:

| Knob      | Effect                                        |
| --------- | --------------------------------------------- |
| **Silk**  | Perspective tilt — the top edge recedes        |
| **Frost** | Blur, glass tint and sheen                     |
| **Shade** | Darkening, heaviest at the edge that folds away |

The effect ramps from 0% at the **start angle** (default 92°) to 100% at the
**closed angle** (default 30°) as the lid comes down. Both are adjustable.

## Requirements

- macOS 14.0 or later
- A MacBook whose hinge reports an angle. Most Apple silicon models do; to
  check a particular machine, run `swift scripts/probe-lid-sensor.swift`.
  Without a sensor the app still runs, but degrades to a coarse open/closed
  signal — see [Degraded mode](#degraded-mode).
- **Screen Recording** permission. The fold is a mirror of the live desktop, so
  macOS requires it. The menu bar shows a button that opens the right Settings
  pane if permission is missing.

## Build and install

```bash
./scripts/install.sh
```

This builds **Release**, copies the app to `/Applications`, then deletes and
unregisters the build copy. Pass `CONFIG=Debug ./scripts/install.sh` when you
want the debug build — it is `-Onone` and defines `DEBUG=1`, which turns on a
per-frame angle log at 30 lines/second: useful while tuning the fold, wrong for
something you run all day.

Both cleanup steps matter:

- **Two copies confuse macOS.** Xcode registers every build product with
  LaunchServices, so a leftover `build/Release/Morphlet.app` gives you duplicate
  Spotlight hits and a second, separate entry in the Screen Recording permission
  list. The script removes it with `lsregister -u`.
- **The script never launches the app.** An app started from a terminal has its
  permission prompts attributed to the terminal, not to itself. Launch Morphlet
  from Spotlight or Finder.

If you build straight from Xcode or `xcodebuild` instead, clean up after
yourself the same way, or you will be granting Screen Recording to the wrong
copy.

## Using it

Morphlet is menu-bar only (`LSUIElement`) — no Dock icon, no main window. The
menu bar popover shows the current lid angle, a master **Enabled** toggle, a
**Launch at login** toggle, any degraded-mode notices, and links to Settings and
Quit. Settings holds the three effect sliders and the two trigger angles. The
sliders and angles persist across launches in `UserDefaults`; the login item
lives in System Settings instead.

### Clamshell mode

With the lid closed on an external display there is nothing to fold, so the
effect suspends and the toggle greys out. The toggle *displays* as off while
docked but does not overwrite your saved preference — undock and it comes back
as you left it.

### Launch at login

Backed by `SMAppService`, so the real state lives in System Settings ▸ General ▸
Login Items rather than in Morphlet's preferences. If macOS puts the
registration into "requires approval", the menu offers a button that opens the
right pane — the toggle alone cannot approve it. Registration wants a signed app
in a stable location, so use `install.sh` rather than running out of `build/`.

### Degraded mode

If the precise HID sensor is missing, or stops responding for 15 consecutive
reads, Morphlet falls back to `AppleClamshellState` from IORegistry. That is an
open/closed flag only, so the fold snaps between flat and folded instead of
tracking the hinge. The menu bar says so.

## Project layout

```
Morphlet.xcodeproj      Xcode project (file-system synchronized — no per-file entries)
Morphlet/               All Swift sources and the asset catalog
  MorphletApp.swift       App entry, AppCoordinator, menu bar and Settings UI
  LidAngleSensor.swift    HID feature-report lid angle + clamshell fallback
  LoginItem.swift         Launch at login, via SMAppService
  StyleModel.swift        Persisted prefs; maps lid angle to effect progress
  Displays.swift          Built-in panel lookup, clamshell detection
  ScreenCaptureController.swift  ScreenCaptureKit mirror of the built-in panel
  OverlayWindowController.swift  Overlay window, frame mailbox, display-link easing
  FoldLayerView.swift     Core Animation renderer
branding/               Glyph, lockup and app icon PNGs
scripts/install.sh      Build, install to /Applications, clean up
scripts/release.sh      Developer ID signing, notarization, stapling
scripts/package.sh      Ad-hoc signed zip for release without a Developer ID
scripts/dmg.sh          Ad-hoc signed .dmg, drag-to-Applications
scripts/make-dmg-background.swift  Regenerates the disk image artwork
packaging/INSTALL.txt   End-user instructions; shared by the zip and the DMG
packaging/dmg-background*.png      Disk image artwork, 1x and 2x
scripts/probe-lid-sensor.swift  Standalone sensor diagnostic
docs/ARCHITECTURE.md    How the pieces fit and why
docs/HARDWARE.md        How the app talks to the sensor, displays and framebuffer
```

Because the project uses a `PBXFileSystemSynchronizedRootGroup`, adding or
renaming a Swift file under `Morphlet/` needs no project-file edit — Xcode picks
it up from disk.

## Signing and release

The app is signed with a **local self-signed certificate named `LidGlass`**,
left over from the project's original name. `CODE_SIGN_IDENTITY` still refers to
it on purpose: the certificate lives in the keychain under that name, and
re-signing with a different identity resets the Screen Recording grant. Renaming
it means creating a new certificate and re-granting permission.

Hardened runtime is **on**, which notarization requires. A public release still
needs an Apple Developer account: the self-signed certificate only works on this
machine, and Gatekeeper rejects it anywhere else (`spctl --assess` says
`rejected`, by design).

Once you have a Developer ID certificate and a stored `notarytool` credential
profile, `scripts/release.sh` does the rest — Release build with Developer ID
signing, signature checks, notarization, stapling, and a final Gatekeeper
assessment. Its header comments list the one-time setup steps. It overrides the
signing identity on the command line, so everyday local builds keep using the
self-signed certificate.

### Publishing without a Developer ID

Until the Apple Developer account exists, `scripts/dmg.sh` produces
`dist/Morphlet-<version>.dmg` with the usual drag-to-Applications layout, and
`scripts/package.sh` produces a plain zip. Both carry the same
`packaging/INSTALL.txt`.

Both sign with the local **self-signed certificate**, not ad-hoc. This matters
more than it looks. Ad-hoc signing leaves the designated requirement empty, so
macOS identifies the app by its exact binary fingerprint — which changes on
every build. Gatekeeper approval and the Screen Recording grant are then lost
on *every update*, and each release makes users re-approve from scratch. The
certificate produces a stable rule instead:

```
identifier "com.danielnebreja.morphlet" and certificate leaf = H"0c31..."
```

That references only the bundle ID and the certificate, so it survives
rebuilds. It does not make Gatekeeper accept the app — only notarization does
that — it just stops the app changing identity every release.

**Verified on 2026-09-20.** Building 0.2 produced a different binary
(`cdhash c59876bf…` → `0832db33…`) with a byte-identical designated
requirement. Installing it over a granted 0.1 kept the Screen Recording
permission: no prompt, capture still working. Under ad-hoc signing that same
cdhash change resets the grant, which is the bug this replaced. Re-run this
check if the signing setup ever changes.

Be clear-eyed about what this costs. Verified by simulating a Safari download:
the signature survives the round trip intact, but `spctl --assess` returns
**rejected**, so every user gets "Morphlet cannot be opened because Apple cannot
check it for malicious software" and must approve the app by hand in System
Settings ▸ Privacy & Security ▸ Open Anyway. The old right-click ▸ Open shortcut
no longer works. Two consequences worth planning for:

- **Put the Gatekeeper steps on the download page**, not only in the zip. People
  who hit an unexplained security dialog delete the app.
- **Lead with the privacy story.** You are asking for Screen Recording on a
  binary macOS just called unverifiable. The honest answer — no networking code,
  no image data written to disk, capture only while the lid is closing — has to
  be visible before the download button, not after it.

Launch at login may also fail on an ad-hoc build, since `SMAppService` prefers a
stable signing identity. The menu surfaces the registration error rather than
failing silently, so you'll hear about it if it happens.

Replace this path with `scripts/release.sh` as soon as the account exists.

Current version: **0.1**, bundle ID `com.danielnebreja.morphlet`.

## Related

- `../morphlet-website` — the marketing site (separate project)
- A Windows port is planned but deferred. Most Windows laptops expose only an
  open/closed switch, so the first step there is a probe to find out whether the
  target hardware reports a hinge angle at all.
