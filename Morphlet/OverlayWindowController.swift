import AppKit
import IOSurface
import QuartzCore

/// Hands the newest captured frame from ScreenCaptureKit's queue to the main
/// thread. Only the latest frame matters, so older ones are simply replaced.
final class SurfaceMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var surface: IOSurface?
    private var isFresh = false

    func put(_ surface: IOSurface?) {
        lock.lock()
        self.surface = surface
        isFresh = true
        lock.unlock()
    }

    /// The newest frame if one arrived since the last call, else nil.
    func takeFresh() -> IOSurface?? {
        lock.lock()
        defer { lock.unlock() }
        guard isFresh else { return nil }
        isFresh = false
        return .some(surface)
    }
}

/// Owns the borderless, click-through, full-screen window on the built-in
/// panel that renders the fold, and drives it once per display frame.
///
/// The lid sensor reports whole degrees about 30 times a second, so the target
/// arrives in steps. A display link eases the rendered value toward it every
/// frame, and the swap between the live desktop and the mirror happens only
/// while that eased value is near zero — with the mirror still untransformed —
/// so the fold neither jumps in when closing nor gets cut off when opening.
@MainActor
final class OverlayWindowController: NSObject {
    private(set) var window: NSWindow?
    private var foldView: FoldLayerView?
    private let frames: SurfaceMailbox
    private var displayLink: CADisplayLink?

    private var target: CGFloat = 0
    private var current: CGFloat = 0
    private var lastTimestamp: CFTimeInterval?
    private var silk: CGFloat = 1
    private var frost: CGFloat = 1
    private var shade: CGFloat = 1

    /// How quickly the rendered fold catches up with the sensor, in seconds.
    private let smoothingTime: CFTimeInterval = 0.06

    /// Called each time the fold finishes easing back to flat with a flat
    /// target — the point where hiding the window can't cut it off.
    var onSettledFlat: (() -> Void)?

    /// True when the fold is flat and not heading anywhere.
    var isFlat: Bool { current == 0 && target == 0 }

    init(frames: SurfaceMailbox) {
        self.frames = frames
        super.init()

        // Prefer the built-in panel. If the app launches while docked, fall
        // back to any screen so the window exists; show() moves it back.
        guard let screen = Displays.builtInScreen ?? NSScreen.main else { return }

        let panel = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false

        let view = FoldLayerView(frame: NSRect(origin: .zero, size: screen.frame.size))
        panel.contentView = view
        foldView = view
        window = panel
    }

    /// Orders the overlay to the front on the built-in panel, without
    /// activating the app, and starts driving it. Stays hidden when the
    /// built-in panel is offline (lid closed on an external display).
    func show() {
        guard let window, let screen = Displays.builtInScreen else { return }
        if window.frame != screen.frame {
            window.setFrame(screen.frame, display: true)
        }
        // Drop any frame left over from the previous session so the first
        // mirror shown is a fresh one.
        _ = frames.takeFresh()
        foldView?.setSurface(nil)
        window.orderFrontRegardless()
        startDisplayLink()
    }

    func hide() {
        window?.orderOut(nil)
        displayLink?.isPaused = true
        target = 0
        current = 0
        lastTimestamp = nil
        foldView?.setSurface(nil)
        foldView?.apply(eased: 0, ramp: 0, silk: silk, frost: frost, shade: shade)
    }

    /// Sets where the fold should head (0 flat … 1 folded) and the style
    /// multipliers. The display link eases toward it.
    func setTarget(progress: Double, silk: Double, frost: Double, shade: Double) {
        target = CGFloat(min(max(progress, 0), 1))
        self.silk = CGFloat(silk)
        self.frost = CGFloat(frost)
        self.shade = CGFloat(shade)
    }

    private func startDisplayLink() {
        if displayLink == nil, let foldView {
            let link = foldView.displayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        lastTimestamp = nil
        displayLink?.isPaused = false
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let foldView else { return }
        if let update = frames.takeFresh() {
            foldView.setSurface(update)
        }

        let dt = min(lastTimestamp.map { link.timestamp - $0 } ?? link.duration, 0.1)
        lastTimestamp = link.timestamp
        let wasFlat = isFlat
        current += (target - current) * CGFloat(1 - exp(-dt / smoothingTime))
        if abs(target - current) < 0.0005 {
            current = target
        }

        // Smoothstep: zero slope at both ends, so the fold starts from rest
        // instead of jumping by the first sensor step.
        let eased = current * current * (3 - 2 * current)
        foldView.apply(eased: eased, ramp: current, silk: silk, frost: frost, shade: shade)

        if isFlat && !wasFlat {
            onSettledFlat?()
        }
    }
}
