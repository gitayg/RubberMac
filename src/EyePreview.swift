import AVFoundation
import AppKit

// The Eye Color Camera page's picture of what a call gets. It reads the virtual camera camrelay sends to, never the real
// one, so the recolouring shows exactly as others see it, unmirrored. It runs only while the page is open and the Eye
// Color Camera is on, and needs the camera permission.
final class EyePreview {
    enum Access { case allowed, notAsked, denied }

    let view = EyePreviewView(frame: NSRect(x: 0, y: 0, width: 450, height: 255))
    var onChange: (() -> Void)?
    private(set) var isRunning = false
    // Why there's no picture, when the virtual camera can't be found.
    private(set) var problem: String?
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "eye preview")

    init() {
        view.previewLayer.session = session
    }

    static var access: Access {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .allowed
        case .notDetermined: return .notAsked
        default: return .denied
        }
    }

    static func videoDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video,
                                         position: .unspecified).devices
    }

    // OBS's camera extension, which is where camrelay sends its picture; a real camera never counts.
    static func virtualCamera(in devices: [AVCaptureDevice]) -> AVCaptureDevice? {
        devices.first { $0.modelID.contains("OBS") || $0.manufacturer.contains("OBS") }
    }

    func start() {
        guard !isRunning else { return }
        guard let camera = Self.virtualCamera(in: Self.videoDevices()), let input = try? AVCaptureDeviceInput(device: camera) else {
            problem = "No preview: OBS Virtual Camera isn't there"
            onChange?()
            return
        }
        problem = nil
        isRunning = true
        queue.async { [session] in
            session.beginConfiguration()
            session.inputs.forEach(session.removeInput)
            if session.canAddInput(input) { session.addInput(input) }
            session.commitConfiguration()
            session.startRunning()
        }
        log("eye preview: on")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        queue.async { [session] in
            session.stopRunning()
            session.inputs.forEach(session.removeInput)
        }
        log("eye preview: off")
    }
}

// The picture, inset in its row and rounded like the cards around it.
final class EyePreviewView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspect
        previewLayer.backgroundColor = NSColor.black.cgColor
        previewLayer.cornerRadius = 8
        previewLayer.masksToBounds = true
        layer?.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds.insetBy(dx: 16, dy: 10)
    }
}
