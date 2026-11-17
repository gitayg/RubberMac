import AppKit

extension Settings {
    // Off until chosen: they change how every wheel scrolls.
    static var wheelClassicEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "wheelClassicEnabled") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "wheelClassicEnabled") }
    }

    static var wheelSteadyEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "wheelSteadyEnabled") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "wheelSteadyEnabled") }
    }

    // On: ⌘ + wheel did nothing before, and it only zooms where an app has its own Zoom In.
    static var wheelZoomEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "wheelZoomEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "wheelZoomEnabled") }
    }
}

extension WheelStyle {
    struct Switches: Equatable {
        var classic: Bool
        var steady: Bool
        var zoom: Bool

        var any: Bool { classic || steady || zoom }

        static var stored: Switches {
            Switches(classic: Settings.wheelClassicEnabled, steady: Settings.wheelSteadyEnabled, zoom: Settings.wheelZoomEnabled)
        }
    }

    static let classicTitle = "Wheel Scrolls the Classic Way"
    static let classicNote = "The trackpad keeps natural scrolling"
    static let alreadyClassicNote = "Natural scrolling is off in System Settings, so the wheel already scrolls the classic way"
    static let steadyTitle = "Steady Wheel Scrolling, as on Windows"
    static let steadyNote = "Each notch scrolls the same distance, \(WheelNotch.lines) lines, however fast it turns"
    static let zoomTitle = "⌘ + Wheel Zooms In and Out"
    static let zoomNote = "Makes text bigger or smaller in apps that can zoom, as Ctrl + wheel does on Windows"

    // System Settings' Natural scrolling, one switch for the trackpad and the mouse, on unless turned off.
    static func naturalScrolling() -> Bool {
        UserDefaults.standard.object(forKey: "com.apple.swipescrolldirection") as? Bool ?? true
    }
}

extension AppDelegate {
    // Rows on the Mouse page, in the section under the mice, before the hold-the-wheel switch.
    func wheelStyleRows(_ facts: SettingsFacts) -> [SettingsRow] {
        wheelStyleRows(facts, on: .stored, natural: WheelStyle.naturalScrolling())
    }

    // With Natural scrolling off the wheel already scrolls the classic way, so the switch would do nothing until it's
    // turned on; the note says so, and the switch stays, ready for then.
    func wheelStyleRows(_ facts: SettingsFacts, on: WheelStyle.Switches, natural: Bool) -> [SettingsRow] {
        [
            accessToggle(WheelStyle.classicTitle, #selector(toggleWheelClassic), on: on.classic, facts,
                         note: natural ? WheelStyle.classicNote : WheelStyle.alreadyClassicNote),
            accessToggle(WheelStyle.steadyTitle, #selector(toggleWheelSteady), on: on.steady, facts, note: WheelStyle.steadyNote),
            accessToggle(WheelStyle.zoomTitle, #selector(toggleWheelZoom), on: on.zoom, facts, note: WheelStyle.zoomNote),
        ]
    }

    @objc func toggleWheelClassic() {
        Settings.wheelClassicEnabled.toggle()
        wheelStyleChanged()
    }

    @objc func toggleWheelSteady() {
        Settings.wheelSteadyEnabled.toggle()
        wheelStyleChanged()
    }

    @objc func toggleWheelZoom() {
        Settings.wheelZoomEnabled.toggle()
        wheelStyleChanged()
    }

    private func wheelStyleChanged() {
        WheelStyle.shared.apply()
        restartTaps()
        if needsAccess { AX.requestAccess() }
    }
}
