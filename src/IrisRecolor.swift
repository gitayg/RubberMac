import CoreGraphics
import CoreVideo
import Foundation

// camrelay's iris recolouring (eyes.py: iris_mask, recolor_region and the per-eye loop of EyeRecolor.__call__), ported
// number for number: Float where numpy works in float32, Double where it promotes to float64, OpenCV's own
// anti-aliased polygon fill and Gaussian blur, and the final truncation to bytes. Every eye is worked on inside its own
// small box, so a 1920x1080 frame costs about as much as a thumbnail.
// The polygon fill, anti-aliased line and Gaussian blur parts translate OpenCV 4.11 (Apache License 2.0): see
// THIRD_PARTY_NOTICES.md.
enum IrisRecolor {
    static func apply(_ eyes: [IrisEye], color: (r: Double, g: Double, b: Double), strength: Double, to frame: CVPixelBuffer) {
        guard CVPixelBufferGetPixelFormatType(frame) == kCVPixelFormatType_32BGRA,
              eyes.contains(where: { strength * Double($0.alpha) >= 0.01 }),
              CVPixelBufferLockBaseAddress(frame, []) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(frame, []) }
        guard let base = CVPixelBufferGetBaseAddress(frame) else { return }
        let pixels = Pixels(base: base.assumingMemoryBound(to: UInt8.self), width: CVPixelBufferGetWidth(frame),
                            height: CVPixelBufferGetHeight(frame), rowBytes: CVPixelBufferGetBytesPerRow(frame))
        for eye in eyes {
            let s = strength * Double(eye.alpha)
            if !(s >= 0.01) { continue }  // eye closed or tracking lost: leave the real eye visible
            let feather = max(1.0, Double(eye.radius) / 20)
            guard let mask = irisMask(eye, width: pixels.width, height: pixels.height) else { continue }
            recolor(pixels, mask: blur(mask, half: Int(feather), width: pixels.width, height: pixels.height),
                    color: color, strength: s, eye: eye)
        }
    }

    struct Pixels {
        let base: UnsafeMutablePointer<UInt8>
        let width: Int, height: Int, rowBytes: Int
    }

    // A float mask over a box of the frame; zero everywhere outside the box.
    struct Plane {
        let x0: Int, y0: Int, width: Int, height: Int
        var values: [Float]

        func at(_ x: Int, _ y: Int) -> Float {
            let i = x - x0, j = y - y0
            return i >= 0 && i < width && j >= 0 && j < height ? values[j * width + i] : 0
        }
    }

    // iris_mask(..., pupil_ratio=0.3), computed only over the box where it can be non-zero.
    static func irisMask(_ eye: IrisEye, width: Int, height: Int) -> Plane? {
        let cx = Double(eye.center.x), cy = Double(eye.center.y), r = max(1.0, Double(eye.radius))
        let limit = 1e7  // also rejects NaN and infinity, which would trap converting to Int
        guard width > 0, height > 0, !eye.contour.isEmpty, abs(cx) < limit, abs(cy) < limit, abs(Double(eye.radius)) < limit,
              eye.contour.allSatisfy({ abs(Double($0.x)) < limit && abs(Double($0.y)) < limit }) else { return nil }
        let xs = eye.contour.map { Double($0.x) }, ys = eye.contour.map { Double($0.y) }
        // OpenCV's anti-aliased edges reach at most 2 px past the polygon; the disc ends at r.
        let left = Int(max(floor(cx - r) - 1, floor(xs.min()!) - 3, 0))
        let right = Int(min(ceil(cx + r) + 1, ceil(xs.max()!) + 3, Double(width - 1)))
        let top = Int(max(floor(cy - r) - 1, floor(ys.min()!) - 3, 0))
        let bottom = Int(min(ceil(cy + r) + 1, ceil(ys.max()!) + 3, Double(height - 1)))
        guard left <= right, top <= bottom else { return nil }
        let w = right - left + 1, h = bottom - top + 1
        var opening = Coverage(x0: left, y0: top, width: w, height: h)
        fillPolyAA(eye.contour, frameWidth: width, frameHeight: height, into: &opening)

        let rim = Smoothstep32(0.82 * r, 1.0 * r)
        let pr = r * 0.3
        let pupil = Smoothstep32(0.85 * pr, 1.2 * pr)
        var values = [Float](repeating: 0, count: w * h)
        for j in 0..<h {
            let dy = Double(top + j) - cy
            for i in 0..<w {
                let dx = Double(left + i) - cx
                let dist = Float((dx * dx + dy * dy).squareRoot())
                let mask = (1 - rim(dist)) * pupil(dist)
                values[j * w + i] = mask * (Float(opening.bytes[j * w + i]) / 255)
            }
        }
        return Plane(x0: left, y0: top, width: w, height: h, values: values)
    }

    // cv2.GaussianBlur(mask, (k, k), 0) with k = 2 * half + 1 and BORDER_REFLECT_101, over the box the result can reach.
    static func blur(_ m: Plane, half: Int, width: Int, height: Int) -> Plane {
        let n = 2 * half + 1
        let k = gaussianKernel(n)
        let x0 = max(m.x0 - half, 0), x1 = min(m.x0 + m.width - 1 + half, width - 1)
        let y0 = max(m.y0 - half, 0), y1 = min(m.y0 + m.height - 1 + half, height - 1)
        let w = x1 - x0 + 1, h = y1 - y0 + 1
        // Row pass over the source rows that hold anything; every other row filters to zero.
        var rows = [Float](repeating: 0, count: w * m.height)
        var tap = [Float](repeating: 0, count: n)
        for j in 0..<m.height {
            let y = m.y0 + j
            for i in 0..<w {
                let x = x0 + i
                for t in 0..<n { tap[t] = m.at(reflect101(x + t - half, width), y) }
                rows[j * w + i] = n >= 7 ? leftToRight(tap, k) : n == 5 ? row5(tap, k) : centreFirst(tap, k, fused: false)
            }
        }
        var out = [Float](repeating: 0, count: w * h)
        for j in 0..<h {
            let y = y0 + j
            for i in 0..<w {
                for t in 0..<n {
                    let row = reflect101(y + t - half, height) - m.y0
                    tap[t] = row >= 0 && row < m.height ? rows[row * w + i] : 0
                }
                out[j * w + i] = centreFirst(tap, k, fused: n >= 5)
            }
        }
        return Plane(x0: x0, y0: y0, width: w, height: h, values: out)
    }

    // recolor_region(frame, mask, color, strength, feather=0, eye) on an already feathered mask, in place.
    static func recolor(_ px: Pixels, mask m: Plane, color: (r: Double, g: Double, b: Double), strength: Double, eye: IrisEye?) {
        let threshold = Float(0.01 as Double)
        var x0 = Int.max, x1 = Int.min, y0 = Int.max, y1 = Int.min
        for j in 0..<m.height {
            for i in 0..<m.width where m.values[j * m.width + i] > threshold {
                x0 = min(x0, m.x0 + i); x1 = max(x1, m.x0 + i + 1)
                y0 = min(y0, m.y0 + j); y1 = max(y1, m.y0 + j + 1)
            }
        }
        guard x0 < x1, y0 < y1 else { return }
        let w = x1 - x0, h = y1 - y0
        let cR = Float(0.299 as Double), cG = Float(0.587 as Double), cB = Float(0.114 as Double)
        var lum = [Float](repeating: 0, count: w * h)
        var core: [Float] = []
        for j in 0..<h {
            let row = px.base + (y0 + j) * px.rowBytes + x0 * 4
            for i in 0..<w {
                let p = row + i * 4  // BGRA
                let l = cR * Float(p[2]) + cG * Float(p[1]) + cB * Float(p[0])
                lum[j * w + i] = l
                if m.at(x0 + i, y0 + j) > 0.5 { core.append(l) }
            }
        }
        let irisLum = max(Double(median(core.isEmpty ? lum : core)), 1.0)

        let target = (Float(color.r), Float(color.g), Float(color.b))
        let targetLum = 0.299 * Double(target.0) + 0.587 * Double(target.1) + 0.114 * Double(target.2)
        // Map the iris median brightness onto the target's, but let very dark (brown) eyes lift only part of the way.
        let goal = min(targetLum, max(irisLum * 1.8, irisLum + 40))
        let scale = Float(goal / max(targetLum, 1.0))
        let tint = (target.0 * scale, target.1 * scale, target.2 * scale)
        let irisLum32 = Float(irisLum), shadeCap = Float(1.2 as Double), s32 = Float(strength)
        let p45 = Float(0.45 as Double), p20 = Float(0.2 as Double), s16 = Float(1.6 as Double), s40 = Float(0.4 as Double)
        let limbal = eye.map { (cx: Double($0.center.x), cy: Double($0.center.y), e0: 0.7 * Double($0.radius), e1: 1.0 * Double($0.radius)) }

        for j in 0..<h {
            let y = y0 + j
            let row = px.base + y * px.rowBytes + x0 * 4
            for i in 0..<w {
                let x = x0 + i
                let l = lum[j * w + i]
                let rel = l / irisLum32
                var shade = Double(min(rel, shadeCap))  // never amplify bright pixels into glowing colour
                if let e = limbal {
                    let dx = Double(x) - e.cx, dy = Double(y) - e.cy
                    shade *= 1.0 - 0.3 * smoothstep64(e.e0, e.e1, (dx * dx + dy * dy).squareRoot())
                }
                let pupil = clip01((rel - p45) / p20)  // much darker than the iris
                let sclera = clip01((s16 - rel) / s40)  // much brighter than the iris
                let glint = clip01((235 - l) / 30)
                let a = m.at(x, y) * pupil * sclera * glint * s32
                let keep = 1 - a
                let p = row + i * 4
                if limbal == nil {  // numpy stays in float32 when there is no limbal ring
                    let shade32 = Float(shade)
                    p[2] = truncated(Double(Float(p[2]) * keep + min(max(tint.0 * shade32, 0), 255) * a))
                    p[1] = truncated(Double(Float(p[1]) * keep + min(max(tint.1 * shade32, 0), 255) * a))
                    p[0] = truncated(Double(Float(p[0]) * keep + min(max(tint.2 * shade32, 0), 255) * a))
                } else {  // the ring's float64 distance promotes the tint, and with it the blend, to float64
                    let a64 = Double(a)
                    p[2] = truncated(Double(Float(p[2]) * keep) + min(max(Double(tint.0) * shade, 0), 255) * a64)
                    p[1] = truncated(Double(Float(p[1]) * keep) + min(max(Double(tint.1) * shade, 0), 255) * a64)
                    p[0] = truncated(Double(Float(p[0]) * keep) + min(max(Double(tint.2) * shade, 0), 255) * a64)
                }
            }
        }
    }

    // astype(np.uint8) of a value that is always inside 0...255.x: drop the fraction.
    private static func truncated(_ v: Double) -> UInt8 { UInt8(min(max(Int(v), 0), 255)) }

    private static func clip01(_ v: Float) -> Float { min(max(v, 0), 1) }

    private static func median(_ values: [Float]) -> Float {
        let s = values.sorted(), n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    private static func smoothstep64(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = min(max((x - e0) / max(e1 - e0, 1e-6), 0), 1)
        return t * t * (3 - 2 * t)
    }

    // _smoothstep on a float32 array: numpy casts both edges and the width to float32 first.
    private struct Smoothstep32 {
        let e0: Float, width: Float
        init(_ e0: Double, _ e1: Double) { self.e0 = Float(e0); width = Float(max(e1 - e0, 1e-6)) }
        func callAsFunction(_ x: Float) -> Float {
            let t = min(max((x - e0) / width, 0), 1)
            return t * t * (3 - 2 * t)
        }
    }
}

// MARK: - OpenCV's Gaussian blur, float32

extension IrisRecolor {
    // getGaussianKernel(n, 0, CV_32F): fixed binomial-like tables up to 9 taps, otherwise sigma = 0.15 n + 0.35.
    static func gaussianKernel(_ n: Int) -> [Float] {
        switch n {
        case 3: return [0.25, 0.5, 0.25]
        case 5: return [0.0625, 0.25, 0.375, 0.25, 0.0625]
        case 7: return [0.03125, 0.109375, 0.21875, 0.28125, 0.21875, 0.109375, 0.03125]
        case 9: return [4, 13, 30, 51, 60, 51, 30, 13, 4].map { Float($0) / 256 }
        default: break
        }
        let sigma = (0.35 as Double).addingProduct(Double(n), 0.15)
        let scale = -0.125 / (sigma * sigma)
        let half = (n - 1) / 2
        var values = [Double](repeating: 0, count: half)
        var sum = 0.0
        for i in 0..<half {
            let x = 1 - n + 2 * i
            values[i] = exp(Double(x * x) * scale)
            sum += values[i]
        }
        sum = sum * 2 + 1
        let mul = 1 / sum
        var kernel = [Float](repeating: Float(mul), count: n)
        for i in 0..<half {
            kernel[i] = Float(values[i] * mul)
            kernel[n - 1 - i] = kernel[i]
        }
        return kernel
    }

    // OpenCV's symmetric filters, centre tap first: the 3-tap passes and every column pass (5 taps and more use NEON's
    // fused multiply-add).
    private static func centreFirst(_ s: [Float], _ k: [Float], fused: Bool) -> Float {
        let c = s.count / 2
        var acc = s[c] * k[c]
        for d in stride(from: 1, through: c, by: 1) {
            acc = fused ? acc.addingProduct(s[c - d] + s[c + d], k[c + d]) : acc + (s[c - d] + s[c + d]) * k[c + d]
        }
        return acc
    }

    // OpenCV's 5-tap row filter fuses the centre product into the first pair (matched against cv2 bit for bit).
    private static func row5(_ s: [Float], _ k: [Float]) -> Float {
        ((s[1] + s[3]) * k[3]).addingProduct(s[2], k[2]) + (s[0] + s[4]) * k[4]
    }

    // OpenCV's general row filter (7 taps and more): tap by tap from the left, fused on NEON.
    private static func leftToRight(_ s: [Float], _ k: [Float]) -> Float {
        var acc = s[0] * k[0]
        for t in 1..<s.count { acc = acc.addingProduct(s[t], k[t]) }
        return acc
    }

    private static func reflect101(_ p: Int, _ n: Int) -> Int {
        if n == 1 { return 0 }
        var p = p
        while p < 0 || p >= n { p = p < 0 ? -p : 2 * n - 2 - p }
        return p
    }
}

// MARK: - cv2.fillPoly(mask, [contour], 255, cv2.LINE_AA)

// OpenCV draws an anti-aliased 1 px line along every edge, then fills the inside solid; that is what clips the iris to
// the eye opening, so it is ported as is rather than replaced by an exact polygon coverage.
extension IrisRecolor {
    struct Coverage {
        let x0: Int, y0: Int, width: Int, height: Int
        var bytes: [UInt8]

        init(x0: Int, y0: Int, width: Int, height: Int) {
            self.x0 = x0; self.y0 = y0; self.width = width; self.height = height
            bytes = [UInt8](repeating: 0, count: width * height)
        }

        mutating func blend(_ x: Int, _ y: Int, _ a: Int) {
            let i = x - x0, j = y - y0
            guard i >= 0, i < width, j >= 0, j < height else { return }
            var v = Int(bytes[j * width + i])
            v += ((255 - v) * a + 127) >> 8
            v += ((255 - v) * a + 127) >> 8
            bytes[j * width + i] = UInt8(v)
        }

        mutating func fill(_ y: Int, _ xa: Int, _ xb: Int) {
            let j = y - y0
            guard j >= 0, j < height else { return }
            let a = max(xa, x0), b = min(xb, x0 + width - 1)
            if a <= b { for x in a...b { bytes[j * width + x - x0] = 255 } }
        }
    }

    private struct Edge { let y0: Int, y1: Int; let x: Int64, dx: Int64 }
    private typealias Point64 = (x: Int64, y: Int64)

    // Points go in with 8 fractional bits, as fillPoly(..., shift=8) takes them; whole-pixel contours give exactly what
    // the integer contour camrelay passes gives.
    static func fillPolyAA(_ contour: [CGPoint], frameWidth: Int, frameHeight: Int, into cov: inout Coverage) {
        guard !contour.isEmpty else { return }
        let shift: Int64 = 8
        func fixed(_ p: CGPoint) -> Point64 {
            let x = Int64((Double(p.x) * 256).rounded()), y = Int64((Double(p.y) * 256).rounded())
            return (x << (16 - shift), (y + ((1 << shift) >> 1)) >> shift)
        }
        var edges: [Edge] = []
        var pt0 = fixed(contour[contour.count - 1])
        for p in contour {
            let pt1 = fixed(p)
            lineAA((pt0.x, pt0.y << 16), (pt1.x, pt1.y << 16), frameWidth: frameWidth, frameHeight: frameHeight, into: &cov)
            if pt0.y != pt1.y {
                let dx = (pt1.x - pt0.x) / (pt1.y - pt0.y)
                edges.append(pt0.y < pt1.y ? Edge(y0: Int(pt0.y), y1: Int(pt1.y), x: pt0.x, dx: dx)
                                           : Edge(y0: Int(pt1.y), y1: Int(pt0.y), x: pt1.x, dx: dx))
            }
            pt0 = pt1
        }
        fillEdges(edges, frameWidth: frameWidth, frameHeight: frameHeight, into: &cov)
    }

    // FillEdgeCollection: per row, the active edges sorted by x, filled pairwise from ceil(left) to floor(right).
    private static func fillEdges(_ edges: [Edge], frameWidth: Int, frameHeight: Int, into cov: inout Coverage) {
        guard edges.count >= 2 else { return }
        var yMin = Int.max, yMax = Int.min, xMin = Int64.max, xMax = Int64(-1)
        for e in edges {
            let xEnd = e.x + Int64(e.y1 - e.y0) * e.dx
            yMin = min(yMin, e.y0); yMax = max(yMax, e.y1)
            xMin = min(xMin, e.x, xEnd); xMax = max(xMax, e.x, xEnd)
        }
        if yMax < 0 || yMin >= frameHeight || xMax < 0 || xMin >= Int64(frameWidth) << 16 { return }
        let first = max(yMin, cov.y0, 0), last = min(yMax, frameHeight, cov.y0 + cov.height) - 1
        guard first <= last else { return }
        var xs: [Int64] = []
        for y in first...last {
            xs.removeAll(keepingCapacity: true)
            for e in edges where e.y0 <= y && y < e.y1 { xs.append(e.x + Int64(y - e.y0) * e.dx) }
            xs.sort()
            var k = 0
            while k + 1 < xs.count {
                var xa = Int((xs[k] + 0xFFFF) >> 16), xb = Int(xs[k + 1] >> 16)
                if xa < frameWidth && xb >= 0 {
                    xa = max(xa, 0); xb = min(xb, frameWidth - 1)
                    cov.fill(y, xa, xb)
                }
                k += 2
            }
        }
    }

    private static let slopeCorr: [Int] = [
        181, 181, 181, 182, 182, 183, 184, 185, 187, 188, 190, 192, 194, 196, 198, 201,
        203, 206, 209, 211, 214, 218, 221, 224, 227, 231, 235, 238, 242, 246, 250, 254,
    ]
    private static let filterTable: [Int] = [
        168, 177, 185, 194, 202, 210, 218, 224, 231, 236, 241, 246, 249, 252, 254, 254,
        254, 254, 252, 249, 246, 241, 236, 231, 224, 218, 210, 202, 194, 185, 177, 168,
        158, 149, 140, 131, 122, 114, 105, 97, 89, 82, 75, 68, 62, 56, 50, 45,
        40, 36, 32, 28, 25, 22, 19, 16, 14, 12, 11, 9, 8, 7, 5, 5,
    ]

    // OpenCV's LineAA for a one-channel image drawn in 255; points are 16.16 fixed point.
    private static func lineAA(_ a: Point64, _ b: Point64, frameWidth: Int, frameHeight: Int, into cov: inout Coverage) {
        var p1 = a, p2 = b
        guard clipLine(Int64(frameWidth) << 16, Int64(frameHeight) << 16, &p1, &p2) else { return }
        var dx = p2.x - p1.x, dy = p2.y - p1.y
        var j: Int64 = dx < 0 ? -1 : 0
        let ax = (dx ^ j) - j
        var i: Int64 = dy < 0 ? -1 : 0
        let ay = (dy ^ i) - i
        let xMajor = ax > ay
        let step: Int64
        var ecount: Int, slope: Int
        if xMajor {
            dy = (dy ^ j) - j
            if j != 0 { swap(&p1, &p2) }
            step = (dy << 16) / (ax | 1)
            p2.x += 1 << 16
            ecount = Int((p2.x >> 16) - (p1.x >> 16))
            j = -(p1.x & 0xFFFF)
            p1.y += ((step * j) >> 16) + (1 << 15)
            slope = Int((step >> 11) & 0x3f)
            slope ^= step < 0 ? 0x3f : 0
            i = (p1.x >> 9) & 0x78
            j = (p2.x >> 9) & 0x78
        } else {
            dx = (dx ^ i) - i
            if i != 0 { swap(&p1, &p2) }
            step = (dx << 16) / (ay | 1)
            p2.y += 1 << 16
            ecount = Int((p2.y >> 16) - (p1.y >> 16))
            j = -(p1.y & 0xFFFF)
            p1.x += ((step * j) >> 16) + (1 << 15)
            slope = Int((step >> 11) & 0x3f)
            slope ^= step < 0 ? 0x3f : 0
            i = (p1.y >> 9) & 0x78
            j = (p2.y >> 9) & 0x78
        }
        slope = (slope & 0x20) != 0 ? 0x100 : slopeCorr[slope]
        let fi = Int(i), fj = Int(j)
        let t0 = slope << 7, t1 = ((0x78 - fi) | 4) * slope, t2 = (fj | 4) * slope
        var ep = [Int](repeating: 0, count: 9)
        ep[8] = slope
        ep[1] = (((((fj - fi) & 0x78) | 4) * slope) >> 8) & 0x1ff
        ep[3] = ep[1]
        ep[2] = (t1 >> 8) & 0x1ff
        ep[4] = (((((fj - fi) + 0x80) | 4) * slope) >> 8) & 0x1ff
        ep[5] = ((t1 + t0) >> 8) & 0x1ff
        ep[6] = (t2 >> 8) & 0x1ff
        ep[7] = ((t2 + t0) >> 8) & 0x1ff

        func corner(_ c: Int) -> Int { ((c >= 2 ? 1 : 0) + 1) & (c | 2) }
        var scount = 0
        var major = Int((xMajor ? p1.x : p1.y) >> 16)
        var minorFixed = xMajor ? p1.y : p1.x
        let majorLimit = xMajor ? frameWidth : frameHeight, minorLimit = xMajor ? frameHeight : frameWidth
        while ecount >= 0 {
            if major >= 0 && major < majorLimit {
                let minor = Int((minorFixed >> 16) - 1)
                let corr = ep[corner(scount) * 3 + corner(ecount)]
                let dist = Int((minorFixed >> 11) & 31)
                let weights = [filterTable[dist + 32], filterTable[dist], filterTable[63 - dist]]
                for (o, wgt) in weights.enumerated() where minor + o >= 0 && minor + o < minorLimit {
                    let alpha = ((corr * wgt) >> 8) & 0xff
                    if xMajor { cov.blend(major, minor + o, alpha) } else { cov.blend(minor + o, major, alpha) }
                }
            }
            major += 1; minorFixed += step; scount += 1; ecount -= 1
        }
    }

    private static func clipLine(_ width: Int64, _ height: Int64, _ p1: inout Point64, _ p2: inout Point64) -> Bool {
        let right = width - 1, bottom = height - 1
        if width <= 0 || height <= 0 { return false }
        func code(_ p: Point64) -> Int { (p.x < 0 ? 1 : 0) + (p.x > right ? 2 : 0) + (p.y < 0 ? 4 : 0) + (p.y > bottom ? 8 : 0) }
        var c1 = code(p1), c2 = code(p2)
        if (c1 & c2) == 0 && (c1 | c2) != 0 {
            if (c1 & 12) != 0 {
                let a: Int64 = c1 < 8 ? 0 : bottom
                p1.x += Int64(Double(a - p1.y) * Double(p2.x - p1.x) / Double(p2.y - p1.y))
                p1.y = a
                c1 = (p1.x < 0 ? 1 : 0) + (p1.x > right ? 2 : 0)
            }
            if (c2 & 12) != 0 {
                let a: Int64 = c2 < 8 ? 0 : bottom
                p2.x += Int64(Double(a - p2.y) * Double(p2.x - p1.x) / Double(p2.y - p1.y))
                p2.y = a
                c2 = (p2.x < 0 ? 1 : 0) + (p2.x > right ? 2 : 0)
            }
            if (c1 & c2) == 0 && (c1 | c2) != 0 {
                if c1 != 0 {
                    let a: Int64 = c1 == 1 ? 0 : right
                    p1.y += Int64(Double(a - p1.x) * Double(p2.y - p1.y) / Double(p2.x - p1.x))
                    p1.x = a
                    c1 = 0
                }
                if c2 != 0 {
                    let a: Int64 = c2 == 1 ? 0 : right
                    p2.y += Int64(Double(a - p2.x) * Double(p2.y - p1.y) / Double(p2.x - p1.x))
                    p2.x = a
                    c2 = 0
                }
            }
        }
        return (c1 | c2) == 0
    }
}
