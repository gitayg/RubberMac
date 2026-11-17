import AppKit

extension Settings {
    static var inputPerAppEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "inputPerAppEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "inputPerAppEnabled") }
    }

    static var inputSearchEnglishEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "inputSearchEnglishEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "inputSearchEnglishEnabled") }
    }
}

extension AppDelegate {
    // Rows on the Keyboard page, right under "Left Alt-Shift Switches Language".
    func inputPerAppRows(_ facts: SettingsFacts) -> [SettingsRow] {
        [
            toggle("Each App Keeps Its Own Language", #selector(toggleInputPerApp), on: Settings.inputPerAppEnabled,
                   note: "Switch in an app and it's that app's language next time too"),
            // Spotlight's own shortcut is seen in the keyboard tap.
            accessToggle("Spotlight and Start Open in English", #selector(toggleInputSearchEnglish), on: Settings.inputSearchEnglishEnabled,
                         facts, note: "Search starts in English; the app gets its language back after"),
        ]
    }

    @objc func toggleInputPerApp() {
        Settings.inputPerAppEnabled.toggle()
        InputPerApp.shared.apply()
    }

    @objc func toggleInputSearchEnglish() {
        Settings.inputSearchEnglishEnabled.toggle()
        InputPerApp.shared.apply()
        restartTaps()
        if needsAccess { AX.requestAccess() }
    }
}
