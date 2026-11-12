import AVFoundation
import AppKit

// --selftest virtualcam: sends test frames into OBS Virtual Camera and reads them back the way Zoom would, through the
// camera itself: they must arrive with their colours, a smaller frame must come out scaled to the camera's size, and
// after stopping the camera must stop showing them. Never opens a real camera. Skips while another app uses the
// virtual camera, as that would put test colours into someone's call.
extension VirtualCameraSink {
    static func selfTestReport() -> String {
        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(what)")
        }
        func finish() -> String { (lines + [failures == 0 ? "PASS" : "FAIL: \(failures) failed"]).joined(separator: "\n") }
        func skip(_ why: String) -> String { "skipped: \(why)" }

        guard isInstalled else { return skip("OBS Virtual Camera isn't installed") }
        guard EyePreview.access == .allowed else { return skip("no camera permission to read the frames back") }
        guard let camera = EyePreview.virtualCamera(in: EyePreview.videoDevices()), let input = try? AVCaptureDeviceInput(device: camera) else {
            return skip("OBS Virtual Camera isn't listed as a camera")
        }
        guard !camera.isInUseByAnotherApplication else { return skip("another app is using OBS Virtual Camera (a call?); run it when nothing is") }

        let reader = FrameSampler(points: [CGPoint(x: 0.25, y: 0.5), CGPoint(x: 0.75, y: 0.5)])
        let session = AVCaptureSession()
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(reader, queue: DispatchQueue(label: "virtual camera test"))
        if session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(output) { session.addOutput(output) }
        session.startRunning()
        defer { session.stopRunning() }

        let sink: VirtualCameraSink
        do { sink = try VirtualCameraSink() } catch {
            check(false, "opens OBS Virtual Camera's input: \(error)")
            return finish()
        }
        lines.append("OBS Virtual Camera takes \(sink.width) × \(sink.height)")

        // BGRA bytes: a blue-ish left half and an orange right half, then one colour at 1280 × 720.
        let left: [UInt8] = [200, 120, 40, 255], right: [UInt8] = [30, 160, 220, 255], small: [UInt8] = [90, 200, 60, 255]
        func pump(_ frame: CVPixelBuffer, seconds: Double) {
            let until = Date(timeIntervalSinceNow: seconds)
            while Date() < until {
                sink.send(frame)
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.0 / 30))
            }
        }
        func near(_ a: [UInt8]?, _ b: [UInt8]) -> Bool {
            guard let a else { return false }
            return zip(a.prefix(3), b.prefix(3)).allSatisfy { abs(Int($0) - Int($1)) <= 8 }
        }

        reader.reset()
        pump(frame(width: sink.width, height: sink.height) { x, _ in x < sink.width / 2 ? left : right }, seconds: 2)
        let halves = reader.matches { near($0[0], left) && near($0[1], right) }
        check(halves.matching >= 20, "the frames sent arrive in the camera with their colours: \(halves.matching) of \(halves.total) read back match"
              + " (last read \(reader.lastValues.map { $0.map { "\(Array($0.prefix(3)))" } ?? "none" }.joined(separator: " ")), sent \(sink.sent))")

        reader.reset()
        pump(frame(width: 1280, height: 720) { _, _ in small }, seconds: 1.5)
        let scaled = reader.matches { near($0[0], small) && near($0[1], small) }
        check(scaled.matching >= 15 && reader.size == "\(sink.width) × \(sink.height)",
              "a 1280 × 720 frame comes out scaled to \(reader.size ?? "?"): \(scaled.matching) of \(scaled.total) match")

        sink.stop()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.5))
        reader.reset()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))
        let after = reader.matches { near($0[0], small) }
        check(after.total > 0 && after.matching == 0, "after stopping, the camera no longer shows them (\(after.matching) of \(after.total) still do)")
        return finish()
    }

    private static func frame(width: Int, height: Int, _ color: (Int, Int) -> [UInt8]) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        let frame = buffer!
        CVPixelBufferLockBaseAddress(frame, [])
        let base = CVPixelBufferGetBaseAddress(frame)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(frame)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = color(x, y)
                for c in 0..<4 { base[y * rowBytes + x * 4 + c] = pixel[c] }
            }
        }
        CVPixelBufferUnlockBaseAddress(frame, [])
        return frame
    }
}

// Reads the BGRA values at a few points (as fractions of the frame) of every frame that arrives.
private final class FrameSampler: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let points: [CGPoint]
    private let lock = NSLock()
    private var samples: [[[UInt8]?]] = []
    private var dimensions: String?

    init(points: [CGPoint]) { self.points = points }

    var size: String? { lock.withLock { dimensions } }
    var lastValues: [[UInt8]?] { lock.withLock { samples.last ?? [] } }
    func reset() { lock.withLock { samples = [] } }
    func matches(_ test: ([[UInt8]?]) -> Bool) -> (matching: Int, total: Int) {
        lock.withLock { (samples.filter(test).count, samples.count) }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        let width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image)
        guard CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_32BGRA, let base = CVPixelBufferGetBaseAddress(image) else { return }
        let bytes = base.assumingMemoryBound(to: UInt8.self), rowBytes = CVPixelBufferGetBytesPerRow(image)
        let values: [[UInt8]?] = points.map { point in
            let x = min(width - 1, Int(point.x * CGFloat(width))), y = min(height - 1, Int(point.y * CGFloat(height)))
            return (0..<4).map { bytes[y * rowBytes + x * 4 + $0] }
        }
        lock.withLock {
            samples.append(values)
            dimensions = "\(width) × \(height)"
        }
    }
}
