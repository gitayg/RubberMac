import AVFoundation

// Reads a real camera as 32BGRA frames, at 1920 × 1080 when it can (OBS Virtual Camera's size), on its own queue. A
// frame that arrives while the last is still being worked on is dropped, so a slow frame never builds a backlog.
final class EyeCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let device: AVCaptureDevice
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "eye camera frames", qos: .userInteractive)
    private let onFrame: (CVPixelBuffer, TimeInterval) -> Void
    private let onStop: (String) -> Void
    private var observers: [NSObjectProtocol] = []
    private let lock = NSLock()
    private var delivered = 0, late = 0

    init(device: AVCaptureDevice, onFrame: @escaping (CVPixelBuffer, TimeInterval) -> Void, onStop: @escaping (String) -> Void) throws {
        self.device = device
        self.onFrame = onFrame
        self.onStop = onStop
        super.init()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        session.beginConfiguration()
        session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) && device.supportsSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CaptureError.busy(device.localizedName)
        }
        session.addInput(input)
        session.addOutput(output)
        // The picture goes out as the camera sees it; the call app mirrors your own view of it, as with a real camera.
        output.connection(with: .video)?.automaticallyAdjustsVideoMirroring = false
        output.connection(with: .video)?.isVideoMirrored = false
        session.commitConfiguration()

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            self?.onStop("the camera stopped: \(error?.localizedDescription ?? "unknown error")")
        })
        observers.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: .main) { [weak self] _ in
            self?.onStop("\(device.localizedName) was disconnected")
        })
    }

    enum CaptureError: Error, CustomStringConvertible {
        case busy(String)
        var description: String {
            switch self { case .busy(let name): return "\(name) can't be opened right now" }
        }
    }

    func start() { queue.async { [session] in session.startRunning() } }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        queue.sync { session.stopRunning() }
    }

    // Frames the camera sent, and of those, how many came while the last was still being worked on and were dropped.
    var counts: (delivered: Int, dropped: Int) { lock.withLock { (delivered, late) } }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        lock.withLock { delivered += 1; late += 1 }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        lock.withLock { delivered += 1 }
        guard let frame = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame(frame, CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds)
    }
}
