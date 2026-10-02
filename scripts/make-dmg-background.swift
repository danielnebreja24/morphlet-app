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

/// The window the layout is designed for. Every coordinate below lives here.
let W: CGFloat = 660
let H: CGFloat = 480

/// The canvas actually painted. Finder anchors the background top-left and
/// does not always honour the saved window size - it can open the window
/// wider or taller than 660x480. Anything past the edge of the image then
/// shows as bright white, which looks broken. Painting the same dark colour
/// well past the design area means any extra space simply continues the
/// background.
let CANVAS_W: CGFloat = 1200
let CANVAS_H: CGFloat = 900

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
// Core Graphics is y-up from the canvas bottom, so measure from the canvas
// height: that keeps the design pinned to the top-left, where Finder anchors it.
func cgY(_ yDown: CGFloat) -> CGFloat { CANVAS_H - yDown }

func draw(scale: CGFloat, to url: URL) {
    let pw = Int(CANVAS_W * scale), ph = Int(CANVAS_H * scale)
    guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("could not create a bitmap context")
    }
    ctx.scaleBy(x: scale, y: scale)

    ctx.setFillColor(bg)
    ctx.fill(CGRect(x: 0, y: 0, width: CANVAS_W, height: CANVAS_H))

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
    let rowY = cgY(196)
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

    text("Install Morphlet", size: 20, weight: .medium, color: headline, yDown: 52)
    text("Drag it across, then open it. That is the whole thing.",
         size: 13, weight: .regular, color: muted, yDown: 76)

    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10))
    ctx.setLineWidth(1)
    ctx.move(to: CGPoint(x: 62, y: cgY(300)))
    ctx.addLine(to: CGPoint(x: 598, y: cgY(300)))
    ctx.strokePath()

    let left: CGFloat = 62
    text("Morphlet lives in the menu bar — it has no Dock icon.",
         size: 13, weight: .regular, color: body, yDown: 336, x: left)
    text("It will ask to record your screen. That is how the fold works: it",
         size: 13, weight: .regular, color: body, yDown: 362, x: left)
    text("mirrors your desktop while the lid closes. Nothing is saved or sent.",
         size: 13, weight: .regular, color: body, yDown: 384, x: left)
    text("Signed and notarized by Apple.",
         size: 12, weight: .regular, color: muted, yDown: 424, x: left)

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
