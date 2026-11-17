import AppKit

extension Settings {
    // On unless turned off; Settings.register() doesn't know it, so the default is here.
    static var levelOverlayEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "levelOverlayEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "levelOverlayEnabled") }
    }
}

extension AppDelegate {
    // Sections added at the end of the Brightness page.
    func levelOverlaySections(_ facts: SettingsFacts) -> [SettingsSection] {
        [SettingsSection(title: "Volume and Brightness Keys", rows: [
            accessToggle("Show Volume and Brightness on the Screen You're Changing", #selector(toggleLevelOverlay),
                         on: Settings.levelOverlayEnabled, facts, note: "Brightness keys work on external screens too"),
        ])]
    }

    @objc func toggleLevelOverlay() {
        Settings.levelOverlayEnabled.toggle()
        LevelOverlay.shared.update()
        if needsAccess { AX.requestAccess() }
    }
}
