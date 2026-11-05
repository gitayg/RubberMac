// Draws the RubberMAC app icon and builds icon/AppIcon.icns.
//
//   swift icon/make-icon.swift
//
// Every size is drawn from vector paths at its own pixel resolution. The 16 and 32 px
// renders use hand-placed, pixel-aligned layouts so they stay crisp; 64 px and up are
// scaled from the 1024 design grid with edges snapped to whole pixels.
// Outputs (next to this script): AppIcon.icns, preview.png (1024), preview-small.png.

import AppKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - Colours

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [r, g, b, a])!
}

enum Palette {
    static let bgTop = rgb(0.30, 0.67, 1.00)
    static let bgMid = rgb(0.22, 0.44, 0.97)
    static let bgBottom = rgb(0.36, 0.25, 0.86)
    static let bodyTop = rgb(1, 1, 1)
    static let bodyBottom = rgb(0.85, 0.88, 0.96)
    static let screenTop = rgb(0.09, 0.15, 0.38)
    static let screenBottom = rgb(0.13, 0.08, 0.34)
    static let leftTop = rgb(1, 1, 1)
    static let leftBottom = rgb(0.88, 0.93, 1.00)
    static let titleBar = rgb(0.80, 0.87, 1.00)
    static let rightTint = (r: CGFloat(0.55), g: CGFloat(0.70), b: CGFloat(1.00))
    static let lights = [rgb(1.00, 0.37, 0.34), rgb(1.00, 0.74, 0.18), rgb(0.16, 0.78, 0.29)]
    static let glow = rgb(0.45, 0.76, 1.00, 0.9)
    static let clock = rgb(1, 1, 1)
}

// MARK: - Paths

/// Rounded rectangle with continuous ("squircle") corners, using the corner curve
/// of UIKit/AppKit continuous rounded rects (corner run = 1.52866 x radius).
func continuousRect(_ r: CGRect, radius: CGFloat) -> CGPath {
    let k: CGFloat = 1.52866483
    let rad = min(radius, min(r.width, r.height) / 2 / k)
    // (corner, unit vector back along the incoming edge, unit vector along the outgoing edge)
    let corners: [(CGPoint, CGVector, CGVector)] = [
        (CGPoint(x: r.maxX, y: r.minY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: 1)),
        (CGPoint(x: r.maxX, y: r.maxY), CGVector(dx: 0, dy: -1), CGVector(dx: -1, dy: 0)),
        (CGPoint(x: r.minX, y: r.maxY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: -1)),
        (CGPoint(x: r.minX, y: r.minY), CGVector(dx: 0, dy: 1), CGVector(dx: 1, dy: 0)),
    ]
    func p(_ c: (CGPoint, CGVector, CGVector), _ m: CGFloat, _ n: CGFloat) -> CGPoint {
        CGPoint(x: c.0.x + (c.1.dx * m + c.2.dx * n) * rad,
                y: c.0.y + (c.1.dy * m + c.2.dy * n) * rad)
    }
    let path = CGMutablePath()
    path.move(to: p(corners[3], 0, k))
    for c in corners {
        path.addLine(to: p(c, k, 0))
        path.addCurve(to: p(c, 0.66993427, 0.06549600),
                      control1: p(c, 1.08849323, 0), control2: p(c, 0.86840689, 0))
        path.addLine(to: p(c, 0.63149399, 0.07491100))
        path.addCurve(to: p(c, 0.07491176, 0.63149399),
                      control1: p(c, 0.37282392, 0.16905899), control2: p(c, 0.16906013, 0.37282401))
        path.addCurve(to: p(c, 0, k),
                      control1: p(c, 0, 0.86840701), control2: p(c, 0, 1.08849299))
    }
    path.closeSubpath()
    return path
}

func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    let rad = max(0, min(radius, r.width / 2, r.height / 2))
    return CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil)
}

// MARK: - Layout (pixel coordinates, y up)

struct Clock {
    var center: CGPoint
    var radius: CGFloat          // ring centre-line radius
    var ring: CGFloat            // ring stroke width
    var hand: CGFloat            // hand stroke width
    var minute: (angle: CGFloat, length: CGFloat)
    var hour: (angle: CGFloat, length: CGFloat)
    var roundCaps: Bool
}

struct Layout {
    var squircle: CGRect
    var squircleRadius: CGFloat
    var shadow: (offset: CGFloat, blur: CGFloat, alpha: CGFloat)
    var body: CGRect
    var bodyRadius: CGFloat
    var neck: CGRect
    var base: CGRect
    var screen: CGRect
    var screenRadius: CGFloat
    var left: CGRect
    var right: CGRect
    var windowRadius: CGFloat
    var rightAlpha: CGFloat
    var clock: Clock?
    var titleBar: CGFloat = 0      // height of the left window's title band; 0 = none
    var lights = false             // traffic-light dots in that band
    var glow: CGFloat = 0          // blur of the "snapped" glow around the left window; 0 = none
    var glyphShadow: CGFloat = 0   // blur of the glyph's own drop shadow; 0 = none
    var sheen = false
}

/// Squircle inset follows the system icons, measured from Calculator.app:
/// floor(px * 100 / 1024) -> 16:1, 32:3, 64:6, 128:12, 256:25, 512:50, 1024:100.
func squircleRect(_ px: Int) -> CGRect {
    let inset = (CGFloat(px) * 100 / 1024).rounded(.down)
    return CGRect(x: inset, y: inset, width: CGFloat(px) - 2 * inset, height: CGFloat(px) - 2 * inset)
}

func baseShadow(_ px: Int) -> (offset: CGFloat, blur: CGFloat, alpha: CGFloat) {
    let k = CGFloat(px) / 1024
    return (8 * k, 28 * k, 0.22)
}

func rect(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> CGRect {
    CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
}

/// 64 px and up: the 1024 design grid scaled to `px`, every edge snapped to a whole pixel.
func scaledLayout(_ px: Int) -> Layout {
    let k = CGFloat(px) / 1024
    func e(_ v: CGFloat) -> CGFloat { (v * k).rounded() }
    func centered(_ width: CGFloat, on center: CGFloat) -> (CGFloat, CGFloat) {
        var w = (width * k).rounded()
        if (center - w / 2).rounded() != center - w / 2 { w += 1 }
        return (center - w / 2, center + w / 2)
    }

    let body = rect(e(192), e(380), e(832), e(790))
    let cx = body.midX
    let bezel = max(2, e(28))
    let screen = body.insetBy(dx: bezel, dy: bezel)
    let gap = max(1, e(20))
    let area = screen.insetBy(dx: gap, dy: gap)
    let halfGap = max(1, e(10))
    let leftMaxX = (cx - halfGap).rounded(.down)
    let left = rect(area.minX, area.minY, leftMaxX, area.maxY)
    let right = rect(screen.minX + screen.maxX - left.maxX, area.minY,
                     screen.minX + screen.maxX - left.minX, area.maxY)
    let (nx0, nx1) = centered(72, on: cx)
    let (bx0, bx1) = centered(272, on: cx)
    let baseY0 = e(276)
    let baseY1 = max(baseY0 + 1, e(306))
    let neck = rect(nx0, baseY1, nx1, body.minY)
    let base = rect(bx0, baseY0, bx1, baseY1)

    // Clock: integer ring radius and an even/odd-aware centre put the ring's cardinal
    // edges and both hands on whole pixels.
    let ring = max(2, (18 * k).rounded())
    let snapCentre: (CGFloat) -> CGFloat = { v in
        ring.truncatingRemainder(dividingBy: 2) == 0 ? v.rounded(.down) : v.rounded(.down) + 0.5
    }
    let radius = (min(right.width, right.height) * 0.36).rounded()
    let clock = Clock(center: CGPoint(x: snapCentre(right.midX), y: snapCentre(right.midY)),
                      radius: radius, ring: ring, hand: ring,
                      minute: (angle: 90, length: (radius * 0.68).rounded()),
                      hour: (angle: 0, length: (radius * 0.46).rounded()),
                      roundCaps: px >= 128)

    return Layout(
        squircle: squircleRect(px), squircleRadius: 185 * k, shadow: baseShadow(px),
        body: body, bodyRadius: 46 * k, neck: neck, base: base,
        screen: screen, screenRadius: max(1, 20 * k),
        left: left, right: right, windowRadius: max(1, 14 * k), rightAlpha: 0.16,
        clock: clock,
        titleBar: px >= 128 ? e(44) : 0,
        lights: px >= 256,
        glow: px >= 128 ? 40 * k : 0,
        glyphShadow: px >= 64 ? 22 * k : 0,
        sheen: px >= 64)
}

/// 32 px: hand-placed on the pixel grid.
func layout32() -> Layout {
    let body = rect(6, 12, 26, 25)
    let screen = rect(7, 13, 25, 24)
    let left = rect(8, 14, 15, 23)
    let right = rect(17, 14, 24, 23)
    let clock = Clock(center: CGPoint(x: 20.5, y: 18.5), radius: 3, ring: 1, hand: 1,
                      minute: (angle: 90, length: 1.5), hour: (angle: 0, length: 1.5),
                      roundCaps: false)
    return Layout(
        squircle: squircleRect(32), squircleRadius: 185 * 32 / 1024, shadow: baseShadow(32),
        body: body, bodyRadius: 1.5, neck: rect(15, 10, 17, 12), base: rect(12, 9, 20, 10),
        screen: screen, screenRadius: 0.5,
        left: left, right: right, windowRadius: 0.5, rightAlpha: 0,
        clock: clock)
}

/// 16 px: hand-placed; no clock (it cannot read at this size), the dim right half stays.
func layout16() -> Layout {
    Layout(
        squircle: squircleRect(16), squircleRadius: 185 * 14 / 824, shadow: baseShadow(16),
        body: rect(3, 6, 13, 13), bodyRadius: 1, neck: rect(7, 5, 9, 6), base: rect(6, 4, 10, 5),
        screen: rect(4, 7, 12, 12), screenRadius: 0,
        left: rect(5, 8, 8, 11), right: rect(8, 8, 11, 11), windowRadius: 0, rightAlpha: 0.35,
        clock: nil)
}

func layout(_ px: Int) -> Layout {
    switch px {
    case ..<24: return layout16()
    case ..<48: return layout32()
    default: return scaledLayout(px)
    }
}

// MARK: - Drawing

func fillGradient(_ ctx: CGContext, _ path: CGPath, _ colors: [CGColor], _ locations: [CGFloat]? = nil) {
    let box = path.boundingBox
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: colors as CFArray, locations: locations)!
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(gradient, start: CGPoint(x: box.midX, y: box.maxY),
                           end: CGPoint(x: box.midX, y: box.minY), options: [])
    ctx.restoreGState()
}

func drawClock(_ ctx: CGContext, _ c: Clock) {
    ctx.setStrokeColor(Palette.clock)
    ctx.setLineWidth(c.ring)
    ctx.strokeEllipse(in: CGRect(x: c.center.x - c.radius, y: c.center.y - c.radius,
                                 width: 2 * c.radius, height: 2 * c.radius))
    ctx.setLineWidth(c.hand)
    ctx.setLineCap(c.roundCaps ? .round : .butt)
    for hand in [c.minute, c.hour] {
        let a = hand.angle * .pi / 180
        // Butt caps start half a hand-width behind the centre so the two hands join cleanly.
        let back = c.roundCaps ? 0 : c.hand / 2
        ctx.move(to: CGPoint(x: c.center.x - cos(a) * back, y: c.center.y - sin(a) * back))
        ctx.addLine(to: CGPoint(x: c.center.x + cos(a) * hand.length, y: c.center.y + sin(a) * hand.length))
        ctx.strokePath()
    }
}

func drawGlyph(_ ctx: CGContext, _ L: Layout) {
    let stand = CGMutablePath()
    stand.addPath(rounded(L.body, L.bodyRadius))
    stand.addRect(L.neck)
    stand.addPath(rounded(L.base, L.base.height / 2))
    fillGradient(ctx, stand, [Palette.bodyTop, Palette.bodyBottom])

    fillGradient(ctx, rounded(L.screen, L.screenRadius), [Palette.screenTop, Palette.screenBottom])

    // The snapped (highlighted) left half.
    let leftPath = rounded(L.left, L.windowRadius)
    if L.glow > 0 {
        ctx.saveGState()
        ctx.addPath(rounded(L.screen, L.screenRadius))
        ctx.clip()
        ctx.setShadow(offset: .zero, blur: L.glow, color: Palette.glow)
        ctx.addPath(leftPath)
        ctx.setFillColor(Palette.leftTop)
        ctx.fillPath()
        ctx.restoreGState()
    }
    fillGradient(ctx, leftPath, [Palette.leftTop, Palette.leftBottom])
    if L.titleBar > 0 {
        ctx.saveGState()
        ctx.addPath(leftPath)
        ctx.clip()
        ctx.setFillColor(Palette.titleBar)
        ctx.fill(CGRect(x: L.left.minX, y: L.left.maxY - L.titleBar, width: L.left.width, height: L.titleBar))
        ctx.restoreGState()
        if L.lights {
            let r = L.titleBar * 0.2
            let y = L.left.maxY - L.titleBar / 2
            for (i, colour) in Palette.lights.enumerated() {
                let x = L.left.minX + L.titleBar * (0.6 + CGFloat(i) * 0.55)
                ctx.setFillColor(colour)
                ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
            }
        }
    }

    // The other half, dimmed, showing the clock.
    let t = Palette.rightTint
    ctx.setFillColor(rgb(t.r, t.g, t.b, L.rightAlpha))
    ctx.addPath(rounded(L.right, L.windowRadius))
    ctx.fillPath()
    if let clock = L.clock { drawClock(ctx, clock) }
}

func render(_ px: Int) -> CGImage {
    let L = layout(px)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let squircle = continuousRect(L.squircle, radius: L.squircleRadius)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -L.shadow.offset), blur: L.shadow.blur,
                  color: rgb(0, 0, 0, L.shadow.alpha))
    ctx.addPath(squircle)
    ctx.setFillColor(Palette.bgMid)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    fillGradient(ctx, squircle, [Palette.bgTop, Palette.bgMid, Palette.bgBottom], [0, 0.5, 1])
    if L.sheen {
        let top = CGRect(x: L.squircle.minX, y: L.squircle.midY, width: L.squircle.width, height: L.squircle.height / 2)
        fillGradient(ctx, CGPath(rect: top, transform: nil), [rgb(1, 1, 1, 0.10), rgb(1, 1, 1, 0)])
    }
    if L.glyphShadow > 0 {
        ctx.setShadow(offset: CGSize(width: 0, height: -L.glyphShadow / 3), blur: L.glyphShadow,
                      color: rgb(0.05, 0.03, 0.25, 0.35))
    }
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    drawGlyph(ctx, L)
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    return ctx.makeImage()!
}

// MARK: - Output

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(url.path)") }
}

func previewStrip(_ sizes: [Int], cell: Int, pad: Int) -> CGImage {
    let w = sizes.count * cell + (sizes.count + 1) * pad
    let h = cell + 2 * pad
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(rgb(0.93, 0.93, 0.94))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.interpolationQuality = .none
    for (i, px) in sizes.enumerated() {
        ctx.draw(render(px), in: CGRect(x: pad + i * (cell + pad), y: pad, width: cell, height: cell))
    }
    return ctx.makeImage()!
}

let iconDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let work = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory())
    .appendingPathComponent("ScreenTools-icon-\(ProcessInfo.processInfo.processIdentifier)")
let iconset = work.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let entries: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in entries {
    writePNG(render(px), to: iconset.appendingPathComponent("\(name).png"))
}

let icns = iconDir.appendingPathComponent("AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
let pipe = Pipe()
iconutil.standardOutput = pipe
iconutil.standardError = pipe
try iconutil.run()
iconutil.waitUntilExit()
let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
print("$ iconutil \(iconutil.arguments!.joined(separator: " "))")
print(output.isEmpty ? "(no output)" : output, terminator: output.hasSuffix("\n") || output.isEmpty ? "\n" : "\n")
print("iconutil exit status: \(iconutil.terminationStatus)")
guard iconutil.terminationStatus == 0 else { exit(1) }
try FileManager.default.removeItem(at: work)

writePNG(render(1024), to: iconDir.appendingPathComponent("preview.png"))
writePNG(previewStrip([16, 32, 64], cell: 256, pad: 32), to: iconDir.appendingPathComponent("preview-small.png"))
print("wrote \(icns.path)")
