import AppKit

// The menu-bar icon's sign that Secure Input hides the keys: an orange disc with a white "!", top right, clear of
// the eye colour's dot in the bottom-right corner.
enum SecureInputBadge {
    static let disc = CGRect(x: 11, y: 11, width: 7, height: 7)

    static func draw(in ctx: CGContext) {
        // Knock a 1-point gap out of the glyph around the disc so it reads on its own, as the eye dot does.
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.fillEllipse(in: disc.insetBy(dx: -1, dy: -1))
        ctx.restoreGState()
        ctx.setFillColor(NSColor.systemOrange.cgColor)
        ctx.fillEllipse(in: disc)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: disc.midX - 0.5, y: disc.minY + 3, width: 1, height: 2.5))
        ctx.fill(CGRect(x: disc.midX - 0.5, y: disc.minY + 1.5, width: 1, height: 1))
    }
}
