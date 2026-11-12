import AVFoundation
import AppKit

extension EyeCamera {
    /// --selftest eyelive: the real thing, as the page's switch does it. Turns the chosen camera on through EyeCamera,
    /// reads OBS Virtual Camera the way a call app would for 6 seconds, and turns it off again. Opens the real camera
    /// (its light comes on), so it's run only when asked; it saves no picture, only numbers. Skips if another app
    /// is using the camera or the virtual camera.
    static func liveSelfTestReport() -> String {
        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(what)")
        }
        func finish() -> String { (lines + [failures == 0 ? "PASS" : "FAIL: \(failures) failed"]).joined(separator: "\n") }
        func wait(_ seconds: TimeInterval, until done: () -> Bool = { false }) {
            let end = Date(timeIntervalSinceNow: seconds)
            while Date() < end && !done() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
        }

        guard isAvailable else { return "skipped: OBS Virtual Camera isn't installed" }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return "skipped: no camera permission" }
        guard let obs = EyePreview.virtualCamera(in: EyePreview.videoDevices()), let input = try? AVCaptureDeviceInput(device: obs) else {
            return "skipped: OBS Virtual Camera isn't listed as a camera"
        }
        guard !obs.isInUseByAnotherApplication else { return "skipped: another app is using OBS Virtual Camera (a call?)" }
        let camera = EyeCamera()
        camera.refreshCameras()
        guard let device = videoDevices().first(where: { $0.localizedName == camera.cameraName }), !isVirtual(device) else {
            return "skipped: no real camera chosen"
        }
        guard !device.isInUseByAnotherApplication else { return "skipped: another app is using \(device.localizedName)" }
        let savedColor = Settings.eyeColor, savedStrength = Settings.eyeStrength

        let counter = ArrivalCounter()
        let session = AVCaptureSession()
        let output = AVCaptureVideoDataOutput()
        output.setSampleBufferDelegate(counter, queue: DispatchQueue(label: "eye live test"))
        if session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(output) { session.addOutput(output) }
        session.startRunning()
        defer { session.stopRunning() }

        let began = Date()
        camera.start()
        wait(10) { camera.state != .starting }
        check(camera.state == .on, String(format: "turns on reading %@ (%.1f s to the first frame)", device.localizedName, Date().timeIntervalSince(began)))
        guard camera.state == .on else {
            lines.append("state: \(camera.statusLine)")
            camera.stop()
            return finish()
        }

        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let cpuBefore = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        let arrivedBefore = counter.count
        let countsBefore = camera.frameCounts
        var rates: [Int] = [], eyes: [Int] = []
        for _ in 0..<6 {
            wait(1)
            rates.append(camera.fps)
            eyes.append(camera.eyesFound)
        }
        getrusage(RUSAGE_SELF, &usage)
        let cpuAfter = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        let arrived = counter.count - arrivedBefore
        let delivered = camera.frameCounts.delivered - countsBefore.delivered, dropped = camera.frameCounts.dropped - countsBefore.dropped
        lines.append("status: \(camera.statusLine)")
        lines.append("frames sent each second: \(rates.map(String.init).joined(separator: ", ")); eyes found: \(eyes.map(String.init).joined(separator: ", "))")
        lines.append(String(format: "CPU while on: %.0f%% of one core", (cpuAfter - cpuBefore) / 6 * 100))
        // The camera sets the pace: in dim light a MacBook's drops itself to 15 frames a second.
        lines.append(String(format: "the camera sent %.1f frames a second (its range %@)", Double(delivered) / 6,
                            device.activeFormat.videoSupportedFrameRateRanges.map { "\(Int($0.minFrameRate))-\(Int($0.maxFrameRate))" }.joined(separator: ", ")))
        check(delivered >= 6 * 10 && dropped * 20 <= delivered, "keeps up with the camera: \(dropped) of \(delivered) frames dropped")
        check(arrived * 10 >= (delivered - dropped) * 9, "a call app reading OBS Virtual Camera gets them: \(arrived) frames in 6 s")
        check(eyes.filter { $0 >= 2 }.count >= 4, "finds both eyes in most seconds (face the camera)")

        camera.stop()
        wait(1)
        check(camera.state == .off && camera.fps == 0, "turns off")
        check(Settings.eyeColor == savedColor && Settings.eyeStrength == savedStrength, "changes no setting")
        return finish()
    }
}

private final class ArrivalCounter: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let lock = NSLock()
    private var frames = 0
    var count: Int { lock.withLock { frames } }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        lock.withLock { frames += 1 }
    }
}
