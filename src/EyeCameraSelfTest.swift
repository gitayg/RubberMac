import AVFoundation
import AppKit

extension EyeCamera {
    /// --selftest eyecamera: OBS Virtual Camera is there to send to, the cameras are listed with OBS's marked as one
    /// that can't be the input, a real one is picked, every colour has its RGB, and camrelay's saved settings carry over.
    /// Opens no camera.
    static func selfTestReport() -> String {
        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(what)")
        }

        check(isAvailable, "OBS Virtual Camera is installed to send the picture to")
        let camera = EyeCamera()
        camera.refreshCameras()
        lines.append("cameras: " + camera.cameras.map { "[\($0.index)] \($0.name)\($0.virtual ? " (virtual)" : "")" }.joined(separator: ", "))
        check(camera.cameras.contains { !$0.virtual }, "there's a real camera to read from")
        check(camera.cameras.filter { $0.name.contains("OBS") }.allSatisfy(\.virtual), "OBS's own camera is marked as one that can't be the input")
        check(camera.cameras.first { $0.index == camera.cameraIndex }?.virtual == false, "the camera it would read is a real one (\(camera.cameraName ?? "none"))")
        check(colorNames.allSatisfy { rgb(for: $0) != nil } && aliases.values.allSatisfy(colorNames.contains),
              "every colour has its RGB, and camrelay's old names map to colours in the list")

        let old = adopted(from: ["eye_color": "violet", "eye_strength": 0.7, "camera_id": "abc"])
        check(old.color == "deep-blue" && old.strength == 0.7 && old.cameraID == "abc", "camrelay's saved violet at 70% carries over as Deep Blue at 70%")
        let odd = adopted(from: ["eye_color": "plaid", "eye_strength": 3.0])
        check(odd.color == nil && odd.strength == 1, "an unknown colour is dropped and a strength past 100% is held at 100%")
        lines.append("settings: \(camera.color) at \(Int((camera.strength * 100).rounded()))%")
        return (lines + [failures == 0 ? "PASS" : "FAIL: \(failures) failed"]).joined(separator: "\n")
    }

    /// --selftest eyepipeline <photo.png> [folder]: the whole Eye Color Camera with a photo standing in for the camera.
    /// The photo goes through the tracker, the recolouring and OBS Virtual Camera, and is read back from the virtual
    /// camera the way Zoom would: the irises must come out recoloured as IrisRecolor paints them, and the rest of the
    /// picture untouched. The photo stays on this Mac; a crop of what arrived is saved to the folder, if one is given.
    static func pipelineSelfTestReport(photo: URL, folder: URL?) -> String {
        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(what)")
        }
        func finish() -> String { (lines + [failures == 0 ? "PASS" : "FAIL: \(failures) failed"]).joined(separator: "\n") }

        guard let source = Self.pixelBuffer(from: photo) else { return "FAIL: couldn't read \(photo.lastPathComponent)" }
        guard VirtualCameraSink.isInstalled else { return "skipped: OBS Virtual Camera isn't installed" }
        guard EyePreview.access == .allowed else { return "skipped: no camera permission to read the picture back" }
        guard let obs = EyePreview.virtualCamera(in: EyePreview.videoDevices()), let input = try? AVCaptureDeviceInput(device: obs) else {
            return "skipped: OBS Virtual Camera isn't listed as a camera"
        }
        guard !obs.isInUseByAnotherApplication else { return "skipped: another app is using OBS Virtual Camera (a call?)" }

        let eyes = EyeTracker(video: false).eyes(in: copy(source), at: 0)
        check(eyes.count >= 2, "the tracker finds the eyes in the photo (\(eyes.count))")
        guard !eyes.isEmpty else { return finish() }
        let color = (r: 114.0, g: 149.0, b: 172.0), strength = 0.9
        let expected = copy(source)
        IrisRecolor.apply(eyes, color: color, strength: strength, to: expected)

        let reader = LastFrame()
        let session = AVCaptureSession()
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(reader, queue: DispatchQueue(label: "eye pipeline test"))
        if session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(output) { session.addOutput(output) }
        session.startRunning()
        defer { session.stopRunning() }

        let pipeline: EyePipeline
        do { pipeline = EyePipeline(sink: try VirtualCameraSink(), rgb: color, strength: strength) } catch {
            check(false, "opens OBS Virtual Camera: \(error)")
            return finish()
        }
        var times: [Double] = []
        let start = ProcessInfo.processInfo.systemUptime
        var fpsSeen = 0
        while ProcessInfo.processInfo.systemUptime - start < 3 {
            let frame = copy(source)
            let began = ProcessInfo.processInfo.systemUptime
            pipeline.process(frame, at: began)
            times.append((ProcessInfo.processInfo.systemUptime - began) * 1000)
            fpsSeen = max(fpsSeen, pipeline.reading.fps)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: max(0, 1.0 / 30 - (ProcessInfo.processInfo.systemUptime - began))))
        }
        pipeline.sink.stop()
        times.sort()
        lines.append(String(format: "per frame: median %.1f ms, slowest %.1f ms, %d frames", times[times.count / 2], times.last ?? 0, times.count))
        check(fpsSeen >= 25, "keeps up with a 30 fps camera (\(fpsSeen) frames in a second)")

        guard let arrived = reader.frame else {
            check(false, "the picture arrives in OBS Virtual Camera")
            return finish()
        }
        check(CVPixelBufferGetWidth(arrived) == CVPixelBufferGetWidth(source), "the picture arrives in OBS Virtual Camera at \(CVPixelBufferGetWidth(arrived)) × \(CVPixelBufferGetHeight(arrived))")
        let irises = eyes.map { CGRect(x: $0.center.x - 0.6 * $0.radius, y: $0.center.y - 0.6 * $0.radius, width: 1.2 * $0.radius, height: 1.2 * $0.radius) }
        // Cheeks: well below each eye, never touched.
        let cheeks = eyes.map { CGRect(x: $0.center.x - $0.radius, y: $0.center.y + 4 * $0.radius, width: 2 * $0.radius, height: $0.radius) }
        let changed = meanDifference(arrived, source, in: irises)
        let likePainted = meanDifference(arrived, expected, in: irises)
        let cheek = meanDifference(arrived, source, in: cheeks)
        check(changed >= 8, String(format: "the irises that arrive are recoloured: %.1f levels from the photo", changed))
        check(likePainted <= 4, String(format: "and as IrisRecolor paints them: %.1f levels from its own output", likePainted))
        check(cheek <= 3, String(format: "the rest of the face arrives untouched: %.1f levels on the cheeks", cheek))
        if let folder { lines.append("     picture: " + saveCrop(arrived, around: eyes, to: folder.appendingPathComponent("eye-pipeline.png"))) }
        return finish()
    }

    private static func pixelBuffer(from url: URL) -> CVPixelBuffer? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        // Drawn in the image's own colour space, so the 8-bit values stay as they are in the file.
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
    }

    private static func copy(_ buffer: CVPixelBuffer) -> CVPixelBuffer {
        var out: CVPixelBuffer?
        CVPixelBufferCreate(nil, CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &out)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        CVPixelBufferLockBaseAddress(out!, [])
        let rows = CVPixelBufferGetHeight(buffer), from = CVPixelBufferGetBytesPerRow(buffer), to = CVPixelBufferGetBytesPerRow(out!)
        for y in 0..<rows {
            memcpy(CVPixelBufferGetBaseAddress(out!)! + y * to, CVPixelBufferGetBaseAddress(buffer)! + y * from, min(from, to))
        }
        CVPixelBufferUnlockBaseAddress(out!, [])
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        return out!
    }

    // Mean absolute difference over the RGB of the pixels in the rectangles.
    private static func meanDifference(_ a: CVPixelBuffer, _ b: CVPixelBuffer, in rects: [CGRect]) -> Double {
        CVPixelBufferLockBaseAddress(a, .readOnly)
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(a, .readOnly)
            CVPixelBufferUnlockBaseAddress(b, .readOnly)
        }
        let pa = CVPixelBufferGetBaseAddress(a)!.assumingMemoryBound(to: UInt8.self), ra = CVPixelBufferGetBytesPerRow(a)
        let pb = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self), rb = CVPixelBufferGetBytesPerRow(b)
        let width = min(CVPixelBufferGetWidth(a), CVPixelBufferGetWidth(b)), height = min(CVPixelBufferGetHeight(a), CVPixelBufferGetHeight(b))
        var total = 0, count = 0
        for rect in rects {
            for y in max(0, Int(rect.minY))..<min(height, Int(rect.maxY)) {
                for x in max(0, Int(rect.minX))..<min(width, Int(rect.maxX)) {
                    for c in 0..<3 { total += abs(Int(pa[y * ra + x * 4 + c]) - Int(pb[y * rb + x * 4 + c])) }
                    count += 3
                }
            }
        }
        return count == 0 ? 0 : Double(total) / Double(count)
    }

    private static func saveCrop(_ frame: CVPixelBuffer, around eyes: [IrisEye], to url: URL) -> String {
        let minX = eyes.map { $0.center.x - 4 * $0.radius }.min()!, maxX = eyes.map { $0.center.x + 4 * $0.radius }.max()!
        let minY = eyes.map { $0.center.y - 3 * $0.radius }.min()!, maxY = eyes.map { $0.center.y + 3 * $0.radius }.max()!
        let image = CIImage(cvPixelBuffer: frame)
        let height = CGFloat(CVPixelBufferGetHeight(frame))
        let crop = image.cropped(to: CGRect(x: minX, y: height - maxY, width: maxX - minX, height: maxY - minY))
        guard let cg = CIContext().createCGImage(crop, from: crop.extent) else { return "couldn't draw it" }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: url)
        return url.path
    }
}

// Keeps a copy of the last frame the virtual camera sent.
private final class LastFrame: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let lock = NSLock()
    private var last: CVPixelBuffer?
    var frame: CVPixelBuffer? { lock.withLock { last } }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        var copy: CVPixelBuffer?
        CVPixelBufferCreate(nil, CVPixelBufferGetWidth(image), CVPixelBufferGetHeight(image), kCVPixelFormatType_32BGRA, nil, &copy)
        guard let copy else { return }
        CVPixelBufferLockBaseAddress(image, .readOnly)
        CVPixelBufferLockBaseAddress(copy, [])
        let rows = CVPixelBufferGetHeight(image), from = CVPixelBufferGetBytesPerRow(image), to = CVPixelBufferGetBytesPerRow(copy)
        for y in 0..<rows { memcpy(CVPixelBufferGetBaseAddress(copy)! + y * to, CVPixelBufferGetBaseAddress(image)! + y * from, min(from, to)) }
        CVPixelBufferUnlockBaseAddress(copy, [])
        CVPixelBufferUnlockBaseAddress(image, .readOnly)
        lock.withLock { last = copy }
    }
}
