//
//  Displays.swift
//  Morphlet
//
//  Finds the MacBook's built-in panel among connected displays and detects
//  clamshell mode — lid closed while the Mac runs on an external display.
//
//  The fold only makes sense on the built-in panel, so the overlay and the
//  screen capture both target it explicitly. `NSScreen.main` is not safe
//  here: with an external monitor attached it is often the external one.
//

import AppKit
import CoreGraphics
import IOKit

enum Displays {

    /// Every display currently drawing, including mirrored ones.
    static var activeDisplayIDs: [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    /// The built-in panel, or nil when it's offline (e.g. lid closed on an
    /// external display).
    static var builtInDisplayID: CGDirectDisplayID? {
        activeDisplayIDs.first { CGDisplayIsBuiltin($0) != 0 }
    }

    static var hasExternalDisplay: Bool {
        activeDisplayIDs.contains { CGDisplayIsBuiltin($0) == 0 }
    }

    /// The NSScreen for the built-in panel, if it's active.
    static var builtInScreen: NSScreen? {
        guard let id = builtInDisplayID else { return nil }
        return NSScreen.screens.first { displayID(of: $0) == id }
    }

    /// Corner radius for the folding screen, in points. macOS doesn't expose
    /// the panel's real value, so this is a proportion of its height tuned by eye.
    static var deviceCornerRadius: CGFloat {
        ((builtInScreen ?? NSScreen.main)?.frame.height ?? 982) * 0.013
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// The lid's open/closed flag from IORegistry (`AppleClamshellState`),
    /// or nil if it can't be read. Thread-safe — IOKit only.
    static func clamshellClosed() -> Bool? {
        for name in ["IOPMrootDomain", "AppleDeviceManagementHIDEventService"] {
            guard let matching = IOServiceMatching(name) else { continue }
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }

            var service = IOIteratorNext(iterator)
            while service != 0 {
                defer {
                    IOObjectRelease(service)
                    service = IOIteratorNext(iterator)
                }
                if let property = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0) {
                    let value = property.takeRetainedValue()
                    if let boolValue = value as? Bool { return boolValue }
                    if let numberValue = value as? NSNumber { return numberValue.boolValue }
                }
            }
        }
        return nil
    }
}

/// Publishes whether the Mac is in clamshell mode. The fold can't be seen
/// then, so the effect is suspended and its switch disabled.
@MainActor
final class DisplayEnvironment: ObservableObject {

    /// True when an external display is active and the built-in panel is
    /// closed or offline.
    @Published private(set) var isClamshellDocked = false

    private var screenObserver: NSObjectProtocol?
    private var recheckTimer: Timer?

    init() {
        evaluate()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.evaluate()
        }
        // The clamshell flag can update slightly after the display change
        // notification, so re-check on a slow timer as a safety net.
        recheckTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.evaluate()
        }
    }

    private func evaluate() {
        let lidClosed = Displays.clamshellClosed() ?? false
        let docked = Displays.hasExternalDisplay && (lidClosed || Displays.builtInDisplayID == nil)
        if docked != isClamshellDocked {
            isClamshellDocked = docked
        }
    }
}
