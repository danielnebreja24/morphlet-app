#!/usr/bin/env swift
//
//  probe-lid-sensor.swift
//  Morphlet
//
//  Standalone diagnostic: finds the lid-angle sensor and prints live readings.
//  Run it when someone reports "Lid angle unavailable", or to check a Mac you
//  haven't tried before:
//
//      swift scripts/probe-lid-sensor.swift
//
//  It needs no permissions and no app bundle. Same matching criteria and same
//  feature-report read as LidAngleSensor.swift, deliberately duplicated so this
//  stays runnable on its own.
//

import Foundation
import IOKit
import IOKit.hid

let readings = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 20 : 20

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
let match: [String: Any] = [
    kIOHIDVendorIDKey: 0x05AC,        // Apple
    kIOHIDDeviceUsagePageKey: 0x20,   // Sensor
    kIOHIDDeviceUsageKey: 0x8A,       // Orientation
]
IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)

guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
    print("Could not open an IOHIDManager.")
    exit(1)
}

guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, let device = devices.first else {
    print("No lid-angle sensor on this Mac (no Apple device on usage page 0x20 / usage 0x8A).")
    print("Morphlet would run in degraded mode here, using AppleClamshellState.")
    exit(2)
}

print("Device:")
for key in [kIOHIDManufacturerKey, kIOHIDProductKey, kIOHIDTransportKey,
            kIOHIDVendorIDKey, kIOHIDProductIDKey,
            kIOHIDPrimaryUsagePageKey, kIOHIDPrimaryUsageKey, kIOHIDReportIntervalKey] {
    let value = IOHIDDeviceGetProperty(device, key as CFString)
    let shown = value.map { "\($0)" } ?? "—"
    print("  \(key.padding(toLength: 20, withPad: " ", startingAt: 0)) \(shown)")
}

/// Requests feature report 1: [reportID, angleLow, angleHigh], little-endian.
func readAngle() -> (angle: Int, bytes: String)? {
    var report = [UInt8](repeating: 0, count: 8)
    var length: CFIndex = report.count
    guard IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &report, &length) == kIOReturnSuccess,
          length >= 3 else { return nil }
    let hex = report.prefix(Int(length)).map { String(format: "%02X", $0) }.joined(separator: " ")
    return (Int(report[1]) | (Int(report[2]) << 8), hex)
}

print("\n\(readings) readings at 10 Hz — move the lid to watch it track:")
var failures = 0
for _ in 0..<readings {
    if let (angle, hex) = readAngle() {
        let bar = String(repeating: "█", count: min(angle / 4, 45))
        print("  \(String(format: "%3d", angle))°  \(hex.padding(toLength: 12, withPad: " ", startingAt: 0)) \(bar)")
    } else {
        failures += 1
        print("  read failed")
    }
    Thread.sleep(forTimeInterval: 0.1)
}

print("\n\(readings - failures)/\(readings) reads succeeded.")
if failures > 0 {
    print("Morphlet drops to the clamshell fallback after 15 consecutive failures.")
}
