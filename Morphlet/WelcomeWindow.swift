//
//  WelcomeWindow.swift
//  Morphlet
//
//  Shown once, the first time Morphlet runs.
//
//  Nothing can greet the user at the moment they drag the app into
//  Applications — that is Finder copying a folder, with no Morphlet process in
//  existence to say anything. The first instant we can speak is launch, and
//  launch is exactly when a menu-bar app looks broken: no Dock icon, no window,
//  no visible change. This window is the one chance to say "it worked, look up
//  there", and it closes for good once seen.
//

import AppKit
import SwiftUI

/// Remembers whether the welcome has been shown, so it appears exactly once.
@MainActor
final class WelcomeState: ObservableObject {
    private static let key = "hasSeenWelcome"

    @Published var isPresented: Bool

    init() {
        isPresented = !UserDefaults.standard.bool(forKey: Self.key)
    }

    /// Marks the welcome as seen. Called when the window is dismissed, not when
    /// it opens, so a crash on first run does not cost the user the greeting.
    func dismiss() {
        UserDefaults.standard.set(true, forKey: Self.key)
        isPresented = false
    }
}

struct WelcomeView: View {
    @ObservedObject var welcome: WelcomeState
    @ObservedObject var capture: ScreenCaptureController
    @ObservedObject var sensor: LidAngleSensor
    /// Closes the hosting window. Owned by AppKit, not SwiftUI.
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Morphlet is running")
                        .font(.system(size: 20, weight: .semibold))
                    Text("Look for its glyph in the menu bar, at the top right of your screen. Morphlet has no Dock icon and no main window — that is normal.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, 20)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                Row(
                    done: !capture.permissionDenied,
                    title: "Screen Recording",
                    detail: capture.permissionDenied
                        ? "Needed to mirror your desktop while the lid closes. Nothing is saved or sent."
                        : "Allowed. Nothing is saved or sent."
                )
                Row(
                    done: sensor.isAvailable,
                    title: "Lid-angle sensor",
                    detail: sensor.isAvailable
                        ? "Found. The fold will track your hinge as it closes."
                        : "Not found on this Mac. The effect will snap between flat and folded instead of tracking the lid."
                )
            }
            .padding(.vertical, 18)

            Divider()

            HStack(spacing: 12) {
                if capture.permissionDenied {
                    Button("Allow Screen Recording…") {
                        capture.requestAccessIfNeeded()
                        capture.openScreenRecordingSettings()
                    }
                }
                Spacer()
                Button("Close your lid to try it") {
                    welcome.dismiss()
                    onDismiss()
                }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 18)
        }
        .padding(28)
        .frame(width: 460)
    }
}

/// One checklist line: a filled tick once the thing is actually in place.
private struct Row: View {
    let done: Bool
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(done ? Color.accentColor : .secondary)
                .font(.system(size: 15))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}


/// Owns the welcome window.
///
/// A SwiftUI `Window` scene will not open itself in an accessory app — it waits
/// for `openWindow`, which an app with no views of its own has no natural place
/// to call. An NSWindow built here opens exactly when we say so.
@MainActor
final class WelcomeWindowController {
    private var window: NSWindow?

    func presentIfNeeded(
        welcome: WelcomeState,
        capture: ScreenCaptureController,
        sensor: LidAngleSensor
    ) {
        guard welcome.isPresented, window == nil else { return }
        // Read the current grant before the view exists, rather than from the
        // view's onAppear: changing published state mid-render is another way
        // to trip the same SwiftUI abort.
        capture.refreshPermission()

        let view = WelcomeView(
            welcome: welcome,
            capture: capture,
            sensor: sensor,
            onDismiss: { [weak self] in self?.close() }
        )
        let panel = NSWindow(contentViewController: NSHostingController(rootView: view))
        panel.title = "Welcome to Morphlet"
        panel.styleMask = [.titled, .closable]
        panel.isReleasedWhenClosed = false
        panel.center()
        // An accessory app does not come forward on its own, so without this
        // the window opens behind whatever the user is already looking at.
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        window = panel
    }

    func close() {
        window?.close()
        window = nil
    }
}
