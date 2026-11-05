import AppKit

/// Menu-bar glyph: the app icon's display, left half lit (a snapped window), a clock in
/// the right half. Drawn per backing scale so 1x and 2x both land on whole pixels.
enum StatusIcon {
    static func image() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let t = ctx.userSpaceToDeviceSpaceTransform
            draw(in: ctx, layout: hypot(t.a, t.b) >= 1.5 ? .retina : .standard)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "RubberMAC"
        return image
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

    private static func draw(in ctx: CGContext, layout l: Layout) {
        ctx.setFillColor(NSColor.black.cgColor)

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
