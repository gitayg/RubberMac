import AVFoundation
import AppKit

// Eye Color Camera: recolours your eyes live on video calls. RubberMAC reads a real camera, finds the irises with
// Vision (EyeTracker), recolours them (IrisRecolor) and sends the picture to OBS Virtual Camera (VirtualCameraSink),
// which you pick in Zoom, Meet or Teams. Until 1.26 this ran camrelay, a Python helper; it all runs in RubberMAC now.
final class EyeCamera {
    struct Camera: Equatable {
        let index: Int
        let name: String
        let virtual: Bool
    }

    enum State: Equatable {
        case off, starting, on
        case error(String)
    }

    static let strengths = [0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9]
    static let colorNames = ["blue", "ice-blue", "deep-blue", "blue-green", "green", "gray", "hazel", "amber", "brown"]
    // Names camrelay 0.1 used, for a colour saved then.
    static let aliases = ["lightblue": "ice-blue", "violet": "deep-blue"]

    /// The colours as RGB 0...1: real eye tones, muted like real irises (camrelay/eyes.py COLORS has the sources).
    static let palette: [String: (Double, Double, Double)] = {
        let bytes: [String: (Double, Double, Double)] = [
            "blue": (114, 149, 172), "ice-blue": (170, 191, 210), "deep-blue": (67, 102, 135), "blue-green": (97, 139, 140),
            "green": (104, 119, 83), "gray": (123, 134, 135), "hazel": (101, 71, 31), "amber": (141, 98, 50),
            "brown": (72, 41, 32),
        ]
        return bytes.mapValues { ($0.0 / 255, $0.1 / 255, $0.2 / 255) }
    }()

    /// A colour name as people read it: "ice-blue" is "Ice Blue".
    static func title(for name: String) -> String { name.replacingOccurrences(of: "-", with: " ").capitalized }

    /// RGB for a colour name or a "#rrggbb" value.
    static func rgb(for name: String) -> (Double, Double, Double)? {
        if let known = palette[name.lowercased()] { return known }
        let hex = name.hasPrefix("#") ? String(name.dropFirst()) : name
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    static let obsURL = URL(string: "https://obsproject.com/download")!

    /// What to keep from camrelay's config file: its colour (under today's name), strength and camera.
    static func adopted(from config: [String: Any]) -> (color: String?, strength: Double?, cameraID: String?) {
        let color = (config["eye_color"] as? String).map { aliases[$0.lowercased()] ?? $0.lowercased() }
        return (color.flatMap { rgb(for: $0) != nil ? $0 : nil }, (config["eye_strength"] as? Double).map { min(1, max(0, $0)) },
                config["camera_id"] as? String)
    }

    /// It needs OBS's virtual camera to send the picture to; nothing else.
    static var isAvailable: Bool { VirtualCameraSink.isInstalled }

    private(set) var state: State = .off
    private(set) var fps = 0
    private(set) var eyesFound = 0
    private(set) var cameras: [Camera] = []
    let colors = colorNames
    private(set) var color: String
    private(set) var strength: Double
    private(set) var cameraIndex = 0
    var onChange: (() -> Void)?

    private var devices: [AVCaptureDevice] = []
    private var capture: EyeCapture?
    private var pipeline: EyePipeline?
    private var timer: Timer?
    private var startedAt = Date.distantPast

    init() {
        color = Self.rgb(for: Settings.eyeColor) != nil ? Settings.eyeColor : "blue"
        strength = Settings.eyeStrength
    }

    var isOn: Bool { state == .on || state == .starting }
    // Frames the camera has sent since it was turned on, and those dropped because the last was still being worked on.
    var frameCounts: (delivered: Int, dropped: Int) { capture?.counts ?? (0, 0) }
    var cameraName: String? { cameras.first { $0.index == cameraIndex }?.name }

    var statusLine: String {
        switch state {
        case .off: return "Off"
        case .starting: return "Starting…"
        case .on:
            let source = cameraName.map { "\($0) → " } ?? ""
            return "On: \(source)OBS Virtual Camera\(fps > 0 ? " · \(fps) fps" : "")"
        case .error(let message):
            let first = message.split(separator: "\n").first.map(String.init) ?? message
            return "Error: \(first.count > 70 ? String(first.prefix(69)) + "…" : first)"
        }
    }

    var errorMessage: String? {
        if case .error(let message) = state { return message }
        return nil
    }

    // MARK: Cameras

    static func isVirtual(_ device: AVCaptureDevice) -> Bool {
        let text = "\(device.localizedName) \(device.modelID) \(device.manufacturer)".lowercased()
        return ["obs", "virtual camera", "camrelay"].contains { text.contains($0) }
    }

    static func videoDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video,
                                         position: .unspecified).devices
    }

    /// Lists the cameras (no permission needed for the names) so the page can show them.
    func prepare() { refreshCameras() }

    func refreshCameras() {
        devices = Self.videoDevices()
        cameras = devices.enumerated().map { Camera(index: $0, name: $1.localizedName, virtual: Self.isVirtual($1)) }
        let saved = Settings.eyeCameraID.flatMap { id in devices.firstIndex { $0.uniqueID == id } }
        cameraIndex = saved ?? cameras.first { !$0.virtual }?.index ?? 0
        onChange?()
    }

    // MARK: Commands

    func toggle() { isOn ? stop() : start() }

    func start() {
        guard !isOn else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            open()
        case .notDetermined:
            state = .starting
            onChange?()
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.state == .starting else { return }
                    if granted { self.open() } else { self.fail(Self.noPermission) }
                }
            }
        default:
            fail(Self.noPermission)
        }
    }

    static let noPermission = "RubberMAC isn't allowed to use the camera: allow it in System Settings › Privacy & Security › Camera"

    private func open() {
        if devices.isEmpty { refreshCameras() }
        guard devices.indices.contains(cameraIndex), !Self.isVirtual(devices[cameraIndex]) else {
            return fail("there's no camera to read from")
        }
        let device = devices[cameraIndex]
        do {
            let sink = try VirtualCameraSink()
            let pipeline = EyePipeline(sink: sink, rgb: rgb255, strength: strength)
            pipeline.onFirstFrame = { [weak self] in
                DispatchQueue.main.async {
                    guard let self, self.state == .starting else { return }
                    self.state = .on
                    self.onChange?()
                }
            }
            capture = try EyeCapture(device: device, onFrame: { pipeline.process($0, at: $1) },
                                     onStop: { [weak self] in self?.fail($0) })
            self.pipeline = pipeline
        } catch {
            return fail("\(error)")
        }
        state = .starting
        startedAt = Date()
        capture?.start()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        log("eye camera: on, \(device.localizedName) → OBS Virtual Camera")
        onChange?()
    }

    // Keeps the frame rate on the page fresh, and gives up on a camera that never sends a picture.
    private func tick() {
        guard let reading = pipeline?.reading else { return }
        if state == .starting && Date().timeIntervalSince(startedAt) > 10 {
            return fail("\(cameraName ?? "The camera") gave no picture; is another app holding it?")
        }
        guard reading.fps != fps || reading.eyes != eyesFound else { return }
        fps = reading.fps
        eyesFound = reading.eyes
        onChange?()
    }

    func stop() {
        guard close() else { return }
        state = .off
        log("eye camera: off")
        onChange?()
    }

    func shutdown() { _ = close() }

    @discardableResult
    private func close() -> Bool {
        timer?.invalidate()
        timer = nil
        fps = 0
        eyesFound = 0
        let wasOpen = capture != nil || pipeline != nil || state != .off
        capture?.stop()
        pipeline?.sink.stop()
        capture = nil
        pipeline = nil
        return wasOpen
    }

    private func fail(_ message: String) {
        close()
        state = .error(message)
        log("eye camera: \(message)")
        onChange?()
    }

    private var rgb255: (r: Double, g: Double, b: Double) {
        let rgb = Self.rgb(for: color) ?? Self.palette["blue"]!
        return (rgb.0 * 255, rgb.1 * 255, rgb.2 * 255)
    }

    func setColor(_ name: String) {
        guard Self.rgb(for: name) != nil else { return }
        color = name
        Settings.eyeColor = name
        pipeline?.setLook(rgb: rgb255, strength: strength)
        onChange?()
    }

    func setStrength(_ value: Double) {
        strength = min(1, max(0, value))
        Settings.eyeStrength = strength
        pipeline?.setLook(rgb: rgb255, strength: strength)
        onChange?()
    }

    func setCamera(_ index: Int) {
        guard devices.indices.contains(index), !Self.isVirtual(devices[index]) else { return }
        cameraIndex = index
        Settings.eyeCameraID = devices[index].uniqueID
        if isOn {
            close()
            open()
        }
        onChange?()
    }

    // MARK: camrelay's own app

    /// The separate camrelay menu-bar app, if still installed, uses the same camera and virtual camera.
    static func separateAppRunning() -> Bool {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", "camrelay.menubar"]
        pgrep.standardOutput = FileHandle.nullDevice
        pgrep.standardError = FileHandle.nullDevice
        guard (try? pgrep.run()) != nil else { return false }
        pgrep.waitUntilExit()
        return pgrep.terminationStatus == 0
    }

    static func quitSeparateApp() {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-f", "camrelay.menubar"]
        try? pkill.run()
    }
}
