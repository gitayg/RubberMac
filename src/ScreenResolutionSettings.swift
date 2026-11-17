import AppKit

extension AppDelegate {
    // Sections on the Brightness page, right after the brightness sliders.
    func screenResolutionSections(_ facts: SettingsFacts) -> [SettingsSection] {
        screenResolutionSections(facts, read: ScreenResolution.reading)
    }

    // A popup per screen, its groups apart; a screen that lists no modes gets none. Choosing brings up the question,
    // and the screen may change size under the panel, so the panel gets out of the way.
    func screenResolutionSections(_ facts: SettingsFacts, read: (CGDirectDisplayID) -> ScreenResolution.Reading) -> [SettingsSection] {
        let rows = facts.displays.compactMap { display -> SettingsRow? in
            let reading = read(display.id)
            var items: [NSMenuItem] = []
            for group in ScreenResolution.menu(reading.modes, current: reading.current) {
                if !items.isEmpty { items.append(.separator()) }
                items += group.map { entry in
                    let item = action(entry.title, #selector(setScreenResolution(_:)), on: entry.current)
                    item.representedObject = ScreenResolution.Pick(display: display.id, name: display.name, mode: entry.mode)
                    return item
                }
            }
            return items.isEmpty ? nil : popup(display.name, items, closes: true)
        }
        guard !rows.isEmpty else { return [] }
        return [SettingsSection(title: "Resolution", rows: rows + [.note(ScreenResolution.note)])]
    }

    @objc func setScreenResolution(_ sender: NSMenuItem) {
        guard let pick = sender.representedObject as? ScreenResolution.Pick else { return }
        ScreenResolution.shared.choose(pick)
    }
}
