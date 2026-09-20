//
//  ScreenCaptureController.swift
//  Morphlet
//
//  Captures the live built-in panel via ScreenCaptureKit and hands each new
//  frame's IOSurface to the renderer, which shows it directly in a layer. The
//  overlay window itself is excluded from the capture so it doesn't appear
//  inside its own frame (which would create an infinite mirror).
//

import AppKit
import CoreMedia
import IOSurface
import ScreenCaptureKit

@MainActor
final class ScreenCaptureController: NSObject, ObservableObject {

    /// True once we've determined Screen Recording permission is denied
    /// (or capture setup otherwise failed for a permission-shaped reason).
    /// The UI layer can use this to point the user at System Settings.
    @Published private(set) var permissionDenied: Bool = false

    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "com.morphlet.screencapture.samples")
    nonisolated private let frames: SurfaceMailbox

    init(frames: SurfaceMailbox) {
        self.frames = frames
        super.init()
    }

    /// Asks macOS for Screen Recording access if it hasn't been granted yet,
    /// using Apple's explicit request API, which registers the app in System
    /// Settings' Screen Recording list. macOS shows its prompt only the first
    /// time; later calls just report the current state.
    func requestAccessIfNeeded() {
        if CGPreflightScreenCaptureAccess() {
            permissionDenied = false
        } else {
            permissionDenied = !CGRequestScreenCaptureAccess()
        }
    }

    /// Opens System Settings at Privacy & Security → Screen Recording.
    func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Starts capturing the built-in panel, excluding `window` (the app's own
    /// overlay) from what gets captured. Safe to call again after `stop()`.
    /// Failures, including denied Screen Recording permission, are reported
    /// via `permissionDenied` rather than thrown.
    func start(excluding window: NSWindow?) async {
        // Tear down any previous session first so repeated calls to
        // start() don't leak streams.
        stop()

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            print("[Capture] failed to get shareable content (permission denied?): \(error)")
            permissionDenied = true
            return
        }

        guard let display = pickMainDisplay(from: content.displays) else {
            print("[Capture] no shareable display found")
            permissionDenied = true
            return
        }

        var excludedWindows: [SCWindow] = []
        if let window {
            if let matched = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) {
                excludedWindows = [matched]
            } else {
                print("[Capture] could not find SCWindow matching overlay window (windowNumber \(window.windowNumber)); excluding none")
            }
        }

        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)

        let config = SCStreamConfiguration()
        config.pixelFormat = kCVPixelFormatType_32BGRA
        // Tag frames in the panel's wide color space so the mirror's colors
        // match the live screen exactly at the moment of the swap.
        config.colorSpaceName = CGColorSpace.displayP3
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        // Capture at native (Retina) pixel resolution so the mirror is as
        // crisp as the live desktop.
        let scale = (Displays.builtInScreen ?? NSScreen.main)?.backingScaleFactor ?? 2.0
        config.width = Int(Double(display.width) * scale)
        config.height = Int(Double(display.height) * scale)
        config.queueDepth = 5
        // Must stay false: macOS always draws the real cursor above every
        // window, so baking one into the mirror too shows TWO cursors — a
        // ghosted double image as soon as the fold tilts.
        config.showsCursor = false

        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            try await newStream.startCapture()
            stream = newStream
            permissionDenied = false
        } catch {
            print("[Capture] failed to start capture: \(error)")
            // SCStream throws essentially the same permission-flavored
            // errors here as SCShareableContent.current does.
            permissionDenied = true
            stream = nil
        }
    }

    /// Stops capturing. Safe to call even if capture was never started.
    func stop() {
        guard let stream else { return }
        self.stream = nil
        Task {
            do {
                try await stream.stopCapture()
            } catch {
                print("[Capture] error stopping capture: \(error)")
            }
        }
    }

    /// The built-in panel (the one that folds), falling back to the main
    /// display. With an external monitor attached, main is often the external.
    private func pickMainDisplay(from displays: [SCDisplay]) -> SCDisplay? {
        let targetID = Displays.builtInDisplayID ?? CGMainDisplayID()
        return displays.first(where: { $0.displayID == targetID }) ?? displays.first
    }
}

// MARK: - SCStreamOutput

extension ScreenCaptureController: SCStreamOutput {

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }

        // Only complete frames carry new pixels; idle frames repeat the last one.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusRaw) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer,
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
        else { return }

        frames.put(surface)
    }
}

// MARK: - SCStreamDelegate

extension ScreenCaptureController: SCStreamDelegate {

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("[Capture] stream stopped with error: \(error)")
        Task { @MainActor [weak self] in
            self?.stream = nil
        }
    }
}
