import CoreGraphics
import CoreVideo
import Foundation

// --selftest irisrecolor: camrelay's tests/test_eyes.py checks, on drawn eyes only (no photos), plus the frame
// handling camrelay never needed: padded rows and an alpha channel that must stay as it was.
extension IrisRecolor {
    static func selfTestReport() -> String {
        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(what)")
        }
        let blue = (r: 114.0, g: 149.0, b: 172.0)

        // The mask: pupil out, iris in, nothing outside the opening, and a low lid cuts the top of the iris off.
        let (_, open) = TestEye.draw()
        if let m = irisMask(open, width: 200, height: 200) {
            check(m.at(100, 100) == 0 && m.at(130, 100) > 0.9 && m.at(100, 40) == 0,
                  "mask: pupil excluded (\(m.at(100, 100))), iris included (\(m.at(130, 100))), outside the opening excluded (\(m.at(100, 40)))")
        } else { check(false, "mask: computed for an open eye") }
        // Points inside the opening's bounding box but outside the opening itself, so the polygon is what clips them.
        let (_, lidded) = TestEye.draw(lid: 25)
        if let m = irisMask(lidded, width: 200, height: 200) {
            check(m.at(100, 73) == 0 && m.at(100, 80) > 0.9,
                  "mask: the eyelid clips the iris (above the lid \(m.at(100, 73)), below it \(m.at(100, 80)))")
        } else { check(false, "mask: computed for a half-closed eye") }
        var slanted = lidded
        slanted.contour = [CGPoint(x: 40, y: 160), CGPoint(x: 160, y: 160), CGPoint(x: 40, y: 40)]
        if let m = irisMask(slanted, width: 200, height: 200) {
            check(m.at(120, 85) == 0 && m.at(85, 120) > 0.9,
                  "mask: a slanted opening clips along its edge (outside \(m.at(120, 85)), inside \(m.at(85, 120)))")
        } else { check(false, "mask: computed for a slanted opening") }

        // A brown iris turns blue; pupil, glint, alpha and everything away from the eye stay as they were.
        let (brown, eye) = TestEye.draw()
        let frame = brown.buffer()
        apply([eye], color: blue, strength: 1.0, to: frame)
        let out = TestImage(frame)
        let ring = TestImage.average(out, xs: 125..<135, ys: 95..<105), ring0 = TestImage.average(brown, xs: 125..<135, ys: 95..<105)
        check(ring.b > ring.r + 30 && ring0.r > ring0.b,
              "brown iris turns blue: ring was rgb \(ring0.text), now \(ring.text)")
        let pupilKept = TestImage.allPixels(in: out, brown) { x, y in TestEye.distance(x, y) <= 13 }
        check(out.max(100, 100) < 30 && pupilKept, "pupil stays black and untouched (centre max \(out.max(100, 100)))")
        check(out.min(118, 82) > 230, "glint on the brown iris stays white (min \(out.min(118, 82)))")
        let box = 40 + 2 + 1  // iris radius + blur reach + 1
        check(TestImage.allPixels(in: out, brown) { x, y in abs(x - 100) > box || abs(y - 100) > box },
              "pixels outside the eye's box are untouched")
        check(out.alphas.allSatisfy { $0 == TestImage.alpha }, "alpha channel untouched")

        // A light iris, where only the glint rule (not the sclera rule) keeps the catch-light white.
        let (light, lightEye) = TestEye.draw(iris: (200, 190, 180), glint: (250, 250, 250))
        let lightFrame = light.buffer()
        apply([lightEye], color: blue, strength: 1.0, to: lightFrame)
        let lightOut = TestImage(lightFrame)
        check(lightOut.min(118, 82) >= 248, "glint on a light iris stays white (min \(lightOut.min(118, 82)))")

        // No-ops.
        let (plain, plainEye) = TestEye.draw()
        func untouched(_ eyes: [IrisEye], strength: Double) -> Bool {
            let f = plain.buffer()
            apply(eyes, color: blue, strength: strength, to: f)
            return TestImage(f).bytes == plain.bytes
        }
        check(untouched([], strength: 1), "no eyes: frame unchanged")
        check(untouched([plainEye], strength: 0), "zero strength: frame unchanged")
        var faded = plainEye
        faded.alpha = 0.009
        check(untouched([faded], strength: 1), "strength x alpha below 0.01 (closed eye): frame unchanged")
        var elsewhere = plainEye  // a C-shaped opening around the iris: its box covers the iris, its inside never does
        elsewhere.contour = [(20, 20), (180, 20), (180, 40), (40, 40), (40, 160), (180, 160), (180, 180), (20, 180)].map { CGPoint(x: $0.0, y: $0.1) }
        check(untouched([elsewhere], strength: 1), "empty mask (opening misses the iris): frame unchanged")

        // No bright halo on the white of the eye, and the rim reads darker than the middle of the iris.
        for sclera in [170, 200, 225] {
            let (img, e) = TestEye.draw(sclera: UInt8(sclera), noise: false, glint: nil)
            let f = img.buffer()
            apply([e], color: blue, strength: 1.0, to: f)
            let o = TestImage(f)
            let halo = (41...45).flatMap { d in [100 + d, 100 - d] }.map { x in o.maxDiff(img, x, 100) }.max()!
            check(halo <= 3, "no halo on a \(sclera) sclera just outside the iris (max change \(halo))")
            let rim = o.mean(137, 100), mid = o.mean(127, 100), inner = o.mean(125, 100), ringed = o.mean(131, 100)
            check(rim < mid, "rim darker than mid-iris on a \(sclera) sclera (\(rim) < \(mid))")
            check(ringed < inner - 2, "limbal ring darkens the full-mask rim on a \(sclera) sclera (\(ringed) < \(inner) - 2)")
            // The tracker's circle overshooting the real iris puts white of the eye inside the mask; it must stay white.
            let (small, _) = TestEye.draw(sclera: UInt8(sclera), noise: false, irisRadius: 34, glint: nil)
            let sf = small.buffer()
            apply([e], color: blue, strength: 1.0, to: sf)
            let so = TestImage(sf)
            let overshoot = (36...39).flatMap { d in [100 + d, 100 - d] }.map { x in so.maxDiff(small, x, 100) }.max()!
            check(overshoot <= 3, "no halo on a \(sclera) sclera inside an overshooting circle (max change \(overshoot))")
        }

        // Rows packed, padded by CoreVideo, and padded oddly past the picture: one result, padding bytes left alone.
        let packed = brown.buffer(padding: 0), padded = brown.buffer(padding: 36)
        apply([eye], color: blue, strength: 1.0, to: packed)
        apply([eye], color: blue, strength: 1.0, to: padded)
        check(TestImage(packed).bytes == out.bytes && TestImage(padded).bytes == out.bytes,
              "rows of \(CVPixelBufferGetBytesPerRow(packed)), \(CVPixelBufferGetBytesPerRow(frame)) and \(CVPixelBufferGetBytesPerRow(padded)) bytes for 200 px: same result")
        check(TestImage.padding(of: padded).allSatisfy { $0 == TestImage.fill }, "padded rows: padding bytes untouched")

        return (lines + [failures == 0 ? "PASS" : "FAIL: \(failures) failed"]).joined(separator: "\n")
    }
}

// A drawn eye like camrelay's synthetic_eye: grey-white sclera, brown textured iris, black pupil, one glint, and an
// elliptical opening, centred in a 200x200 picture.
private enum TestEye {
    static func distance(_ x: Int, _ y: Int) -> Double { (Double((x - 100) * (x - 100) + (y - 100) * (y - 100))).squareRoot() }

    static func draw(sclera: UInt8 = 235, iris: (Int, Int, Int) = (110, 70, 40), noise: Bool = true,
                     irisRadius: Double = 40, glint: (Int, Int, Int)? = (255, 255, 255), lid: Double = 45) -> (TestImage, IrisEye) {
        var img = TestImage(width: 200, height: 200, rgb: (sclera, sclera, sclera))
        var seed: UInt32 = 1
        for y in 0..<200 {
            for x in 0..<200 {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let n = noise ? Int(seed >> 24) % 30 - 15 : 0
                let d = distance(x, y)
                if d <= irisRadius { img.set(x, y, (iris.0 + n, iris.1 + n, iris.2 + n)) }
                if d <= 14 { img.set(x, y, (8, 6, 5)) }
                let gd = (Double((x - 118) * (x - 118) + (y - 82) * (y - 82))).squareRoot()
                if let g = glint, gd <= 4 { img.set(x, y, g) }
            }
        }
        let contour = stride(from: 0.0, to: 360.0, by: 10.0).map { a in
            CGPoint(x: (100 + 90 * cos(a * .pi / 180)).rounded(), y: (100 + lid * sin(a * .pi / 180)).rounded())
        }
        return (img, IrisEye(center: CGPoint(x: 100, y: 100), radius: 40, contour: contour, openness: lid / 90))
    }
}

private struct TestImage {
    static let alpha: UInt8 = 200, fill: UInt8 = 0xA5
    let width: Int, height: Int
    var bytes: [UInt8]  // BGRA, packed
    var alphas: [UInt8] { stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] } }

    init(width: Int, height: Int, rgb: (UInt8, UInt8, UInt8)) {
        self.width = width; self.height = height
        bytes = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) { bytes[i * 4] = rgb.2; bytes[i * 4 + 1] = rgb.1; bytes[i * 4 + 2] = rgb.0; bytes[i * 4 + 3] = Self.alpha }
    }

    init(_ b: CVPixelBuffer) {
        let w = CVPixelBufferGetWidth(b), h = CVPixelBufferGetHeight(b)
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self), rb = CVPixelBufferGetBytesPerRow(b)
        width = w; height = h
        bytes = (0..<h).flatMap { y in Array(UnsafeBufferPointer(start: base + y * rb, count: w * 4)) }
    }

    mutating func set(_ x: Int, _ y: Int, _ rgb: (Int, Int, Int)) {
        let i = (y * width + x) * 4
        bytes[i] = UInt8(clamping: rgb.2); bytes[i + 1] = UInt8(clamping: rgb.1); bytes[i + 2] = UInt8(clamping: rgb.0)
    }

    func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let i = (y * width + x) * 4
        return (Int(bytes[i + 2]), Int(bytes[i + 1]), Int(bytes[i]))
    }

    func max(_ x: Int, _ y: Int) -> Int { let p = rgb(x, y); return Swift.max(p.0, p.1, p.2) }
    func min(_ x: Int, _ y: Int) -> Int { let p = rgb(x, y); return Swift.min(p.0, p.1, p.2) }
    func mean(_ x: Int, _ y: Int) -> Double { let p = rgb(x, y); return Double(p.0 + p.1 + p.2) / 3 }
    func maxDiff(_ o: TestImage, _ x: Int, _ y: Int) -> Int {
        let a = rgb(x, y), b = o.rgb(x, y)
        return Swift.max(abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2))
    }

    static func average(_ img: TestImage, xs: Range<Int>, ys: Range<Int>) -> (r: Double, g: Double, b: Double, text: String) {
        var s = (0, 0, 0)
        for y in ys { for x in xs { let p = img.rgb(x, y); s.0 += p.0; s.1 += p.1; s.2 += p.2 } }
        let n = Double(xs.count * ys.count), m = (Double(s.0) / n, Double(s.1) / n, Double(s.2) / n)
        return (m.0, m.1, m.2, String(format: "%.0f,%.0f,%.0f", m.0, m.1, m.2))
    }

    // Every pixel the predicate picks is byte-for-byte what it was.
    static func allPixels(in a: TestImage, _ b: TestImage, where pick: (Int, Int) -> Bool) -> Bool {
        for y in 0..<a.height { for x in 0..<a.width where pick(x, y) {
            let i = (y * a.width + x) * 4
            if a.bytes[i..<(i + 4)] != b.bytes[i..<(i + 4)] { return false }
        } }
        return true
    }

    static func padding(of b: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self), rb = CVPixelBufferGetBytesPerRow(b)
        let w = CVPixelBufferGetWidth(b) * 4
        return (0..<CVPixelBufferGetHeight(b)).flatMap { y in Array(UnsafeBufferPointer(start: base + y * rb + w, count: rb - w)) }
    }

    // A 32BGRA buffer holding this picture: CoreVideo's own row alignment, or rows exactly `padding` bytes longer than
    // the picture with the extra filled.
    func buffer(padding: Int? = nil) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        if let padding {
            let rb = width * 4 + padding
            let mem = UnsafeMutableRawPointer.allocate(byteCount: rb * height, alignment: 64)
            memset(mem, Int32(Self.fill), rb * height)
            CVPixelBufferCreateWithBytes(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, mem, rb,
                                         { _, p in p?.deallocate() }, nil, nil, &pb)
        } else {
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &pb)
        }
        let b = pb!
        CVPixelBufferLockBaseAddress(b, [])
        let base = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self), rb = CVPixelBufferGetBytesPerRow(b)
        bytes.withUnsafeBufferPointer { src in
            for y in 0..<height { memcpy(base + y * rb, src.baseAddress! + y * width * 4, width * 4) }
        }
        CVPixelBufferUnlockBaseAddress(b, [])
        return b
    }
}
