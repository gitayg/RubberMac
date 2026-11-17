import AppKit

extension OpenOnScreen {
    static let sectionTitle = "New Windows"
    static let switchTitle = "Open Apps and Files on the Screen You're Using"
    static let switchNote = "A window that opens on another screen moves to the one with the pointer"
    static let addTitle = "Always Open an App on One Screen"
    static let addButton = "Add App…"
    static let noApps = "Every Running App Has a Screen"
    static let removeItem = "Remove"

    static func ruleTitle(_ rule: OpenOnScreenRule) -> String { "\(rule.appName) Always Opens On" }
}

extension AppDelegate {
    // Sections on the Windows page, after the Lost Windows sections.
    func openOnScreenSections(_ facts: SettingsFacts) -> [SettingsSection] {
        openOnScreenSections(facts, on: Settings.openOnScreenEnabled, rules: Settings.openOnScreenRules, displays: DockScreen.connectedDisplays())
    }

    func openOnScreenSections(_ facts: SettingsFacts, on: Bool, rules: [OpenOnScreenRule], displays: [DockScreen.Display]) -> [SettingsSection] {
        var rows = [accessToggle(OpenOnScreen.switchTitle, #selector(toggleOpenOnScreen), on: on, facts, note: OpenOnScreen.switchNote)]
        for rule in rules {
            // Each screen's item carries the rule as it would be with that screen.
            var items = rule.choices(displays).map { choice in
                let item = action(choice.title, #selector(setOpenOnScreenRuleScreen(_:)), on: choice.on)
                var changed = rule
                changed.screen = choice.key
                if choice.key != rule.screen { changed.screenName = choice.title }
                item.representedObject = changed
                return item
            }
            let remove = action(OpenOnScreen.removeItem, #selector(removeOpenOnScreenRule(_:)))
            remove.representedObject = rule
            items += [.separator(), remove]
            // Choosing a screen without Accessibility brings up macOS's question, so the panel gets out of the way.
            rows.append(popup(OpenOnScreen.ruleTitle(rule), items, closes: !facts.permissions.accessibility))
        }
        // The apps are listed when the button is clicked, so the list is the one running then.
        rows.append(button(OpenOnScreen.addTitle, OpenOnScreen.addButton, #selector(showOpenOnScreenApps(_:))))
        return [SettingsSection(title: OpenOnScreen.sectionTitle, rows: rows)]
    }

    // The running apps that don't have a screen yet, by name.
    func openOnScreenAppsMenu(_ apps: [OpenOnScreen.App], rules: [OpenOnScreenRule]) -> NSMenu {
        let menu = NSMenu()
        let ruled = Set(rules.map(\.app))
        for app in apps where !ruled.contains(app.bundleID) {
            let item = action(app.name, #selector(addOpenOnScreenRule(_:)))
            item.representedObject = app
            menu.addItem(item)
        }
        if menu.items.isEmpty { menu.addItem(infoItem(OpenOnScreen.noApps)) }
        return menu
    }

    @objc func toggleOpenOnScreen() {
        Settings.openOnScreenEnabled.toggle()
        log("open on screen: " + (Settings.openOnScreenEnabled ? "on" : "off"))
        OpenOnScreen.shared.apply()
        if needsAccess { AX.requestAccess() }
    }

    @objc func showOpenOnScreenApps(_ sender: NSButton) {
        openOnScreenAppsMenu(OpenOnScreen.runningApps(), rules: Settings.openOnScreenRules)
            .popUp(positioning: nil, at: NSPoint(x: 0, y: sender.isFlipped ? sender.bounds.maxY : 0), in: sender)
    }

    // Starts on the screen with the pointer, the one the panel is open on.
    @objc func addOpenOnScreenRule(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? OpenOnScreen.App else { return }
        let screens = OpenOnScreenPlan.connectedScreens()
        guard let index = OpenOnScreenPlan.screen(at: OpenOnScreenPlan.pointer(), screens) else { return }
        Settings.openOnScreenRules.append(OpenOnScreenRule(app: app.bundleID, appName: app.name, screen: screens[index].key,
                                                           screenName: screens[index].name))
        log("open on screen: \(app.name) always opens on \(screens[index].name)")
        OpenOnScreen.shared.apply()
        // macOS's question comes up over the panel, so the panel gets out of the way.
        if needsAccess {
            settingsPanel.close()
            AX.requestAccess()
        }
    }

    @objc func setOpenOnScreenRuleScreen(_ sender: NSMenuItem) {
        guard let changed = sender.representedObject as? OpenOnScreenRule else { return }
        var rules = Settings.openOnScreenRules
        guard let index = rules.firstIndex(where: { $0.app == changed.app }), rules[index] != changed else { return }
        rules[index] = changed
        Settings.openOnScreenRules = rules
        log("open on screen: \(changed.appName) always opens on \(changed.screenName)")
        OpenOnScreen.shared.apply()
        if needsAccess { AX.requestAccess() }
    }

    @objc func removeOpenOnScreenRule(_ sender: NSMenuItem) {
        guard let removed = sender.representedObject as? OpenOnScreenRule else { return }
        Settings.openOnScreenRules.removeAll { $0.app == removed.app }
        log("open on screen: \(removed.appName) no longer has a screen of its own")
        OpenOnScreen.shared.apply()
    }
}
