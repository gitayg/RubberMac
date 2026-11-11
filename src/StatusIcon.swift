import AppKit

/// Menu-bar glyph: the app icon's display, left half lit (a snapped window), a clock in
/// the right half. Drawn per backing scale so 1x and 2x both land on whole pixels.
/// While the Eye Color Camera is on, a dot in the eye colour sits in the bottom-right corner.
enum StatusIcon {
    static func image(eyeColor: NSColor? = nil) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let t = ctx.userSpaceToDeviceSpaceTransform
            // A coloured dot can't be a template image, so then the glyph takes the menu bar's text
            // colour itself (resolved here, at draw time, for a light or dark menu bar).
            draw(in: ctx, layout: hypot(t.a, t.b) >= 1.5 ? .retina : .standard,
                 glyph: eyeColor == nil ? .black : .labelColor)
            if let eyeColor { drawDot(in: ctx, color: eyeColor) }
            return true
        }
        image.isTemplate = eyeColor == nil
        image.accessibilityDescription = eyeColor == nil ? "RubberMAC" : "RubberMAC, Eye Color Camera on"
        return image
    }

    private static func drawDot(in ctx: CGContext, color: NSColor) {
        let dot = CGRect(x: 11, y: 0, width: 7, height: 7)
        // Knock a 1-point gap out of the glyph around the dot so it reads on its own.
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.fillEllipse(in: dot.insetBy(dx: -1, dy: -1))
        ctx.restoreGState()
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: dot)
        // Real eye colours are muted, so a ring in the menu bar's text colour keeps a dark brown or a pale blue dot
        // visible on either bar.
        ctx.setStrokeColor(NSColor.labelColor.withAlphaComponent(0.6).cgColor)
        ctx.setLineWidth(1)
        ctx.strokeEllipse(in: dot.insetBy(dx: 0.5, dy: 0.5))
    }

    private struct Layout {
        var frame: CGRect, frameRadius: CGFloat, hole: CGRect, holeRadius: CGFloat
        var window: CGRect, dial: CGRect, minuteHand: CGRect, hourHand: CGRect
        var neck: CGRect, base: CGRect

        static let retina = Layout(
            frame: CGRect(x: 1, y: 4, width: 16, height: 12), frameRadius: 2.5,
            hole: CGRect(x: 2.5, y: 5.5, width: 13, height: 9), holeRadius: 1,
            window: CGRect(x: 3.5, y: 6.5, width: 5, height: 7),
            dial: CGRect(x: 9.5, y: 7.5, width: 5, height: 5),
            minuteHand: CGRect(x: 11.5, y: 9.5, width: 1, height: 2.5),
            hourHand: CGRect(x: 12.5, y: 9.5, width: 1, height: 1),
            neck: CGRect(x: 8, y: 2, width: 2, height: 2),
            base: CGRect(x: 5, y: 1, width: 8, height: 1))

        static let standard = Layout(
            frame: CGRect(x: 1, y: 4, width: 16, height: 12), frameRadius: 2,
            hole: CGRect(x: 2, y: 5, width: 14, height: 10), holeRadius: 0.5,
            window: CGRect(x: 3, y: 6, width: 5, height: 8),
            dial: CGRect(x: 10, y: 7, width: 5, height: 5),
            minuteHand: CGRect(x: 12, y: 9, width: 1, height: 2),
            hourHand: CGRect(x: 13, y: 9, width: 1, height: 1),
            neck: CGRect(x: 8, y: 2, width: 2, height: 2),
            base: CGRect(x: 5, y: 1, width: 8, height: 1))
    }

    private static func draw(in ctx: CGContext, layout l: Layout, glyph: NSColor) {
        ctx.setFillColor(glyph.cgColor)

        let display = CGMutablePath()
        display.addRoundedRect(in: l.frame, cornerWidth: l.frameRadius, cornerHeight: l.frameRadius)
        display.addRoundedRect(in: l.hole, cornerWidth: l.holeRadius, cornerHeight: l.holeRadius)
        ctx.addPath(display)
        ctx.fillPath(using: .evenOdd)

        ctx.addPath(CGPath(roundedRect: l.window, cornerWidth: 0.5, cornerHeight: 0.5, transform: nil))
        ctx.addRect(l.neck)
        ctx.addPath(CGPath(roundedRect: l.base, cornerWidth: 0.5, cornerHeight: 0.5, transform: nil))
        ctx.fillPath()

        // Solid dial with the hands knocked out (even-odd; the hand rects don't overlap),
        // so the clock still reads at this size.
        let dial = CGMutablePath()
        dial.addEllipse(in: l.dial)
        dial.addRect(l.minuteHand)
        dial.addRect(l.hourHand)
        ctx.addPath(dial)
        ctx.fillPath(using: .evenOdd)
    }
}
