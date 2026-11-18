import AppKit

extension SpotlightFilter {
    static let switchTitle = "Spotlight Searches Only Apps"
    static let switchNote = "Like pressing ⌘1 in the search bar; Esc goes back to searching everything"
}

extension AppDelegate {
    // On the Keyboard page, after the ⌘R and ⌘-alone rows and Start's.
    func spotlightFilterRows(_ facts: SettingsFacts) -> [SettingsRow] {
        [accessToggle(SpotlightFilter.switchTitle, #selector(toggleSpotlightFilter), on: Settings.spotlightAppsOnlyEnabled, facts,
                      note: SpotlightFilter.switchNote)]
    }

    @objc func toggleSpotlightFilter() {
        Settings.spotlightAppsOnlyEnabled.toggle()
        log("spotlight apps only: " + (Settings.spotlightAppsOnlyEnabled ? "on" : "off"))
        SpotlightFilter.shared.apply()
        // The keyboard tap may have to start (or stop) for the keys held during a switch.
        restartTaps()
        if needsAccess { AX.requestAccess() }
    }
}

extension Settings {
    // Off unless turned on: Spotlight finding only apps would surprise anyone who didn't ask for it.
    static var spotlightAppsOnlyEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "spotlightAppsOnlyEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "spotlightAppsOnlyEnabled") }
    }
}
