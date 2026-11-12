import CoreGraphics
import CoreVideo
import Foundation

// --selftest eyetracker: camrelay's tracking tests (tests/test_tracking.py) against the smoother fed synthetic eyes,
// the iris refinement on a drawn eye, and a frame with no face. Uses no photos of anyone.
extension EyeTracker {
    enum SelfTest {
        static let fps = 30.0

        static func run() -> String {
            var lines: [String] = []
            var failures = 0
            func check(_ ok: Bool, _ what: String) {
                if !ok { failures += 1 }
                lines.append("\(ok ? "ok  " : "FAIL") \(what)")
            }
            func f2(_ v: Double) -> String { String(format: "%.2f", v) }
            func f2(_ v: CGFloat) -> String { String(format: "%.2f", Double(v)) }

            var rng = Noise(seed: 0)
            var still = OneEuroFilter(0.3, 0.05, 0.3)
            let raw = (0..<300).map { _ in 100 + 1.5 * rng.normal() }
            let calm = raw.enumerated().map { still([$0.element], Double($0.offset) / fps)[0] }
            let sdRaw = sd(raw.dropFirst(30)), sdOut = sd(calm.dropFirst(30))
            check(sdOut < sdRaw / 3, "removes jitter when still: sd \(f2(sdRaw)) px -> \(f2(sdOut)) px (under a third)")

            var moving = OneEuroFilter(0.3, 0.05, 0.3)
            let xs = (0..<20).map { 100 + 15 * Double($0) }
            let followed = xs.enumerated().map { moving([$0.element], Double($0.offset) / fps)[0] }
            check(abs(followed.last! - xs.last!) < 15, "follows fast motion (450 px/s): lags \(f2(abs(followed.last! - xs.last!))) px (under one frame, 15)")

            let swap = Smoother()
            var out: [IrisEye] = []
            for i in 0..<10 {
                out = swap.update(i % 2 == 0 ? [eye(100), eye(200)] : [eye(200), eye(100)], at: Double(i) / fps)
            }
            let kept = out.map(\.center.x).sorted()
            check(kept.count == 2 && abs(kept[0] - 100) < 1 && abs(kept[1] - 200) < 1,
                  "keeps identity when detection order swaps: \(kept.map { f2($0) }) (want 100, 200)")

            let blink = Smoother()
            var t = 0.0
            var alphas: [CGFloat] = []
            for o in Array(repeating: 0.35, count: 5) + [0.2, 0.08, 0.04, 0.08, 0.2] + Array(repeating: 0.35, count: 5) {
                t += 1 / fps
                alphas.append(blink.update([eye(100, openness: CGFloat(o))], at: t).first?.alpha ?? -1)
            }
            let gradual = (0.05 < alphas[5] && alphas[5] < 0.95) || (0.05 < alphas[9] && alphas[9] < 0.95)
            check(alphas[4] > 0.95 && alphas[6...8].min()! < 0.1 && alphas[14] > 0.95 && gradual,
                  "blink fades out and back in: alpha \(alphas.map { f2($0) }.joined(separator: " "))")

            let drop = Smoother(fadeSeconds: 0.1, forgetSeconds: 0.4)
            t = 0
            for _ in 0..<5 {
                t += 1 / fps
                _ = drop.update([eye(100)], at: t)
            }
            t += 1 / fps
            let lost = drop.update([], at: t)
            var later: [IrisEye] = []
            for _ in 0..<20 {
                t += 1 / fps
                later = drop.update([], at: t)
            }
            check(lost.count == 1 && lost[0].alpha > 0 && lost[0].alpha < 1 && later.isEmpty,
                  "short dropout fades instead of popping: alpha \(lost.first.map { f2($0.alpha) } ?? "none") on the lost frame, \(later.count) eyes 0.7 s later")

            // With a slow fade the eye is still visible when forget_seconds runs out, so only the forgetting drops it.
            let slow = Smoother(fadeSeconds: 1, forgetSeconds: 0.4)
            t = 0
            _ = slow.update([eye(100)], at: t)
            let at3 = slow.update([], at: 0.3), at5 = slow.update([], at: 0.5)
            check(at3.count == 1 && at5.isEmpty, "forgets a lost eye after forget_seconds: \(at3.count) eye at 0.3 s, \(at5.count) at 0.5 s")

            let b0 = EyeTracker.blinkFactor(0), b5 = EyeTracker.blinkFactor(0.5), b15 = EyeTracker.blinkFactor(0.15)
            check(b0 == 0 && b5 == 1 && b15 > 0 && b15 < 1, "blink factor: 0 closed, 1 open, between in between (\(f2(b0)), \(f2(b5)), \(f2(b15)))")

            // The drawn iris is 0.18 of the eye's width, against the 0.219 prior, so its radius has to be measured.
            for (scene, place) in [(DrawnEye(highlight: CGVector(dx: -0.25, dy: -0.28), size: 0.15), "highlight on the pupil"),
                                   (DrawnEye(highlight: CGVector(dx: -0.55, dy: 0), size: 0.3), "large highlight on the iris's side")] {
                for side: CGFloat in [-1, 1] {
                    // Where Vision would put its pupil point (a little high, measured), plus 0.3 radii sideways.
                    let start = CGPoint(x: scene.center.x + side * 0.3 * scene.radius,
                                        y: scene.center.y - EyeTracker.pupilDrop * EyeTracker.irisPerEyeWidth * scene.eyeWidth)
                    let found = scene.refine(from: start)
                    let err = hypot(found.center.x - scene.center.x, found.center.y - scene.center.y) / scene.radius
                    let ratio = found.radius / scene.radius
                    check(err <= 0.1 && abs(ratio - 1) <= 0.1,
                          "refines a drawn iris (\(place)) from 0.3 radii \(side < 0 ? "left" : "right") of it: lands \(f2(err)) radii off, radius x\(f2(ratio))")
                }
            }

            let blank = blankFrame()
            let none = EyeTracker(video: false).eyes(in: blank, at: 0), noneVideo = EyeTracker(video: true).eyes(in: blank, at: 0)
            check(none.isEmpty && noneVideo.isEmpty, "no face, no eyes (\(none.count) still, \(noneVideo.count) video)")

            return (lines + [failures == 0 ? "PASS" : "FAIL: \(failures) failed"]).joined(separator: "\n")
        }

        static func eye(_ x: CGFloat, y: CGFloat = 100, r: CGFloat = 12, openness: CGFloat = 0.35) -> IrisEye {
            IrisEye(center: CGPoint(x: x, y: y), radius: r, contour: Array(repeating: .zero, count: 4), openness: openness)
        }

        static func sd<C: Collection>(_ v: C) -> Double where C.Element == Double {
            let m = v.reduce(0, +) / Double(v.count)
            return (v.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(v.count)).squareRoot()
        }

        /// Deterministic noise, so the report is the same every run.
        struct Noise {
            var state: UInt64
            init(seed: UInt64) { state = seed }
            mutating func next() -> Double {
                state &+= 0x9E37_79B9_7F4A_7C15
                var z = state
                z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
                z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
                return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
            }
            mutating func normal() -> Double {
                (-2 * log(max(next(), 1e-300))).squareRoot() * cos(2 * Double.pi * next())
            }
        }

        static func blankFrame() -> CVPixelBuffer {
            var noise = Noise(seed: 1)
            return frame(width: 640, height: 480) { _, _ in
                let v = UInt8(110 + 30 * noise.next())
                return (v, v, v)
            }
        }

        static func frame(width: Int, height: Int, _ pixel: (Int, Int) -> (b: UInt8, g: UInt8, r: UInt8)) -> CVPixelBuffer {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pb)
            let buf = pb!
            CVPixelBufferLockBaseAddress(buf, [])
            let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
            let bpr = CVPixelBufferGetBytesPerRow(buf)
            for y in 0..<height {
                for x in 0..<width {
                    let c = pixel(x, y), p = base + y * bpr + x * 4
                    (p[0], p[1], p[2], p[3]) = (c.b, c.g, c.r, 255)
                }
            }
            CVPixelBufferUnlockBaseAddress(buf, [])
            return buf
        }

        /// A drawn eye, like a webcam's: skin, an almond opening with a dark lash line under the upper lid, white
        /// sclera, a brown iris cut off by both lids, a pupil and a highlight on it, mild noise; edges antialiased.
        struct DrawnEye {
            let outline = [CGPoint(x: 100, y: 120), CGPoint(x: 160, y: 88), CGPoint(x: 240, y: 88),
                           CGPoint(x: 300, y: 120), CGPoint(x: 240, y: 150), CGPoint(x: 160, y: 150)]
            let center = CGPoint(x: 205, y: 116)
            let radius: CGFloat = 36
            var eyeWidth: CGFloat { 200 }
            let pixels: CVPixelBuffer

            /// `highlight`: where the highlight's centre sits, and `size` its radius, in iris radii.
            init(highlight: CGVector, size: Double) {
                let poly = EyeTracker.closedSpline(outline).map { (Double($0.x), Double($0.y)) }
                let lashes = EyeTracker.closedSpline(outline).map { (Double($0.x), Double($0.y) + 5) }
                let (cx, cy, r) = (Double(center.x), Double(center.y), Double(radius))
                let (hx, hy, hr) = (cx + Double(highlight.dx) * r, cy + Double(highlight.dy) * r, size * r)
                var noise = Noise(seed: 2)
                pixels = SelfTest.frame(width: 400, height: 240) { x, y in
                    var acc = (0.0, 0.0, 0.0)
                    for sy in 0..<4 {
                        for sx in 0..<4 {
                            let px = Double(x) + (Double(sx) + 0.5) / 4, py = Double(y) + (Double(sy) + 0.5) / 4
                            let d = hypot(px - cx, py - cy)
                            var c: (Double, Double, Double)
                            if !EyeTracker.inside(poly, px, py) { c = (120, 150, 200) }  // skin, BGR
                            else if !EyeTracker.inside(lashes, px, py) && py < 120 { c = (45, 50, 60) }  // lash line
                            else if hypot(px - hx, py - hy) < hr { c = (250, 250, 250) }  // highlight
                            else if d < 0.33 * r { c = (20, 20, 22) }  // pupil
                            else if d < r { c = (40, 70, 110) }  // brown iris
                            else { c = (215, 220, 225) }  // sclera
                            acc = (acc.0 + c.0, acc.1 + c.1, acc.2 + c.2)
                        }
                    }
                    let n = 8 * (noise.next() - 0.5)
                    func byte(_ v: Double) -> UInt8 { UInt8(min(max(v / 16 + n, 0), 255)) }
                    return (byte(acc.0), byte(acc.1), byte(acc.2))
                }
            }

            func refine(from start: CGPoint) -> (center: CGPoint, radius: CGFloat) {
                var result = (center: start, radius: CGFloat(0))
                EyeTracker.withImage(pixels) { image in
                    result = EyeTracker.refineIris(image: image, contour: EyeTracker.closedSpline(outline), pupil: start, eyeWidth: eyeWidth)
                }
                return result
            }
        }
    }
}
