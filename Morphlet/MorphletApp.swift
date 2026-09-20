import SwiftUI
import AppKit
import Combine
import CoreGraphics

/// Owns and wires together the pieces of the app:
/// `StyleModel` (user prefs), `LidAngleSensor` (input), `DisplayEnvironment`
/// (clamshell detection), `ScreenCaptureController` (desktop mirror), and
/// `OverlayWindowController` (renderer).
///
/// Flow, driven by `sensor.$angle`:
///   - lid within the warm-up zone above the start angle → capture running,
///     overlay shown, and the overlay eases toward the angle's fold progress.
///   - anything else (disabled, docked with the lid closed, angle unreadable,
///     lid open past the zone) → the fold eases back to flat, and only once it
///     has settled is the overlay hidden and capture stopped.
@MainActor
final class AppCoordinator: ObservableObject {
    let styleModel = StyleModel()
    let sensor = LidAngleSensor()
    let displays = DisplayEnvironment()
    let loginItem = LoginItem()
    let capture: ScreenCaptureController
    let overlay: OverlayWindowController

    private var cancellables = Set<AnyCancellable>()
    /// Whether capture has been started and the overlay shown for this pass.
    private var captureActive = false
    /// Start capturing this many degrees BEFORE the effect begins, so a live
    /// frame is ready the instant the fold starts. The overlay stays
    /// transparent during this pre-warm.
    private let warmupMargin: Double = 15

    init() {
        let frames = SurfaceMailbox()
        capture = ScreenCaptureController(frames: frames)
        overlay = OverlayWindowController(frames: frames)
        overlay.onSettledFlat = { [weak self] in self?.overlayDidSettleFlat() }
        wire()
        sensor.start()
        capture.requestAccessIfNeeded()
    }

    private func wire() {
        // Any of these can change what should be on screen; they all funnel
        // into refresh(), which recomputes from the current driving angle.
        sensor.$angle
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        styleModel.$isEnabled
            .dropFirst()
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        displays.$isClamshellDocked
            .dropFirst()
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
    }

    private func refresh() {
        guard let angle = activeAngle else {
            relax()
            return
        }

        if !captureActive {
            captureActive = true
            // Show FIRST so the window is on-screen before ScreenCaptureKit
            // excludes it (otherwise it would mirror itself — feedback loop).
            overlay.show()
            Task { [weak self] in
                guard let self else { return }
                await self.capture.start(excluding: self.overlay.window)
            }
        }

        overlay.setTarget(
            progress: styleModel.progress(forAngle: angle),
            silk: styleModel.silk,
            frost: styleModel.frost,
            shade: styleModel.shade
        )
    }

    /// The lid angle while the effect should run: enabled, not docked, and the
    /// lid within the warm-up zone above the start angle. Nil otherwise.
    private var activeAngle: Double? {
        guard styleModel.isEnabled, !displays.isClamshellDocked, let angle = sensor.angle,
              angle < styleModel.startAngle + warmupMargin else { return nil }
        return angle
    }

    /// Eases the fold back to flat. Hiding right away would cut a half-folded
    /// mirror off mid-animation, so teardown waits for the overlay to settle —
    /// unless it's already flat, or the built-in panel is gone (nothing to see).
    private func relax() {
        guard captureActive else { return }
        if overlay.isFlat || Displays.builtInScreen == nil {
            deactivate()
        } else {
            overlay.setTarget(progress: 0, silk: styleModel.silk, frost: styleModel.frost, shade: styleModel.shade)
        }
    }

    private func overlayDidSettleFlat() {
        if activeAngle == nil {
            deactivate()
        }
    }

    private func deactivate() {
        overlay.hide()
        capture.stop()
        captureActive = false
    }
}

@main
struct MorphletApp: App {
    @StateObject private var coordinator = AppCoordinator()

    var body: some Scene {
        MenuBarExtra("Morphlet", image: "MenuBarIcon") {
            MenuBarContent(coordinator: coordinator)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(styleModel: coordinator.styleModel)
        }
    }
}

/// MenuBarExtra popover content: status line, master toggle, degraded-mode
/// notices, and links to Settings / Quit.
private struct MenuBarContent: View {
    @ObservedObject private var styleModel: StyleModel
    @ObservedObject private var sensor: LidAngleSensor
    @ObservedObject private var capture: ScreenCaptureController
    @ObservedObject private var displays: DisplayEnvironment
    @ObservedObject private var loginItem: LoginItem
    @Environment(\.openSettings) private var openSettings

    init(coordinator: AppCoordinator) {
        styleModel = coordinator.styleModel
        sensor = coordinator.sensor
        capture = coordinator.capture
        displays = coordinator.displays
        loginItem = coordinator.loginItem
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Morphlet")
                    .font(.headline)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("Enabled", isOn: enabledBinding)
                .toggleStyle(.switch)
                .disabled(displays.isClamshellDocked)

            Toggle("Launch at login", isOn: loginItemBinding)
                .toggleStyle(.switch)

            if loginItem.needsApproval {
                Button {
                    loginItem.openLoginItemsSettings()
                } label: {
                    Label("Approve Morphlet in Login Items…", systemImage: "person.badge.clock")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
            }

            if let error = loginItem.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if displays.isClamshellDocked {
                Label("Paused while the lid is closed on an external display", systemImage: "display")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !sensor.isAvailable {
                Label("Lid-angle sensor unavailable — degraded mode", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if capture.permissionDenied {
                Button {
                    capture.requestAccessIfNeeded()
                    capture.openScreenRecordingSettings()
                } label: {
                    Label("Allow Screen Recording in Settings…", systemImage: "video.slash")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
            }

            Divider()

            Button {
                // Accessory (menu-bar) apps don't auto-activate, so the
                // Settings window can open behind everything. Activate first,
                // then open it, so it reliably comes to the front.
                NSApplication.shared.activate(ignoringOtherApps: true)
                openSettings()
            } label: {
                Text("Settings…")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Text("Quit")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 260)
        // The user can change the login item in System Settings while the app
        // runs, so re-read it each time the menu opens rather than trusting
        // whatever we last saw.
        .onAppear { loginItem.refresh() }
    }

    private var loginItemBinding: Binding<Bool> {
        Binding(
            get: { loginItem.isEnabled },
            set: { loginItem.setEnabled($0) }
        )
    }

    /// Shows the switch as off while docked without overwriting the saved
    /// preference, so it comes back as the user left it after undocking.
    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { styleModel.isEnabled && !displays.isClamshellDocked },
            set: { styleModel.isEnabled = $0 }
        )
    }

    private var statusText: String {
        guard sensor.isAvailable, let angle = sensor.angle else {
            return "Lid angle unavailable"
        }
        return String(format: "Lid angle: %.0f°", angle)
    }
}

/// Settings scene: Silk / Frost / Shade multipliers, plus the start/closed
/// trigger angles.
private struct SettingsView: View {
    @ObservedObject var styleModel: StyleModel

    var body: some View {
        Form {
            Section("Effect") {
                LabeledSlider(title: "Silk", subtitle: "Perspective tilt", value: $styleModel.silk)
                LabeledSlider(title: "Frost", subtitle: "Blur / liquid glass", value: $styleModel.frost)
                LabeledSlider(title: "Shade", subtitle: "Darkening", value: $styleModel.shade)
            }

            Section("Trigger angles") {
                Stepper(value: $styleModel.startAngle, in: 0...180, step: 1) {
                    Text("Start angle: \(Int(styleModel.startAngle))°")
                }
                Stepper(value: $styleModel.closedAngle, in: 0...180, step: 1) {
                    Text("Closed angle: \(Int(styleModel.closedAngle))°")
                }
                Text("Effect ramps from 0% at the start angle to 100% at the closed angle as the lid comes down.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(28)
        .frame(width: 460)
    }
}

private struct LabeledSlider: View {
    let title: String
    let subtitle: String
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(String(format: "%.0f%%", value * 100))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: 0...1)
        }
        .padding(.vertical, 2)
    }
}
