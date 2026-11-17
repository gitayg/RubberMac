import AppKit

extension AppDelegate {
    // Rows on the Keyboard page, right under "⌘ Alone Opens Apps".
    func startMenuRows(_ facts: SettingsFacts) -> [SettingsRow] {
        [toggle("⌘ Alone Opens RubberMAC's Start, Not Spotlight's Apps", #selector(toggleStartMenu), on: Settings.startMenuEnabled,
                note: "Your own order, folders and pins; right-click an app to remove it")]
    }

    @objc func toggleStartMenu() {
        Settings.startMenuEnabled.toggle()
        if !Settings.startMenuEnabled { StartMenu.shared.close() }
    }
}

extension Settings {
    static let startMenuKey = "startMenuEnabled"

    // On unless turned off.
    static var startMenuEnabled: Bool {
        get { startMenuEnabled(in: .standard) }
        set { UserDefaults.standard.set(newValue, forKey: startMenuKey) }
    }

    static func startMenuEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: startMenuKey) as? Bool ?? true
    }
}
