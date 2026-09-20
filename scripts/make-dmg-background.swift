#!/usr/bin/env swift
//
//  make-dmg-background.swift
//  Morphlet
//
//  Draws the disk image's background art at 1x and 2x into packaging/.
//  scripts/dmg.sh combines them into a single multi-resolution TIFF, which is
//  how a DMG background stays crisp on a Retina display.
//
//  The art carries the post-drag instructions on purpose. Dragging an app to
//  Applications produces no visible feedback, and an unsigned app then refuses
//  to open — so someone who only drags and double-clicks hits a dead end. The
//  window background is the one surface every user actually looks at;
//  INSTALL.txt is not.
//
//  Run only when the artwork or the window geometry changes:
//      swift scripts/make-dmg-background.swift
//
//  Geometry here must stay in sync with the constants at the top of dmg.sh.
//

import AppKit
import CoreGraphics
import Foundation

let W: CGFloat = 660
let H: CGFloat = 480

// Pulled from the app icon so the window feels like part of the product.
let bg = CGColor(srgbRed: 0.055, green: 0.067, blue: 0.098, alpha: 1)
let headline = CGColor(srgbRed: 0.92, green: 0.94, blue: 0.97, alpha: 1)
let body = CGColor(srgbRed: 0.72, green: 0.77, blue: 0.85, alpha: 1)
let muted = CGColor(srgbRed: 0.45, green: 0.50, blue: 0.60, alpha: 1)
let accent = CGColor(srgbRed: 0.36, green: 0.60, blue: 0.90, alpha: 1)
let warn = CGColor(srgbRed: 0.95, green: 0.72, blue: 0.36, alpha: 1)

/// Finder positions icons in y-down coordinates; Core Graphics draws y-up.
/// Everything below is written y-down and converted here, so the numbers match
/// the ones in dmg.sh directly.
func cgY(_ yDown: CGFloat) -> CGFloat { H - yDown }

func draw(scale: CGFloat, to url: URL) {
    let pw = Int(W * scale), ph = Int(H * scale)
    guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("could not create a bitmap context")
    }
    ctx.scaleBy(x: scale, y: scale)

    ctx.setFillColor(bg)
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

    func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: CGColor,
              yDown: CGFloat, x: CGFloat? = nil) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor(cgColor: color)!,
        ]
        let line = NSAttributedString(string: s, attributes: attrs)
        let drawX = x ?? (W - line.size().width) / 2
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        line.draw(at: CGPoint(x: drawX, y: cgY(yDown)))
        NSGraphicsContext.restoreGraphicsState()
    }

    // Arrow on the icon row, pointing from the app at the Applications alias.
    let rowY = cgY(178)
    ctx.setStrokeColor(accent)
    ctx.setLineWidth(2)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: 272, y: rowY))
    ctx.addLine(to: CGPoint(x: 386, y: rowY))
    ctx.strokePath()
    ctx.move(to: CGPoint(x: 374, y: rowY + 9))
    ctx.addLine(to: CGPoint(x: 388, y: rowY))
    ctx.addLine(to: CGPoint(x: 374, y: rowY - 9))
    ctx.strokePath()

    text("Install Morphlet", size: 20, weight: .medium, color: headline, yDown: 46)
    text("Four steps. The third one is the awkward one.",
         size: 12, weight: .regular, color: muted, yDown: 68)

    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10))
    ctx.setLineWidth(1)
    ctx.move(to: CGPoint(x: 62, y: cgY(258)))
    ctx.addLine(to: CGPoint(x: 598, y: cgY(258)))
    ctx.strokePath()

    let left: CGFloat = 62
    text("1.   Drag Morphlet onto the Applications folder above",
         size: 13, weight: .regular, color: body, yDown: 292, x: left)
    text("2.   Open Morphlet — from Applications, or press \u{2318}Space and search for it.",
         size: 13, weight: .regular, color: body, yDown: 320, x: left)
    text("      macOS will refuse the first time. Click Done — do NOT move it to Trash.",
         size: 13, weight: .medium, color: warn, yDown: 342, x: left)
    text("3.   Open System Settings ▸ Privacy & Security, scroll to the bottom,",
         size: 13, weight: .regular, color: body, yDown: 372, x: left)
    text("      and click \"Open Anyway\" next to Morphlet. Confirm.",
         size: 13, weight: .regular, color: body, yDown: 394, x: left)
    text("4.   Allow Screen Recording when asked, then open Morphlet again.",
         size: 13, weight: .regular, color: body, yDown: 424, x: left)

    text("Morphlet has no Dock icon — look for it in the menu bar.",
         size: 12, weight: .regular, color: muted, yDown: 452, x: left)

    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        fatalError("could not encode \(url.lastPathComponent)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    print("  wrote \(url.path) (\(pw)×\(ph))")
}

let packaging = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("packaging")
try? FileManager.default.createDirectory(at: packaging, withIntermediateDirectories: true)

draw(scale: 1, to: packaging.appendingPathComponent("dmg-background.png"))
draw(scale: 2, to: packaging.appendingPathComponent("dmg-background@2x.png"))
