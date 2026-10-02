# Morphlet — notes for agents

macOS menu-bar app (SwiftUI + AppKit + Core Animation) that folds the live
desktop as the MacBook lid closes. Read [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)
before changing rendering, capture or sensor code — it lists the invariants and
the specific bug each one prevents. [`docs/HARDWARE.md`](docs/HARDWARE.md)
covers the four hardware APIs and why each one is used.

## Orientation

- Sources: `Morphlet/*.swift` (9 files, ~1350 lines). Start at
  `MorphletApp.swift` — `AppCoordinator` wires everything together.
- The Xcode project is **file-system synchronized**
  (`PBXFileSystemSynchronizedRootGroup`), so adding or renaming a file under
  `Morphlet/` needs no `project.pbxproj` edit.
- `main` is protected: changes land through a pull request. Releases are
  tagged `v<version>` with the notarized DMG attached as the asset.
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

Distribution is `scripts/release.sh`: it builds the disk image with Developer
ID signing, signs the image itself, submits it to Apple, staples the ticket and
asserts Gatekeeper accepts the result. Everything a user downloads must come
out of that script.

```bash
DEVELOPER_ID="Developer ID Application: DANIEL NEBREJA (VF9J56SQPG)" \
TEAM_ID="VF9J56SQPG" NOTARY_PROFILE="<your-profile>" ./scripts/release.sh
```

`scripts/dmg.sh` and `scripts/package.sh` build the same artifacts signed with
the local certificate only — useful for testing the window layout, refused by
Gatekeeper anywhere else. `release.sh` drives `dmg.sh` through `SIGN_IDENTITY`,
so the notarized image is byte-for-byte the one that was tested.

Three things that will get a submission rejected, all learned the hard way:

- **`CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO` on Release must stay.** Without
  it Xcode injects `com.apple.security.get-task-allow` into Release builds too,
  and Apple refuses anything carrying the debugging entitlement. Debug keeps it
  so the debugger still attaches.
- **Never switch to ad-hoc signing.** Ad-hoc leaves the designated requirement
  empty, so macOS keys the app to its binary fingerprint and every update
  silently revokes the user's Gatekeeper approval and Screen Recording grant.
- **`notarytool --wait` exits 0 even when Apple rejects the build.** Read the
  status back; `release.sh` does, and prints Apple's own reasons. Stapling a
  rejected submission produces an image that still fails on a stranger's Mac.

Both image scripts read `packaging/INSTALL.txt`; edit that file rather than
either script when the user-facing instructions change.

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
- **Never show a window synchronously from `AppCoordinator.init`.** It runs
  inside SwiftUI's scene evaluation, and presenting an `NSHostingView` there
  aborts the app at launch. The welcome window is deferred with
  `DispatchQueue.main.async` for exactly this reason. See ARCHITECTURE.md.
- **`@AppStorage` will not work in `StyleModel`.** It is a `DynamicProperty` for
  `View` structs and does not drive a class's `objectWillChange`. The manual
  `UserDefaults` writes in `didSet` are deliberate.
- **Hardened runtime is ON** and must stay on — notarization requires it.
- **A secure timestamp is required too**, which is why `release.sh` passes
  `--timestamp`. Apple refuses a signature without one.
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
