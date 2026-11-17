import AppKit

// Part of --selftest resolution: the question on made-up screens, never shown, and drawn into pictures; and the rows,
// on made-up screens and on this Mac's real one, with the Brightness page drawn as the panel shows it.
extension ScreenResolution {
    // MARK: The question

    static func questionChecks(_ check: Check, _ note: (String) -> Void) {
        let question = ScreenResolutionQuestion(display: 5, name: "LG ULTRAWIDE", chosen: "1920 × 1080, 60 Hz", previous: "3440 × 1440, 100 Hz (native)",
                                                secondsLeft: 15)
        check(question.title(onChangedScreen: true) == "Keep this resolution?" && question.title(onChangedScreen: false) == "Keep the new resolution on LG ULTRAWIDE?",
              "the question: \"Keep this resolution?\" on the screen, naming it on the others")
        check(question.body == "LG ULTRAWIDE is at 1920 × 1080, 60 Hz. Going back to 3440 × 1440, 100 Hz (native) in 15 seconds."
              && ScreenResolutionQuestion(display: 5, name: "A", chosen: "B", previous: "C", secondsLeft: 1).body.hasSuffix("in 1 second."),
              "and what happens next: \(question.body)")

        let windows = ScreenResolutionWindows()
        var presented: [(CGDirectDisplayID, Bool)] = []
        var screens: [(id: CGDirectDisplayID, visible: NSRect)] = [(5, NSRect(x: 0, y: 0, width: 3440, height: 1415)), (7, NSRect(x: 3440, y: 0, width: 1920, height: 1055))]
        windows.screens = { screens }
        windows.present = { panel, key in presented.append((windows.panels.first { $0.value === panel }?.key ?? 0, key)) }
        var answers: [String] = []
        windows.onKeep = { answers.append("keep") }
        windows.onGoBack = { answers.append("go back") }
        windows.show(question)
        check(Set(windows.panels.keys) == [5, 7] && presented.filter(\.1).map(\.0) == [5],
              "it's on every screen, and the changed screen's takes the keyboard (\(presented.map { "\($0.0)\($0.1 ? " key" : "")" }.joined(separator: ", ")))")
        let onChanged = windows.panels[5]!, onOther = windows.panels[7]!
        check(onChanged.question.title.stringValue == "Keep this resolution?" && onOther.question.title.stringValue == "Keep the new resolution on LG ULTRAWIDE?",
              "each says which screen it means")
        check(NSRect(x: 0, y: 0, width: 3440, height: 1415).contains(onChanged.frame) && abs(onChanged.frame.midX - 1720) <= 1
              && NSRect(x: 3440, y: 0, width: 1920, height: 1055).contains(onOther.frame),
              "each sits across the middle of its own screen (\(Int(onChanged.frame.minX)),\(Int(onChanged.frame.minY)) and \(Int(onOther.frame.minX)),\(Int(onOther.frame.minY)))")
        presented = []
        screens = [(5, NSRect(x: 0, y: 0, width: 1920, height: 1055))]
        windows.show(ScreenResolutionQuestion(display: 5, name: "LG ULTRAWIDE", chosen: "1920 × 1080, 60 Hz", previous: "3440 × 1440, 100 Hz (native)", secondsLeft: 9))
        check(Set(windows.panels.keys) == [5] && NSRect(x: 0, y: 0, width: 1920, height: 1055).contains(onChanged.frame)
              && onChanged.question.body.stringValue.hasSuffix("in 9 seconds.") && presented.allSatisfy { !$0.1 },
              "a tick after the other screen went and this one shrank: its window gone, this one moved and counting, the keyboard left where it is")
        onChanged.question.keep.performClick(nil)
        onChanged.question.goBack.performClick(nil)
        onChanged.cancelOperation(nil)
        check(answers == ["keep", "go back", "go back"], "Keep and Go Back answer, and Esc is Go Back (\(answers.joined(separator: ", ")))")
        check(onChanged.question.goBack.keyEquivalent == "\r" && onChanged.question.keep.keyEquivalent.isEmpty,
              "↩ is Go Back, the safe guess on a screen that shows nothing; Keep takes a click")
        check(onChanged.level > ScreenOverlay.brightnessLevel && onChanged.collectionBehavior.contains(.canJoinAllSpaces)
              && onChanged.collectionBehavior.contains(.fullScreenAuxiliary) && onChanged.canBecomeKey && !onChanged.hidesOnDeactivate,
              "above RubberMAC's software dimming, on every Space and over full-screen apps, and it takes the keyboard (level \(onChanged.level.rawValue))")
        check(!onChanged.isVisible && !onOther.isVisible, "nothing was put on the screen")
        windows.hide()
        check(windows.panels.isEmpty, "put away, nothing is left")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("resolution-selftest")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let view = ScreenResolutionQuestionView()
        view.show(question, onChangedScreen: true)
        for (look, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            view.appearance = NSAppearance(named: appearance)
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { check(false, "the question drawn, \(look)"); continue }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let colours = Set(stride(from: 0, to: bitmap.pixelsWide, by: 2).flatMap { x in
                stride(from: 0, to: bitmap.pixelsHigh, by: 2).compactMap { bitmap.colorAt(x: x, y: $0) }
            }.map { [$0.redComponent, $0.greenComponent, $0.blueComponent].map { Int($0 * 16) } })
            let url = folder.appendingPathComponent("resolution-question-\(look).png")
            try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
            let corner = bitmap.colorAt(x: 2, y: 2)?.usingColorSpace(.deviceRGB)?.brightnessComponent ?? -1
            check(colours.count > 12 && view.bounds.height > 80 && (look == "light" ? corner > 0.8 : corner >= 0 && corner < 0.3),
                  "the question drawn, \(look): \(Int(view.bounds.width)) × \(Int(view.bounds.height)), \(colours.count) colours, background brightness "
                  + String(format: "%.2f", corner))
            note("picture: \(url.path)")
        }
    }

    // MARK: The rows

    static func settingsChecks(_ check: Check, _ note: (String) -> Void) {
        let delegate = AppDelegate(lockWarning: LockWarning(timeoutOverride: nil))
        var facts = SettingsFacts()
        facts.displays = [Brightness.Display(id: 5, name: "LG ULTRAWIDE", hardware: true), Brightness.Display(id: 7, name: "DELL U2723QE", hardware: true),
                          Brightness.Display(id: 9, name: "Sidecar", hardware: false)]
        let readings: [CGDirectDisplayID: Reading] = [5: Reading(modes: wide, current: wide[0]), 7: Reading(modes: side, current: side[1])]
        let sections = delegate.screenResolutionSections(facts) { readings[$0] ?? Reading(modes: [], current: nil) }
        let rows = sections.first?.rows ?? []
        check(sections.count == 1 && sections[0].title == "Resolution" && rows.map(\.title) == ["LG ULTRAWIDE", "DELL U2723QE", ScreenResolution.note]
              && rows.last?.isNote == true, "a Resolution card: a popup per screen that lists modes, then the note (\(rows.map(\.title).joined(separator: " | ")))")
        var items: [NSMenuItem] = []
        if case .popup(let list)? = rows.first?.control { items = list }
        check(items.map { $0.isSeparatorItem ? "-" : $0.title } == ["3440 × 1440, 100 Hz (native)", "3440 × 1440, 60 Hz (native)", "-",
                                                                     "1920 × 1080, 120 Hz", "1920 × 1080, 60 Hz", "-", "1280 × 720, 60 Hz"],
              "its items, a line between groups: \(items.map { $0.isSeparatorItem ? "-" : $0.title }.joined(separator: " | "))")
        check(items.filter { $0.state == .on }.map(\.title) == ["3440 × 1440, 100 Hz (native)"], "the mode in use is ticked")
        let picks = items.compactMap { $0.representedObject as? Pick }
        check(picks.count == 5 && picks.allSatisfy { $0.display == 5 && $0.name == "LG ULTRAWIDE" } && picks.map(\.mode.id) == [51, 52, 42, 44, 15],
              "each item carries its screen and mode")
        check(items.filter { !$0.isSeparatorItem }.allSatisfy { $0.target === delegate && $0.action == #selector(AppDelegate.setScreenResolution(_:)) }
              && delegate.responds(to: #selector(AppDelegate.setScreenResolution(_:))), "and reaches setScreenResolution(_:) (not chosen)")
        check(rows.dropLast().allSatisfy(\.closesPanel), "choosing closes the panel, as the question comes up and the screen may change size")
        check(delegate.screenResolutionSections(SettingsFacts()) { _ in Reading(modes: wide, current: wide[0]) }.isEmpty,
              "no screens, no card")

        // The real page, on this Mac's real screens.
        var real = SettingsFacts()
        real.displays = NSScreen.screens.compactMap { screen in screen.displayID.map { Brightness.Display(id: $0, name: screen.localizedName, hardware: true) } }
        let page = delegate.settingsPages(real).first { $0.id == "brightness" }
        let titles = page?.sections.map { $0.title ?? "-" } ?? []
        let sliders = page?.sections.first?.rows.allSatisfy { if case .custom = $0.control { true } else { false } } == true
        check(titles.count > 1 && titles[1] == "Resolution" && sliders, "on the Brightness page right after the brightness sliders (cards: \(titles.joined(separator: " | ")))")
        let realItems = page?.sections[1].rows.compactMap { row -> [NSMenuItem]? in if case .popup(let list) = row.control { list } else { nil } } ?? []
        let ticked = realItems.map { $0.filter { $0.state == .on }.count }
        check(realItems.count == real.displays.count && ticked.allSatisfy { $0 == 1 }, "one popup per real screen, each with one mode ticked")

        // As the panel shows it, in a window never put on screen.
        let panel = SettingsPanel()
        panel.pages = { [unowned delegate] in delegate.settingsPages(real) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: SettingsPanel.size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = panel.root
        panel.choose("brightness")
        panel.root.layoutSubtreeIfNeeded()
        func popups(_ view: NSView) -> [NSPopUpButton] { (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap(popups) }
        let selected = popups(panel.detail).compactMap(\.titleOfSelectedItem)
        let inUse = real.displays.compactMap { display in reading(display.id).current.map { title(of: $0, among: reading(display.id).modes) } }
        check(!selected.isEmpty && inUse.allSatisfy(selected.contains), "the panel's popup shows the mode in use: \(selected.joined(separator: ", "))")
        if let bitmap = panel.detail.bitmapImageRepForCachingDisplay(in: panel.detail.bounds) {
            panel.detail.cacheDisplay(in: panel.detail.bounds, to: bitmap)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("resolution-selftest/brightness-page.png")
            try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
            note("picture: \(url.path)")
        }
        window.contentView = nil
    }
}
