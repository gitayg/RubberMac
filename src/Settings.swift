import CoreGraphics
import Foundation

enum SnapKeys: String, CaseIterable {
    case command, controlOption

    var title: String {
        switch self {
        case .command: return "⌘ + arrows  (Windows key + arrow)"
        case .controlOption: return "⌃⌥ + arrows"
        }
    }
}

enum AltTabMode: String, CaseIterable {
    case windows, apps, off

    var title: String {
        switch self {
        case .windows: return "Switch Windows (like Windows)"
        case .apps: return "Switch Apps (macOS switcher)"
        case .off: return "Off"
        }
    }
}

enum Settings {
    static let warnSecondsChoices = [5, 10, 15, 20, 30, 45, 60]
    static let snapGridChoices = (2...4).flatMap { columns in (1...3).map { SnapGrid(columns: columns, rows: $0) } }

    private static let defaults = UserDefaults.standard

    static func register() {
        defaults.register(defaults: [
            "warnEnabled": true,
            "warnSeconds": 15,
            "dimEnabled": true,
            "snapEnabled": true,
            "snapKeys": SnapKeys.command.rawValue,
            "snapColumns": SnapGrid.standard.columns,
            "snapRows": SnapGrid.standard.rows,
            "altTabMode": AltTabMode.apps.rawValue,
            "layoutsEnabled": true,
            "brightnessKeysEnabled": true,
            "clipboardKeysEnabled": true,
            "textNavEnabled": true,
            "minimizeAllEnabled": true,
            "inputSwitchEnabled": true,
            "wheelSpeed": 1.0,
            "wheelDragScrollEnabled": true,
            "autoUpdate": true,
            "writingPadEnabled": true,
            "finderPathPasteEnabled": true,
            "commandTabWindows": true,
            "fullScreenDockEnabled": true,
            "finderAddressBarEnabled": true,
            "dockWindowMenuEnabled": true,
            "eyeCameraAtLaunch": false,
        ])
        // 1.2.0 stored an on/off flag; keep a user's "off".
        if defaults.object(forKey: "altTabEnabled") != nil {
            if !defaults.bool(forKey: "altTabEnabled") { altTabMode = .off }
            defaults.removeObject(forKey: "altTabEnabled")
        }
    }

    static var warnEnabled: Bool {
        get { defaults.bool(forKey: "warnEnabled") }
        set { defaults.set(newValue, forKey: "warnEnabled") }
    }

    static var warnSeconds: Int {
        get { defaults.integer(forKey: "warnSeconds") }
        set { defaults.set(newValue, forKey: "warnSeconds") }
    }

    static var dimEnabled: Bool {
        get { defaults.bool(forKey: "dimEnabled") }
        set { defaults.set(newValue, forKey: "dimEnabled") }
    }

    static var snapEnabled: Bool {
        get { defaults.bool(forKey: "snapEnabled") }
        set { defaults.set(newValue, forKey: "snapEnabled") }
    }

    static var snapKeys: SnapKeys {
        get { SnapKeys(rawValue: defaults.string(forKey: "snapKeys") ?? "") ?? .command }
        set { defaults.set(newValue.rawValue, forKey: "snapKeys") }
    }

    static var snapGrid: SnapGrid {
        get {
            let grid = SnapGrid(columns: defaults.integer(forKey: "snapColumns"), rows: defaults.integer(forKey: "snapRows"))
            return snapGridChoices.contains(grid) ? grid : .standard
        }
        set {
            defaults.set(newValue.columns, forKey: "snapColumns")
            defaults.set(newValue.rows, forKey: "snapRows")
        }
    }

    static var altTabMode: AltTabMode {
        get { AltTabMode(rawValue: defaults.string(forKey: "altTabMode") ?? "") ?? .apps }
        set { defaults.set(newValue.rawValue, forKey: "altTabMode") }
    }

    static var layoutsEnabled: Bool {
        get { defaults.bool(forKey: "layoutsEnabled") }
        set { defaults.set(newValue, forKey: "layoutsEnabled") }
    }

    static var clipboardKeysEnabled: Bool {
        get { defaults.bool(forKey: "clipboardKeysEnabled") }
        set { defaults.set(newValue, forKey: "clipboardKeysEnabled") }
    }

    static var textNavEnabled: Bool {
        get { defaults.bool(forKey: "textNavEnabled") }
        set { defaults.set(newValue, forKey: "textNavEnabled") }
    }

    static var minimizeAllEnabled: Bool {
        get { defaults.bool(forKey: "minimizeAllEnabled") }
        set { defaults.set(newValue, forKey: "minimizeAllEnabled") }
    }

    static var inputSwitchEnabled: Bool {
        get { defaults.bool(forKey: "inputSwitchEnabled") }
        set { defaults.set(newValue, forKey: "inputSwitchEnabled") }
    }

    static var wheelSpeed: Double {
        get { defaults.double(forKey: "wheelSpeed") }
        set { defaults.set(newValue, forKey: "wheelSpeed") }
    }

    // Per mouse model, by its product name.
    static var pointerSpeeds: [String: Double] {
        get { defaults.dictionary(forKey: "pointerSpeeds") as? [String: Double] ?? [:] }
        set { defaults.set(newValue, forKey: "pointerSpeeds") }
    }

    static var wheelSpeeds: [String: Double] {
        get { defaults.dictionary(forKey: "wheelSpeeds") as? [String: Double] ?? [:] }
        set { defaults.set(newValue, forKey: "wheelSpeeds") }
    }

    static var wheelDragScrollEnabled: Bool {
        get { defaults.bool(forKey: "wheelDragScrollEnabled") }
        set { defaults.set(newValue, forKey: "wheelDragScrollEnabled") }
    }

    static var autoUpdate: Bool {
        get { defaults.bool(forKey: "autoUpdate") }
        set { defaults.set(newValue, forKey: "autoUpdate") }
    }

    static var brightnessKeysEnabled: Bool {
        get { defaults.bool(forKey: "brightnessKeysEnabled") }
        set { defaults.set(newValue, forKey: "brightnessKeysEnabled") }
    }

    static var writingPadEnabled: Bool {
        get { defaults.bool(forKey: "writingPadEnabled") }
        set { defaults.set(newValue, forKey: "writingPadEnabled") }
    }

    static var commandTabWindows: Bool {
        get { defaults.bool(forKey: "commandTabWindows") }
        set { defaults.set(newValue, forKey: "commandTabWindows") }
    }

    static var finderPathPasteEnabled: Bool {
        get { defaults.bool(forKey: "finderPathPasteEnabled") }
        set { defaults.set(newValue, forKey: "finderPathPasteEnabled") }
    }

    static var finderAddressBarEnabled: Bool {
        get { defaults.bool(forKey: "finderAddressBarEnabled") }
        set { defaults.set(newValue, forKey: "finderAddressBarEnabled") }
    }

    // Whether RubberMAC has asked for Screen Recording yet: it asks by itself only once.
    static var screenRecordingAsked: Bool {
        get { defaults.bool(forKey: "screenRecordingAsked") }
        set { defaults.set(newValue, forKey: "screenRecordingAsked") }
    }

    static var fullScreenDockEnabled: Bool {
        get { defaults.bool(forKey: "fullScreenDockEnabled") }
        set { defaults.set(newValue, forKey: "fullScreenDockEnabled") }
    }

    static var dockWindowMenuEnabled: Bool {
        get { defaults.bool(forKey: "dockWindowMenuEnabled") }
        set { defaults.set(newValue, forKey: "dockWindowMenuEnabled") }
    }

    // Window IDs start over at each boot, so a history saved before the last one is dropped.
    static var focusHistory: [CGWindowID] {
        get { focusHistory(from: defaults.dictionary(forKey: "focusHistory"), boot: bootTime) }
        set { defaults.set(["boot": bootTime, "ids": newValue.map { Int($0) }], forKey: "focusHistory") }
    }

    static func focusHistory(from saved: [String: Any]?, boot: Int) -> [CGWindowID] {
        guard let saved, saved["boot"] as? Int == boot else { return [] }
        return (saved["ids"] as? [Int] ?? []).map { CGWindowID($0) }
    }

    static let bootTime: Int = {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &boot, &size, nil, 0)
        return boot.tv_sec
    }()

    static var eyeCameraAtLaunch: Bool {
        get { defaults.bool(forKey: "eyeCameraAtLaunch") }
        set { defaults.set(newValue, forKey: "eyeCameraAtLaunch") }
    }

    static var cameraAvoid: Bool {
        get { defaults.bool(forKey: "cameraAvoid") }
        set { defaults.set(newValue, forKey: "cameraAvoid") }
    }

    static var cameraArea: CameraArea? {
        get { defaults.data(forKey: "cameraArea").flatMap { try? JSONDecoder().decode(CameraArea.self, from: $0) } }
        set { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "cameraArea") }
    }
}
