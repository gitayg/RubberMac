import AppKit

// What happens to the windows behind the one in front.
enum BackgroundDimMode: String, CaseIterable {
    case off, dim, blur

    var title: String {
        switch self {
        case .off: return "Leave As They Are"
        case .dim: return "Dim"
        case .blur: return "Blur"
        }
    }

    // Nothing stored, or something this version doesn't know, is off.
    init(stored: String?) {
        self = stored.flatMap(Self.init(rawValue:)) ?? .off
    }
}

extension Settings {
    // How strong the dimming or the blur is, from 10% to 90%.
    static let backgroundDimRange = 0.1...0.9
    static let backgroundDimDefault = 0.4

    static var backgroundDimMode: BackgroundDimMode {
        get { BackgroundDimMode(stored: UserDefaults.standard.string(forKey: "backgroundDimMode")) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "backgroundDimMode") }
    }

    static var backgroundDimStrength: Double {
        get { backgroundDimStrength(stored: UserDefaults.standard.object(forKey: "backgroundDimStrength") as? Double) }
        set { UserDefaults.standard.set(newValue, forKey: "backgroundDimStrength") }
    }

    static func backgroundDimStrength(stored: Double?) -> Double {
        stored.map { min(max($0, backgroundDimRange.lowerBound), backgroundDimRange.upperBound) } ?? backgroundDimDefault
    }

    // The slider runs 0–1 across the range, in steps of 5%.
    static func backgroundDimStrength(atSlider position: Double) -> Double {
        let range = backgroundDimRange
        return ((range.lowerBound + position * (range.upperBound - range.lowerBound)) * 20).rounded() / 20
    }

    static func backgroundDimSlider(for strength: Double) -> Double {
        let range = backgroundDimRange
        return (strength - range.lowerBound) / (range.upperBound - range.lowerBound)
    }
}

extension AppDelegate {
    // Sections added at the end of the Windows page.
    func backgroundDimSections(_ facts: SettingsFacts) -> [SettingsSection] {
        backgroundDimSections(facts, mode: Settings.backgroundDimMode, strength: Settings.backgroundDimStrength)
    }

    // From the values given rather than the stored ones, so the self-test can build each mode without storing it.
    func backgroundDimSections(_ facts: SettingsFacts, mode: BackgroundDimMode, strength: Double) -> [SettingsSection] {
        let choices = BackgroundDimMode.allCases.enumerated().map { index, choice in
            action(choice.title, #selector(setBackgroundDimMode(_:)), on: choice == mode, tag: index)
        }
        // Without Accessibility, Dim or Blur brings up macOS's question, so the panel gets out of the way.
        var rows = [SettingsRow(title: "Background Windows", note: "So the window you're using stands out; the menu bar and the Dock stay clear",
                                control: .popup(choices), closesPanel: !facts.permissions.accessibility)]
        if mode != .off {
            let slider = ValueSliderView(position: Settings.backgroundDimSlider(for: strength), unavailable: "",
                                         describe: { "Strength  \(Int((Settings.backgroundDimStrength(atSlider: $0) * 100).rounded()))%" },
                                         onChange: {
                                             Settings.backgroundDimStrength = Settings.backgroundDimStrength(atSlider: $0)
                                             BackgroundDimmer.shared.refresh()
                                         })
            rows.append(SettingsRow(title: "Strength", note: nil, control: .custom(slider)))
        }
        return [SettingsSection(title: "Background Windows", rows: rows)]
    }

    @objc func setBackgroundDimMode(_ sender: NSMenuItem) {
        Settings.backgroundDimMode = BackgroundDimMode.allCases[sender.tag]
        BackgroundDimmer.shared.refresh()
        if needsAccess { AX.requestAccess() }
        settingsPanel.reloadIfShown()
    }
}
