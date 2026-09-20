//
//  FoldLayerView.swift
//  Morphlet
//
//  Renders the fold with Core Animation. The captured desktop arrives as an
//  IOSurface and goes straight into a layer — no per-frame image conversion —
//  and the tilt, blur, glass and shade are layer properties, so the whole
//  effect is composited on the GPU at the display's refresh rate.
//

import AppKit
import CoreImage
import IOSurface
import QuartzCore

final class FoldLayerView: NSView {

    /// Below this eased amount the fold is invisible and the live desktop shows
    /// through the window. The swap to and from the mirror happens here, while
    /// the mirror is still at an (essentially) identity transform.
    private static let visibleThreshold: CGFloat = 0.0005
    /// The mirror fades in over this extra range, masking the swap itself.
    private static let fadeRange: CGFloat = 0.0035

    private let planeLayer = CALayer()     // tilts on the bottom hinge
    private let contentLayer = CALayer()   // the captured desktop, blurred
    private let glassLayer = CAGradientLayer()
    private let tintLayer = CAGradientLayer()
    private let sheenLayer = CAGradientLayer()
    private let shadeLayer = CAGradientLayer()
    private let cornerMask = CAShapeLayer()

    private(set) var hasSurface = false
    private var appliedBlurRadius: CGFloat = 0
    private var appliedCornerRadius: CGFloat = -1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        layer?.backgroundColor = .clear

        planeLayer.anchorPoint = CGPoint(x: 0.5, y: 0)   // hinge along the bottom edge
        planeLayer.allowsGroupOpacity = true
        planeLayer.mask = cornerMask

        contentLayer.contentsGravity = .resize

        glassLayer.backgroundColor = CGColor(srgbRed: 0.51, green: 0.78, blue: 1.0, alpha: 0.10)
        glassLayer.colors = [CGColor(gray: 1, alpha: 0.18), CGColor(gray: 1, alpha: 0)]
        glassLayer.startPoint = CGPoint(x: 0, y: 1)
        glassLayer.endPoint = CGPoint(x: 0.72, y: 0.28)
        glassLayer.compositingFilter = "screenBlendMode"

        tintLayer.colors = [CGColor(srgbRed: 0.71, green: 0.59, blue: 1.0, alpha: 0.13), CGColor(gray: 0, alpha: 0)]
        tintLayer.startPoint = CGPoint(x: 1, y: 0.65)
        tintLayer.endPoint = CGPoint(x: 0.28, y: 0)
        tintLayer.compositingFilter = "screenBlendMode"

        sheenLayer.colors = [CGColor(gray: 1, alpha: 0), CGColor(gray: 1, alpha: 0.6), CGColor(gray: 1, alpha: 0)]
        sheenLayer.locations = [0.40, 0.50, 0.60]
        sheenLayer.startPoint = CGPoint(x: 0, y: 0.75)
        sheenLayer.endPoint = CGPoint(x: 1, y: 0.25)
        sheenLayer.compositingFilter = "overlayBlendMode"

        // Darker toward the top, the edge that folds away.
        shadeLayer.colors = [CGColor(gray: 0, alpha: 0.35), CGColor(gray: 0, alpha: 0.92)]
        shadeLayer.startPoint = CGPoint(x: 0.5, y: 0)
        shadeLayer.endPoint = CGPoint(x: 0.5, y: 1)

        for sublayer in [contentLayer, glassLayer, tintLayer, sheenLayer, shadeLayer] {
            planeLayer.addSublayer(sublayer)
        }
        layer?.addSublayer(planeLayer)
        planeLayer.isHidden = true
        needsLayout = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let b = bounds
        planeLayer.bounds = b
        planeLayer.position = CGPoint(x: b.midX, y: b.minY)
        for sublayer in [contentLayer, glassLayer, tintLayer, shadeLayer, cornerMask] {
            sublayer.frame = b
        }
        sheenLayer.bounds = CGRect(x: 0, y: 0, width: b.width * 1.4, height: b.height * 1.4)
        contentLayer.contentsScale = window?.backingScaleFactor ?? 2
        appliedCornerRadius = -1
        CATransaction.commit()
    }

    /// Shows a captured frame, or clears the mirror with nil.
    func setSurface(_ surface: IOSurface?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.contents = surface
        CATransaction.commit()
        hasSurface = surface != nil
    }

    /// - Parameters:
    ///   - eased: smoothed, eased fold amount (0 flat … 1 folded) driving the
    ///     tilt, blur, glass and shade.
    ///   - ramp: smoothed but un-eased amount, used for the corner rounding so
    ///     the corners round early in the close.
    func apply(eased: CGFloat, ramp: CGFloat, silk: CGFloat, frost: CGFloat, shade: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let fade = min(max((eased - Self.visibleThreshold) / Self.fadeRange, 0), 1)
        let visible = hasSurface && eased > Self.visibleThreshold
        planeLayer.isHidden = !visible
        // The black the plane reveals as it tilts. It's this view's own
        // background, not a sibling layer: Core Animation depth-sorts
        // 3D-transformed siblings, so a flat black layer at z = 0 would cover
        // the receding plane. Keep it off until the mirror is fully opaque, or
        // it would darken the screen through the fading plane.
        layer?.backgroundColor = (visible && fade >= 1) ? .black : .clear
        guard visible else { return }
        planeLayer.opacity = Float(fade)

        let b = bounds
        var transform = CATransform3DIdentity
        transform.m34 = -0.42 / max(b.width, b.height)
        // Negative angle: the top edge recedes away from the viewer.
        planeLayer.transform = CATransform3DRotate(transform, -eased * silk * 52 * .pi / 180, 1, 0, 0)

        let blurRadius = (eased * frost * 24 * contentLayer.contentsScale * 10).rounded() / 10
        if blurRadius != appliedBlurRadius {
            appliedBlurRadius = blurRadius
            if blurRadius < 0.3 {
                contentLayer.filters = nil
            } else if let blur = CIFilter(name: "CIGaussianBlur") {
                blur.setValue(blurRadius, forKey: kCIInputRadiusKey)
                contentLayer.filters = [blur]
            }
        }

        let glass = Float(eased * frost)
        glassLayer.opacity = glass
        tintLayer.opacity = glass
        sheenLayer.opacity = glass * 0.95
        sheenLayer.position = CGPoint(x: b.midX + (eased - 0.5) * b.width * 0.7, y: b.midY)
        shadeLayer.opacity = Float(eased * shade)

        let radius = (Displays.deviceCornerRadius * min(ramp / 0.08, 1) * 2).rounded() / 2
        if radius != appliedCornerRadius {
            appliedCornerRadius = radius
            // Top corners rounder than the bottom: the top edge is the one that lifts.
            cornerMask.path = roundedRectPath(in: b, top: radius * 1.4, bottom: radius * 0.8)
        }
    }

    // MARK: - Shapes

    /// A rectangle with separate radii for its top and bottom corners
    /// (y-up coordinates: "top" is maxY).
    private func roundedRectPath(in r: CGRect, top: CGFloat, bottom: CGFloat) -> CGPath {
        let t = min(top, r.width / 2, r.height / 2)
        let b = min(bottom, r.width / 2, r.height / 2)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: r.minX + b, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX - b, y: r.minY))
        path.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY + b), radius: b)
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY - t))
        path.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.maxX - t, y: r.maxY), radius: t)
        path.addLine(to: CGPoint(x: r.minX + t, y: r.maxY))
        path.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY - t), radius: t)
        path.addLine(to: CGPoint(x: r.minX, y: r.minY + b))
        path.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.minX + b, y: r.minY), radius: b)
        path.closeSubpath()
        return path
    }
}
