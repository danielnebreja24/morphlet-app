# Morphlet — notes for agents

macOS menu-bar app (SwiftUI + AppKit + Core Animation) that folds the live
desktop as the MacBook lid closes. Read [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)
before changing rendering, capture or sensor code — it lists the invariants and
the specific bug each one prevents. [`docs/HARDWARE.md`](docs/HARDWARE.md)
covers the four hardware APIs and why each one is used.

## Orientation

- Sources: `Morphlet/*.swift` (8 files, ~1200 lines). Start at
  `MorphletApp.swift` — `AppCoordinator` wires everything together.
- The Xcode project is **file-system synchronized**
  (`PBXFileSystemSynchronizedRootGroup`), so adding or renaming a file under
  `Morphlet/` needs no `project.pbxproj` edit.
- Not a git repository. There is no undo — check before overwriting.
- No tests, no test target. Verification means building and running.

## Build

```bash
./scripts/install.sh              # Release (default)
CONFIG=Debug ./scripts/install.sh # -Onone, DEBUG=1, 30 log lines/sec
```

Builds, installs to `/Applications`, then unregisters and deletes the build
copy. If you instead run `xcodebuild` directly, do that cleanup yourself:

```bash
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u build/Release/Morphlet.app
rm -rf build/Release/Morphlet.app
```

Distribution: `scripts/release.sh` (Developer ID + notarization) is the real
path. `scripts/dmg.sh` and `scripts/package.sh` are the interim ones — signed with
the local certificate, not notarized, Gatekeeper-rejected by design — used
until the Apple Developer account exists. **Do not switch these to ad-hoc
signing.** Ad-hoc leaves the designated requirement empty, so macOS keys the
app to its binary fingerprint and every update silently revokes the user's
Gatekeeper approval and Screen Recording grant. Both read `packaging/INSTALL.txt`; edit that file
rather than either script when the user-facing instructions change.

`dmg.sh` styles the disk image window by driving Finder through AppleScript.
Three things about that are easy to break: the window must be **closed** at the
end (closing is what flushes `.DS_Store`), an extra open/close cycle after
positioning discards the layout, and the script reads the icon size and app
position back from Finder and fails loudly if they don't match — keep that
check. The geometry constants at the top must stay in sync with
`packaging/dmg-background.png`, whose arrow is drawn on the icon row; rerun
`swift scripts/make-dmg-background.swift` after changing either.
`swift scripts/probe-lid-sensor.swift` diagnoses sensor problems without
building anything.

A stray second copy produces duplicate Spotlight hits and a **separate entry in
the Screen Recording permission list**, which then silently isn't the copy the
user granted.

**Never launch the app from the shell.** A process started from a terminal has
its TCC permission prompts attributed to the terminal, not to Morphlet. Ask the
user to launch it from Spotlight or Finder.

## Things that will bite you

- **`CODE_SIGN_IDENTITY = "LidGlass"` is correct — do not "fix" it.** It names a
  local self-signed certificate in the keychain, left from the project's former
  name. Re-signing with a different identity resets the user's Screen Recording
  grant. Renaming it requires creating a new certificate and re-granting.
- **The product name is Morphlet everywhere else.** The project, target, folder
  and source directory were renamed from LidGlass; the certificate is the only
  survivor. Bundle ID is `com.danielnebreja.morphlet`.
- **`NSScreen.main` is wrong in this codebase.** With an external display
  attached it is often the external one. Use `Displays.builtInScreen` /
  `Displays.builtInDisplayID`, and handle their `nil`.
- **Order matters in `AppCoordinator.refresh()`**: show the overlay *before*
  starting capture, or ScreenCaptureKit cannot exclude the overlay and it
  mirrors itself infinitely.
- **`@AppStorage` will not work in `StyleModel`.** It is a `DynamicProperty` for
  `View` structs and does not drive a class's `objectWillChange`. The manual
  `UserDefaults` writes in `didSet` are deliberate.
- **Hardened runtime is ON** and must stay on — notarization requires it.
- **`SMAppService` needs a signed app in a stable location.** Launch-at-login
  registration fails from inside `build/`; test it from `/Applications`.
- Requires Screen Recording permission and a real lid-angle sensor. Behaviour
  degrades deliberately without either — see the README.

## Conventions

- Comments explain **why**, not what. The existing header comments carry the
  design rationale; keep that up when you change the reasoning behind a
  constant or an ordering.
- `@MainActor` on the controller/model classes; only the capture callback and
  the poll timers run off the main thread, handing back through
  `SurfaceMailbox` or `DispatchQueue.main.async`.
- Swift 5.0, `SWIFT_STRICT_CONCURRENCY = minimal`, macOS 14.0 deployment target.
- Tuning constants live next to the code that uses them, with a comment on why
  that value. `docs/ARCHITECTURE.md` has the table.

## Related projects

The marketing site lives at [morphlet.fujiui.com](https://morphlet.fujiui.com)
and is a separate repository. A Windows port is planned but deferred, and would
be a separate codebase — only the design and logic carry over, since most
Windows laptops report only an open/closed switch.
