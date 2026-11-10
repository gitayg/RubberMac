import AppKit

// Eye Color Camera: recolours your eyes live on video calls, using camrelay (github.com/gitayg/camrelay).
// camrelay does the face tracking and iris recolouring in Python and sends the picture to the OBS virtual
// camera. RubberMAC runs it as a helper (`python -m camrelay --control`), sends it commands and shows its
// state in the menu. One JSON object per line: commands on the helper's stdin, events on its stdout.
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

    /// camrelay's colour names (camrelay/eyes.py COLORS) as RGB 0...1, for the menu-bar dot.
    static let palette: [String: (Double, Double, Double)] = {
        let bytes: [String: (Double, Double, Double)] = [
            "blue": (40, 110, 230), "lightblue": (110, 170, 240), "green": (40, 160, 80), "hazel": (140, 120, 50),
            "gray": (140, 150, 160), "violet": (140, 70, 200), "red": (200, 30, 40),
        ]
        return bytes.mapValues { ($0.0 / 255, $0.1 / 255, $0.2 / 255) }
    }()

    /// RGB for a colour name or a "#rrggbb" value.
    static func rgb(for name: String) -> (Double, Double, Double)? {
        if let known = palette[name.lowercased()] { return known }
        let hex = name.hasPrefix("#") ? String(name.dropFirst()) : name
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }
    static let projectURL = URL(string: "https://github.com/gitayg/camrelay")!
    static let outdatedMessage = "camrelay is too old for RubberMAC: update it (git pull in its folder, e.g. ~/camrelay)"

    private(set) var state: State = .off
    private(set) var device: String?
    private(set) var fps = 0
    private(set) var cameras: [Camera] = []
    private(set) var colors = ["blue", "lightblue", "green", "hazel", "gray", "violet", "red"]
    private(set) var color = "blue"
    private(set) var strength = 0.6
    private(set) var cameraIndex = 0
    private(set) var isCalibrating = false
    var onChange: (() -> Void)?

    private var helper: Process?
    private var calibration: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var stderrTail: [String] = []
    private var quitting = false
    private var resumeAfterCalibration = false

    init() {
        // Writing to the helper after it exited must not kill RubberMAC.
        signal(SIGPIPE, SIG_IGN)
    }

    var isOn: Bool { state == .on || state == .starting }
    var cameraName: String? { cameras.first { $0.index == cameraIndex }?.name }

    var statusLine: String {
        if isCalibrating { return "Calibrating in its own window…" }
        switch state {
        case .off: return "Off"
        case .starting: return "Starting…"
        case .on:
            let source = cameraName.map { "\($0) → " } ?? ""
            return "On: \(source)\(device ?? "virtual camera")\(fps > 0 ? " · \(fps) fps" : "")"
        case .error(let message):
            let first = message.split(separator: "\n").first.map(String.init) ?? message
            return "Error: \(first.count > 70 ? String(first.prefix(69)) + "…" : first)"
        }
    }

    var errorMessage: String? {
        if case .error(let message) = state { return message }
        return nil
    }

    // MARK: Finding camrelay

    /// The Python interpreter camrelay is installed in: the one the camrelay app launches, else ~/camrelay/.venv.
    static func python() -> URL? {
        let fm = FileManager.default
        if let custom = UserDefaults.standard.string(forKey: "camrelayPython"), fm.isExecutableFile(atPath: custom) {
            return URL(fileURLWithPath: custom)
        }
        let home = fm.homeDirectoryForCurrentUser.path
        for launcher in ["/Applications/camrelay.app/Contents/MacOS/camrelay",
                         "\(home)/Applications/camrelay.app/Contents/MacOS/camrelay"] {
            if let script = try? String(contentsOfFile: launcher, encoding: .utf8),
               let path = execPath(inLauncher: script), fm.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        let venv = "\(home)/camrelay/.venv/bin/python"
        return fm.isExecutableFile(atPath: venv) ? URL(fileURLWithPath: venv) : nil
    }

    /// The program on the launcher's `exec` line, as `camrelay-menubar --install-app` writes it
    /// (a plain path, or one in single quotes when it has spaces).
    static func execPath(inLauncher script: String) -> String? {
        for line in script.split(separator: "\n") where line.hasPrefix("exec ") {
            let rest = line.dropFirst(5)
            if rest.hasPrefix("'") {
                let body = rest.dropFirst()
                return body.firstIndex(of: "'").map { String(body[..<$0]) }
            }
            return rest.split(separator: " ").first.map(String.init)
        }
        return nil
    }

    /// The separate camrelay menu-bar app uses the same camera and virtual camera.
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

    // MARK: Commands

    /// Starts the helper (without turning the camera on) so the camera list is ready.
    func prepare() {
        _ = launch()
    }

    func start() {
        guard send(["cmd": "start"]) else { return }
        state = .starting
        onChange?()
    }

    func stop() {
        guard helper != nil else { return }
        send(["cmd": "stop"])
    }

    func toggle() {
        isOn ? stop() : start()
    }

    func setColor(_ name: String) {
        send(["cmd": "set", "color": name])
    }

    func setStrength(_ value: Double) {
        send(["cmd": "set", "strength": value])
    }

    func setCamera(_ index: Int) {
        send(["cmd": "set", "camera": index])
    }

    func refreshCameras() {
        send(["cmd": "cameras"])
    }

    /// Opens camrelay's calibration window (alignment hints, test shots, colour tuning) in its own process;
    /// the settings it saves are picked up when it closes.
    func calibrate() {
        guard !isCalibrating, let python = Self.python() else { return }
        resumeAfterCalibration = isOn
        stop()
        let process = Self.helperProcess(python, ["-m", "camrelay", "--calibrate", "-c", String(cameraIndex)])
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.calibration = nil
                self.isCalibrating = false
                self.send(["cmd": "reload"])
                if self.resumeAfterCalibration { self.start() }
                self.onChange?()
            }
        }
        do {
            try process.run()
            calibration = process
            isCalibrating = true
            log("eye camera: calibrating")
        } catch {
            state = .error("couldn't open calibration: \(error.localizedDescription)")
        }
        onChange?()
    }

    /// Stops the camera and the helper (when RubberMAC quits).
    func shutdown() {
        guard let helper else { return }
        quitting = true
        send(["cmd": "quit"])
        try? input?.close()
        let deadline = Date().addingTimeInterval(2)
        while helper.isRunning && Date() < deadline { usleep(50_000) }
        if helper.isRunning { helper.terminate() }
    }

    // MARK: Helper process

    private static func helperProcess(_ python: URL, _ arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = python
        process.arguments = arguments
        // Not the home folder: there a ~/camrelay project folder would shadow the installed package.
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONSAFEPATH"] = "1"
        process.environment = environment
        return process
    }

    private func launch() -> Bool {
        if helper?.isRunning == true { return true }
        guard let python = Self.python() else {
            state = .error("camrelay isn't installed")
            return false
        }
        let process = Self.helperProcess(python, ["-m", "camrelay", "--control"])
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.received(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.receivedError(String(decoding: data, as: UTF8.self)) }
        }
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async { self?.exited(process) }
        }
        do {
            try process.run()
        } catch {
            state = .error("couldn't start camrelay: \(error.localizedDescription)")
            log("eye camera: couldn't start \(python.path): \(error)")
            return false
        }
        helper = process
        input = stdin.fileHandleForWriting
        quitting = false
        stderrTail = []
        log("eye camera: started camrelay helper with \(python.path)")
        return true
    }

    @discardableResult
    private func send(_ command: [String: Any]) -> Bool {
        guard launch(), let input,
              var data = try? JSONSerialization.data(withJSONObject: command) else { return false }
        data.append(0x0A)
        do {
            try input.write(contentsOf: data)
            return true
        } catch {
            log("eye camera: couldn't send \(command["cmd"] ?? "?"): \(error)")
            return false
        }
    }

    private func received(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            if let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                handle(event)
            }
        }
        onChange?()
    }

    /// Applies one event from the helper. Internal so the self-test can feed it.
    func handle(_ event: [String: Any]) {
        switch event["event"] as? String {
        case "settings":
            if let value = event["color"] as? String { color = value }
            if let value = event["strength"] as? NSNumber { strength = value.doubleValue }
            if let value = event["camera"] as? NSNumber { cameraIndex = value.intValue }
            if let value = event["colors"] as? [String], !value.isEmpty { colors = value }
        case "cameras":
            let list = event["cameras"] as? [[String: Any]] ?? []
            cameras = list.compactMap { entry in
                guard let index = entry["index"] as? NSNumber, let name = entry["name"] as? String else { return nil }
                return Camera(index: index.intValue, name: name, virtual: (entry["virtual"] as? Bool) ?? false)
            }
        case "state":
            device = event["device"] as? String
            fps = (event["fps"] as? NSNumber)?.intValue ?? 0
            switch event["state"] as? String {
            case "on": state = .on
            case "starting": state = .starting
            case "error": state = .error((event["error"] as? String) ?? "unknown error")
            default: state = .off
            }
            if case .error(let message) = state { log("eye camera: \(message)") }
        case "error":
            log("eye camera: helper said: \(event["message"] as? String ?? "?")")
        default:
            break
        }
    }

    private func receivedError(_ text: String) {
        for line in text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            stderrTail.append(String(line))
        }
        if stderrTail.count > 20 { stderrTail.removeFirst(stderrTail.count - 20) }
    }

    private func exited(_ process: Process) {
        guard process === helper else { return }
        helper = nil
        input = nil
        buffer.removeAll()
        if quitting {
            state = .off
        } else if stderrTail.contains(where: { $0.contains("unrecognized arguments: --control") }) {
            state = .error(Self.outdatedMessage)
        } else {
            let detail = stderrTail.last ?? "exit code \(process.terminationStatus)"
            state = .error("camrelay stopped: \(detail)")
            log("eye camera: helper exited (\(process.terminationStatus)); last output:\n\(stderrTail.joined(separator: "\n"))")
        }
        onChange?()
    }

    // MARK: Self-test

    /// --selftest eyecamera: finds camrelay, starts the helper, reads its first events and quits it.
    static func selfTestReport() -> String {
        var lines = ["eye camera self-test"]
        guard let python = python() else {
            return (lines + ["camrelay: not found (no camrelay.app launcher, no ~/camrelay/.venv)"]).joined(separator: "\n")
        }
        lines.append("python: \(python.path)")
        let process = helperProcess(python, ["-m", "camrelay", "--control"])
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        do { try process.run() } catch { return (lines + ["start failed: \(error)"]).joined(separator: "\n") }
        try? stdin.fileHandleForWriting.write(contentsOf: Data("{\"cmd\": \"quit\"}\n".utf8))
        try? stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errors = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let camera = EyeCamera()
        for line in output.split(separator: 0x0A) {
            if let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] { camera.handle(event) }
        }
        lines.append("exit: \(process.terminationStatus)")
        lines.append("settings: \(camera.color) at \(Int((camera.strength * 100).rounded()))%, camera \(camera.cameraIndex)")
        lines.append("cameras: " + camera.cameras.map { "[\($0.index)] \($0.name)\($0.virtual ? " (virtual)" : "")" }
            .joined(separator: ", "))
        lines.append("state: \(camera.statusLine)")
        let errorText = String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if errorText.contains("unrecognized arguments: --control") { lines.append(outdatedMessage) }
        if !errorText.isEmpty { lines.append("stderr:\n" + errorText.split(separator: "\n").suffix(10).joined(separator: "\n")) }
        let ok = process.terminationStatus == 0 && !camera.cameras.isEmpty
        lines.append(ok ? "PASS" : "FAIL")
        return lines.joined(separator: "\n")
    }
}
