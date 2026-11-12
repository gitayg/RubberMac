import CoreGraphics
import CoreVideo
import Foundation
import Vision

// Finds irises with Apple's Vision face landmarks, refined against the image, and (for video) smooths them over time
// like camrelay's tracker. Vision gives each eye's opening and a pupil point but no iris size, and its pupil point sits
// off the iris centre (measured against MediaPipe on calibration photos: mostly sideways, and a steady bit high). The
// refinement takes the iris's sides from the image (dark iris to bright sclera) and its height from Vision.
final class EyeTracker {
    private let smoother: Smoother?
    private let request: VNDetectFaceLandmarksRequest

    init(video: Bool = true) {
        smoother = video ? Smoother() : nil
        request = VNDetectFaceLandmarksRequest()
        request.revision = VNDetectFaceLandmarksRequestRevision3
        request.constellation = .constellation76Points
    }

    /// The eyes in a 32BGRA frame taken at `time` (seconds, any steady clock), with `alpha` set.
    func eyes(in frame: CVPixelBuffer, at time: TimeInterval) -> [IrisEye] {
        let found = detect(in: frame)
        if let smoother { return smoother.update(found, at: time) }
        return found.map { e in
            var e = e
            e.alpha = Self.blinkFactor(e.openness)
            return e
        }
    }

    /// --selftest eyetracker
    static func selfTestReport() -> String { SelfTest.run() }

    /// This frame's eyes, unsmoothed, alpha 1.
    func detect(in frame: CVPixelBuffer) -> [IrisEye] {
        guard CVPixelBufferGetPixelFormatType(frame) == kCVPixelFormatType_32BGRA else { return [] }
        let handler = VNImageRequestHandler(cvPixelBuffer: frame, orientation: .up, options: [:])
        guard (try? handler.perform([request])) != nil, let faces = request.results, !faces.isEmpty else { return [] }
        let size = CGSize(width: CVPixelBufferGetWidth(frame), height: CVPixelBufferGetHeight(frame))
        let biggest = faces.sorted { $0.boundingBox.width * $0.boundingBox.height > $1.boundingBox.width * $1.boundingBox.height }
        var out: [IrisEye] = []
        Self.withImage(frame) { image in
            for face in biggest.prefix(2) {
                guard let lm = face.landmarks else { continue }
                for (eye, pupil) in [(lm.leftEye, lm.leftPupil), (lm.rightEye, lm.rightPupil)] {
                    guard let eye, let pupil, eye.pointCount >= 3, pupil.pointCount >= 1 else { continue }
                    // Vision's image points have the origin at the bottom left.
                    let flip = { (p: CGPoint) in CGPoint(x: p.x, y: size.height - p.y) }
                    let outline = eye.pointsInImage(imageSize: size).map(flip)
                    let p = flip(pupil.pointsInImage(imageSize: size)[0])
                    out.append(Self.makeEye(outline: outline, pupil: p, image: image))
                }
            }
        }
        return out
    }

    /// One eye from Vision's eye outline and pupil point: the opening as a smooth polygon, and the iris refined.
    static func makeEye(outline: [CGPoint], pupil: CGPoint, image: BGRAImage) -> IrisEye {
        let contour = closedSpline(outline)
        let xs = contour.map(\.x), ys = contour.map(\.y)
        let openness = (ys.max()! - ys.min()!) / max(xs.max()! - xs.min()!, 1)
        let width = outline.map(\.x).max()! - outline.map(\.x).min()!
        let iris = refineIris(image: image, contour: contour, pupil: pupil, eyeWidth: width)
        return IrisEye(center: iris.center, radius: iris.radius, contour: contour, openness: openness)
    }

    // Vision's 76-point eye outline has 6 points; a Catmull-Rom curve through them follows the lids' curve, which
    // raised the overlap with MediaPipe's 16-point opening from 0.72 to 0.81 (median IoU on the calibration photos).
    static func closedSpline(_ p: [CGPoint], steps: Int = 8) -> [CGPoint] {
        let k = p.count
        var out: [CGPoint] = []
        out.reserveCapacity(k * steps)
        for i in 0..<k {
            let p0 = p[(i + k - 1) % k], p1 = p[i], p2 = p[(i + 1) % k], p3 = p[(i + 2) % k]
            for s in 0..<steps {
                let t = CGFloat(s) / CGFloat(steps), t2 = t * t, t3 = t2 * t
                func f(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
                    0.5 * (2 * b + (c - a) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (3 * b - a - 3 * c + d) * t3)
                }
                out.append(CGPoint(x: f(p0.x, p1.x, p2.x, p3.x), y: f(p0.y, p1.y, p2.y, p3.y)))
            }
        }
        return out
    }

    /// Read access to a locked 32BGRA frame.
    struct BGRAImage {
        let base: UnsafePointer<UInt8>
        let width: Int, height: Int, bytesPerRow: Int

        func luma(_ x: Int, _ y: Int) -> Float {
            let p = base + y * bytesPerRow + x * 4
            return 0.114 * Float(p[0]) + 0.587 * Float(p[1]) + 0.299 * Float(p[2])
        }
    }

    static func withImage(_ frame: CVPixelBuffer, _ body: (BGRAImage) -> Void) {
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(frame) else { return }
        body(BGRAImage(base: base.assumingMemoryBound(to: UInt8.self), width: CVPixelBufferGetWidth(frame),
                       height: CVPixelBufferGetHeight(frame), bytesPerRow: CVPixelBufferGetBytesPerRow(frame)))
    }
}

// The iris refinement. Constants marked "fitted" were fitted on one calibration session's photos and checked on the
// other session's; everything else is a scale-free choice made on the first session.
extension EyeTracker {
    /// Fitted: MediaPipe's iris radius over the width of Vision's eye outline (0.219, sd 0.008). Sets the search scale,
    /// and the radius when the image gives no answer.
    static let irisPerEyeWidth: CGFloat = 0.219
    /// Fitted: how far below Vision's pupil point the iris centre sits, in iris radii (0.071, sd 0.058). The image
    /// can't do better here: the lids hide the iris's top and bottom, and a circle through its sides alone put the
    /// centre's height off by 0.25 radii (sd), against 0.06 for Vision's point.
    static let pupilDrop: CGFloat = 0.071

    /// The iris centre and radius: the sideways position and radius from where rays out of the centre cross from the
    /// dark iris to the bright sclera inside the eye opening, the height from Vision's pupil point.
    static func refineIris(image: BGRAImage, contour: [CGPoint], pupil: CGPoint, eyeWidth: CGFloat) -> (center: CGPoint, radius: CGFloat) {
        let r0 = Double(irisPerEyeWidth * eyeWidth)
        let cy = Double(pupil.y) + Double(pupilDrop) * r0
        var cx = Double(pupil.x), r = r0
        guard r0 >= 2, let luma = OpenedLuma(image: image, around: contour, openRadius: max(1, Int((0.25 * r0).rounded()))) else {
            return (CGPoint(x: cx, y: cy), CGFloat(r))
        }
        let poly = contour.map { (Double($0.x), Double($0.y)) }
        // Only rays within 30 degrees of horizontal: further up or down they meet the lids, whose edges look like the
        // iris's (measured: wider sectors shrank the radius by 5-10%).
        let angles = (0..<72).compactMap { k -> Double? in
            let folded = min(k * 5 % 360, 360 - k * 5 % 360)
            return folded < 30 || folded > 150 ? Double(k * 5) * Double.pi / 180 : nil
        }
        for _ in 0..<3 {
            let edges = irisEdges(luma, poly, cx, cy, r0, angles)
            guard edges.count >= 4, edges.filter({ $0.x < cx }).count >= 2, edges.filter({ $0.x > cx }).count >= 2,
                  let fit = robustCircle(edges, cy: cy) else { break }
            guard fit.r > 0.6 * r0, fit.r < 1.6 * r0, abs(fit.cx - Double(pupil.x)) < 0.8 * r0 else { break }
            (cx, r) = (fit.cx, fit.r)
        }
        return (CGPoint(x: cx, y: cy), CGFloat(r))
    }

    /// The luminance around one eye, opened (eroded then dilated) so specular highlights smaller than the iris -
    /// they sit on the pupil in most frames and would read as iris edges - are gone. Edges of the iris survive it.
    struct OpenedLuma {
        let x0: Int, y0: Int, w: Int, h: Int
        var v: [Float]

        init?(image: BGRAImage, around contour: [CGPoint], openRadius k: Int) {
            // The opening reaches 2k pixels; a margin that wide makes the crop's result match the whole frame's.
            let m = 2 * k + 2
            let minX = max(0, Int(contour.map(\.x).min()!.rounded(.down)) - m)
            let maxX = min(image.width - 1, Int(contour.map(\.x).max()!.rounded(.up)) + m)
            let minY = max(0, Int(contour.map(\.y).min()!.rounded(.down)) - m)
            let maxY = min(image.height - 1, Int(contour.map(\.y).max()!.rounded(.up)) + m)
            guard maxX - minX >= 3, maxY - minY >= 3 else { return nil }
            (x0, y0, w, h) = (minX, minY, maxX - minX + 1, maxY - minY + 1)
            v = [Float](repeating: 0, count: w * h)
            for y in 0..<h { for x in 0..<w { v[y * w + x] = image.luma(x0 + x, y0 + y) } }
            v = Self.filter(Self.filter(v, w, h, k, min), w, h, k, max)
        }

        /// A separable square min or max filter of half-size k; the window is clipped at the crop's edges.
        private static func filter(_ src: [Float], _ w: Int, _ h: Int, _ k: Int, _ op: (Float, Float) -> Float) -> [Float] {
            var tmp = src, dst = src
            for y in 0..<h {
                for x in 0..<w {
                    var a = src[y * w + x]
                    for i in max(0, x - k)...min(w - 1, x + k) { a = op(a, src[y * w + i]) }
                    tmp[y * w + x] = a
                }
            }
            for y in 0..<h {
                for x in 0..<w {
                    var a = tmp[y * w + x]
                    for j in max(0, y - k)...min(h - 1, y + k) { a = op(a, tmp[j * w + x]) }
                    dst[y * w + x] = a
                }
            }
            return dst
        }

        /// Bilinear sample at image coordinates, where pixel (i, j) covers [i, i+1) x [j, j+1).
        func sample(_ x: Double, _ y: Double) -> Float {
            let fx = min(max(x - 0.5 - Double(x0), 0), Double(w - 1)), fy = min(max(y - 0.5 - Double(y0), 0), Double(h - 1))
            let ix = min(Int(fx), w - 2), iy = min(Int(fy), h - 2)
            let ax = Float(fx - Double(ix)), ay = Float(fy - Double(iy))
            let i = iy * w + ix
            return (v[i] * (1 - ax) + v[i + 1] * ax) * (1 - ay) + (v[i + w] * (1 - ax) + v[i + w + 1] * ax) * ay
        }
    }

    static func inside(_ poly: [(Double, Double)], _ x: Double, _ y: Double) -> Bool {
        var res = false
        var j = poly.count - 1
        for i in poly.indices {
            let (xi, yi) = poly[i], (xj, yj) = poly[j]
            if (yi > y) != (yj > y), x < (xj - xi) * (y - yi) / (yj - yi + 1e-12) + xi { res.toggle() }
            j = i
        }
        return res
    }

    /// Along each ray from (cx, cy), the strongest rise from dark to bright before the ray leaves the eye opening.
    static func irisEdges(_ luma: OpenedLuma, _ poly: [(Double, Double)], _ cx: Double, _ cy: Double, _ r0: Double,
                          _ angles: [Double]) -> [(x: Double, y: Double)] {
        let step = 0.5, k = 2  // samples every half pixel; the rise is taken over +-1 px
        let s0 = 0.45 * r0
        let n = Int(((1.7 * r0 - s0) / step).rounded(.up))
        guard n > 2 * k + 2 else { return [] }
        var edges: [(x: Double, y: Double)] = []
        var v = [Float](repeating: 0, count: n)
        for a in angles {
            let dx = cos(a), dy = sin(a)
            var count = 0
            while count < n {
                let s = s0 + Double(count) * step
                let x = cx + s * dx, y = cy + s * dy
                if !inside(poly, x, y) { break }
                v[count] = luma.sample(x, y)
                count += 1
            }
            guard count > 2 * k else { continue }
            var g = [Float](repeating: -.infinity, count: n)
            var best = -1
            for j in k..<(count - k) {
                g[j] = v[j + k] - v[j - k]
                if best < 0 || g[j] > g[best] { best = j }
            }
            guard best >= 0, g[best] > 10 else { continue }
            var s = s0 + Double(best) * step
            let jj = min(max(best, 1), n - 2)
            let gl = g[jj - 1], gc = g[jj], gr = g[jj + 1]
            let den = gl - 2 * gc + gr
            if gl.isFinite, gr.isFinite, den < 0 {
                s = s0 + Double(jj) * step + step * Double(min(max(0.5 * (gl - gr) / den, -1), 1))
            }
            edges.append((cx + s * dx, cy + s * dy))
        }
        return edges
    }

    /// Least-squares circle with its centre's height fixed, reweighted (Tukey) so stray edges - lashes, lid
    /// shadows - drop out.
    static func robustCircle(_ e: [(x: Double, y: Double)], cy: Double) -> (cx: Double, r: Double)? {
        func fit(_ w: [Double]) -> (cx: Double, r: Double)? {
            // x^2 + (y - cy)^2 = 2 cx x + c, linear in (cx, c), with r^2 = c + cx^2.
            var sxx = 0.0, sx = 0.0, s1 = 0.0, sxb = 0.0, sb = 0.0
            for (p, wi) in zip(e, w) {
                let b = p.x * p.x + (p.y - cy) * (p.y - cy)
                sxx += wi * 4 * p.x * p.x; sx += wi * 2 * p.x; s1 += wi
                sxb += wi * 2 * p.x * b; sb += wi * b
            }
            let det = sxx * s1 - sx * sx
            guard abs(det) > 1e-9 else { return nil }
            let cx = (sxb * s1 - sx * sb) / det, c = (sxx * sb - sx * sxb) / det
            return (cx, max(c + cx * cx, 1e-6).squareRoot())
        }
        guard var best = fit(e.map { _ in 1 }) else { return nil }
        for _ in 0..<10 {
            let res = e.map { hypot($0.x - best.cx, $0.y - cy) - best.r }
            let sorted = res.map(abs).sorted()
            let mad = sorted.count % 2 == 1 ? sorted[sorted.count / 2] : 0.5 * (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2])
            let scale = max(1.4826 * mad, 0.3)
            let w = res.map { r -> Double in
                let u = r / (4.5 * scale)
                return abs(u) < 1 ? (1 - u * u) * (1 - u * u) : 0
            }
            guard w.reduce(0, +) >= 3, let next = fit(w) else { break }
            best = next
        }
        return best
    }
}
