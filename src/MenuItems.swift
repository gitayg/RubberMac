import AppKit

extension NSMenuItem {
    static func action(_ title: String, _ action: Selector, target: AnyObject?, on: Bool = false, tag: Int = 0,
                       enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
        item.target = target
        item.state = on ? .on : .off
        item.tag = tag
        return item
    }

    static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.submenu = NSMenu()
        items.forEach { parent.submenu!.addItem($0) }
        return parent
    }

    static func note(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}

// A menu row with the monitor's name, its brightness percentage and a slider.
final class BrightnessSliderView: NSView {
    let displayID: CGDirectDisplayID
    private let name: String
    private let label = NSTextField(labelWithString: "")
    private let slider = NSSlider(value: 50, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let onChange: (CGDirectDisplayID, Int) -> Void

    init(id: CGDirectDisplayID, name: String, level: Int?, onChange: @escaping (CGDirectDisplayID, Int) -> Void) {
        displayID = id
        self.name = name
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 46))

        label.font = .menuFont(ofSize: 0)
        label.textColor = .secondaryLabelColor
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(slid)
        for view in [label, slider] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            slider.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 2),
        ])
        show(level)
    }

    required init?(coder: NSCoder) { nil }

    func show(_ level: Int?) {
        slider.isEnabled = level != nil
        slider.integerValue = level ?? 50
        label.stringValue = level.map { "\(name)  \($0)%" } ?? "\(name)  (not responding)"
    }

    @objc private func slid() {
        label.stringValue = "\(name)  \(slider.integerValue)%"
        onChange(displayID, slider.integerValue)
    }
}

// A menu row with a label and a 0–1 slider; the owner turns the slider position into a value and a label.
final class ValueSliderView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let describe: (Double) -> String
    private let onChange: (Double) -> Void

    init(position: Double?, unavailable: String, describe: @escaping (Double) -> String,
         onChange: @escaping (Double) -> Void) {
        self.describe = describe
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 46))

        label.font = .menuFont(ofSize: 0)
        label.textColor = .secondaryLabelColor
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(slid)
        for view in [label, slider] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            slider.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 2),
        ])
        slider.isEnabled = position != nil
        slider.doubleValue = position ?? 0
        label.stringValue = position.map(describe) ?? unavailable
    }

    required init?(coder: NSCoder) { nil }

    @objc private func slid() {
        label.stringValue = describe(slider.doubleValue)
        onChange(slider.doubleValue)
    }
}
