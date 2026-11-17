import AppKit

extension Settings {
    // The screen the Dock is kept on, keyed by vendor, model and serial as CameraArea keys one; nil leaves it to macOS.
    static var dockScreen: String? {
        get { UserDefaults.standard.string(forKey: "dockScreen") }
        set { UserDefaults.standard.set(newValue, forKey: "dockScreen") }
    }

    // Its name when it was chosen, for the popup while it's not connected.
    static var dockScreenName: String? {
        get { UserDefaults.standard.string(forKey: "dockScreenName") }
        set { UserDefaults.standard.set(newValue, forKey: "dockScreenName") }
    }
}

extension DockScreen {
    static let anyScreen = "Any Screen (as macOS does)"
    static let popupTitle = "Keep the Dock On"
    static let spansNote = "“Displays have separate Spaces” is off in Desktop & Dock, so the Dock stays on the main screen"

    struct Choice: Equatable {
        let title: String
        // nil for Any Screen.
        let key: String?
        let on: Bool
    }

    // Any Screen, then each connected screen; a chosen screen that isn't connected stays listed, as chosen.
    static func choices(_ displays: [Display], chosen: String?, chosenName: String?) -> [Choice] {
        var list = [Choice(title: anyScreen, key: nil, on: chosen == nil)]
        list += displays.map { Choice(title: $0.name, key: $0.key, on: $0.key == chosen) }
        if let chosen, !displays.contains(where: { $0.key == chosen }) {
            list.append(Choice(title: "\(chosenName ?? "The Chosen Screen") (not connected)", key: chosen, on: true))
        }
        return list
    }
}

extension AppDelegate {
    // Rows added at the end of the Windows page's Dock section.
    func dockScreenRows(_ facts: SettingsFacts) -> [SettingsRow] {
        dockScreenRows(facts, displays: DockScreen.connectedDisplays(), chosen: Settings.dockScreen, chosenName: Settings.dockScreenName,
                       spansDisplays: DockScreenDock.spansDisplays)
    }

    func dockScreenRows(_ facts: SettingsFacts, displays: [DockScreen.Display], chosen: String?, chosenName: String?,
                        spansDisplays: Bool) -> [SettingsRow] {
        let choices = DockScreen.choices(displays, chosen: chosen, chosenName: chosenName)
        var items = choices.map { choice in
            let item = action(choice.title, #selector(setDockScreen(_:)), on: choice.on)
            item.representedObject = choice.key
            return item
        }
        items.insert(.separator(), at: 1)
        // Choosing a screen without Accessibility brings up macOS's question, so the panel gets out of the way.
        var rows = [popup(DockScreen.popupTitle, items, closes: !facts.permissions.accessibility)]
        if spansDisplays { rows.append(.note(DockScreen.spansNote)) }
        return rows
    }

    @objc func setDockScreen(_ sender: NSMenuItem) {
        let key = sender.representedObject as? String
        guard key != Settings.dockScreen else { return }
        Settings.dockScreen = key
        Settings.dockScreenName = key.flatMap { key in DockScreen.connectedDisplays().first { $0.key == key }?.name }
        log("dock screen: " + (key == nil ? "any screen" : "kept on \(Settings.dockScreenName ?? "a screen")"))
        DockScreen.shared.choiceChanged()
        if needsAccess { AX.requestAccess() }
    }
}
