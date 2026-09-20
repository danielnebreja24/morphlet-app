//
//  LidAngleSensor.swift
//  Morphlet
//
//  Reads the built-in lid-angle sensor on Apple silicon MacBooks.
//
//  The sensor is a HID device (Apple vendor 0x05AC, usage page 0x20 "Sensor",
//  usage 0x8A "Orientation"). It does NOT stream input events to apps; the
//  angle is obtained by actively requesting **Feature Report ID 1**, which
//  returns 3 bytes: [reportID, angleLow, angleHigh], where the angle is a
//  16-bit little-endian value in degrees (0 = closed, ~90 = right angle,
//  ~130+ = fully open). This is the technique used by the open-source
//  lid-angle tools (LidAngleSensor / pybooklid / mac-angle et al.).
//
//  All of this is the PUBLIC IOHIDManager API — no private symbols, no
//  bridging header. If the device isn't present or a read fails, we degrade
//  to a coarse open/closed signal from IORegistry's AppleClamshellState.
//

import Foundation
import IOKit
import IOKit.hid

@MainActor
final class LidAngleSensor: ObservableObject {

    /// Lid angle in degrees. nil until the first successful reading.
    @Published private(set) var angle: Double?

    /// True when the precise HID feature-report sensor is in use. False before
    /// start(), or when we've dropped to the coarse clamshell fallback (angle
    /// is still published in that mode, just open/closed resolution only).
    @Published private(set) var isAvailable: Bool = false

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?

    private var pollTimer: DispatchSourceTimer?
    private let pollQueue = DispatchQueue(label: "com.morphlet.lidangle.poll")
    private var consecutiveFailures = 0

    func start() {
        guard pollTimer == nil else { return }
        if openSensor() {
            isAvailable = true
            startTimer(hz: 30) { [weak self] in self?.pollFeatureReport() }
            print("[LidAngle] using HID feature-report lid angle sensor")
        } else {
            isAvailable = false
            print("[LidAngle] precise sensor unavailable; falling back to AppleClamshellState")
            startTimer(hz: 5) { [weak self] in self?.pollClamshellFallback() }
        }
    }

    func stop() {
        pollTimer?.cancel()
        pollTimer = nil
        if let manager {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        device = nil
        manager = nil
        consecutiveFailures = 0
    }

    // MARK: - Precise sensor (HID feature report)

    private func openSensor() -> Bool {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [
            kIOHIDVendorIDKey: 0x05AC,            // Apple
            kIOHIDDeviceUsagePageKey: 0x20,       // Sensor
            kIOHIDDeviceUsageKey: 0x8A            // Orientation (lid angle)
        ]
        IOHIDManagerSetDeviceMatching(mgr, match as CFDictionary)
        guard IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            return false
        }
        guard let devices = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>,
              let dev = devices.first else {
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
            return false
        }
        // Confirm one plausible reading before committing to this path.
        guard let a = Self.readAngle(dev), a >= 0, a <= 360 else {
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
            return false
        }
        manager = mgr
        device = dev
        return true
    }

    /// Requests Feature Report ID 1 and parses the little-endian angle.
    private static func readAngle(_ device: IOHIDDevice) -> Double? {
        var report = [UInt8](repeating: 0, count: 8)
        var length: CFIndex = report.count
        let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &report, &length)
        guard result == kIOReturnSuccess, length >= 3 else { return nil }
        let raw = Int(report[1]) | (Int(report[2]) << 8)
        return Double(raw)
    }

    private func pollFeatureReport() {
        guard let device, let a = Self.readAngle(device), a >= 0, a <= 360 else {
            handlePreciseFailure()
            return
        }
        consecutiveFailures = 0
        DispatchQueue.main.async { [weak self] in
            self?.angle = a
            #if DEBUG
            print("[LidAngle] \(a)")
            #endif
        }
    }

    /// After a run of failed reads (sensor asleep / device removed) drop to the
    /// coarse fallback rather than publishing stale data forever.
    private func handlePreciseFailure() {
        consecutiveFailures += 1
        guard consecutiveFailures > 15 else { return }
        consecutiveFailures = 0
        print("[LidAngle] precise sensor stopped responding; switching to fallback")
        pollTimer?.cancel()
        pollTimer = nil
        if let manager {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        device = nil
        manager = nil
        DispatchQueue.main.async { [weak self] in self?.isAvailable = false }
        startTimer(hz: 5) { [weak self] in self?.pollClamshellFallback() }
    }

    // MARK: - Timer plumbing

    private func startTimer(hz: Double, handler: @escaping () -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / hz)
        timer.setEventHandler(handler: handler)
        timer.resume()
        pollTimer = timer
    }

    // MARK: - Fallback: AppleClamshellState from IORegistry

    private func pollClamshellFallback() {
        guard let closed = Displays.clamshellClosed() else { return }
        let value = closed ? 5.0 : 100.0
        DispatchQueue.main.async { [weak self] in
            self?.angle = value
            #if DEBUG
            print("[LidAngle] (fallback) \(value)")
            #endif
        }
    }

}
