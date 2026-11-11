import AVFoundation
import AppKit

// --selftest eyepreview: which camera the preview would read (only OBS's virtual camera, never a real one), the camera
// permission, and, when it's allowed, whether pictures arrive from the virtual camera for 3 seconds. Never opens a real
// camera.
extension EyePreview {
    static func selfTestReport() -> String {
        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(what)")
        }

        let devices = videoDevices()
        lines.append("cameras: " + devices.map { "\($0.localizedName) (\($0.modelID))" }.joined(separator: ", "))
        let picked = virtualCamera(in: devices)
        check(picked.map { $0.modelID.contains("OBS") || $0.manufacturer.contains("OBS") } ?? true, "it picks only OBS's virtual camera (\(picked?.localizedName ?? "none here"))")
        let real = devices.filter { !($0.modelID.contains("OBS") || $0.manufacturer.contains("OBS")) }
        check(virtualCamera(in: real) == nil, "with only real cameras (\(real.count)) it picks none")

        switch access {
        case .notAsked: lines.append("camera permission: not asked yet; the page's Show button asks"); return finish()
        case .denied: lines.append("camera permission: refused; the page offers System Settings"); return finish()
        case .allowed: lines.append("camera permission: allowed")
        }
        guard let camera = picked, let input = try? AVCaptureDeviceInput(device: camera) else {
            lines.append("skipped reading: no virtual camera to read")
            return finish()
        }
        let session = AVCaptureSession()
        let output = AVCaptureVideoDataOutput()
        let counter = FrameCounter()
        output.setSampleBufferDelegate(counter, queue: DispatchQueue(label: "eye preview test"))
        if session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(output) { session.addOutput(output) }
        session.startRunning()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 3))
        session.stopRunning()
        check(counter.frames > 0, "pictures arrive from \(camera.localizedName): \(counter.frames) in 3 s\(counter.size.map { ", \($0)" } ?? "")")
        return finish()

        func finish() -> String {
            (lines + [failures == 0 ? "PASS" : "FAIL: \(failures) failed"]).joined(separator: "\n")
        }
    }
}

private final class FrameCounter: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let lock = NSLock()
    private var count = 0
    private var dimensions: String?
    var frames: Int { lock.withLock { count } }
    var size: String? { lock.withLock { dimensions } }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let image = CMSampleBufferGetImageBuffer(sampleBuffer)
        lock.withLock {
            count += 1
            if let image { dimensions = "\(CVPixelBufferGetWidth(image)) × \(CVPixelBufferGetHeight(image))" }
        }
    }
}
