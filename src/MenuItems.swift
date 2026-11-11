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
}

// A settings row with the monitor's name, its brightness percentage and a slider.
final class BrightnessSliderView: NSView, SettingsSlider {
    let displayID: CGDirectDisplayID
    var isDragging = false
    var onDragEnd: (() -> Void)?
    private let name: String
    private let label = NSTextField(labelWithString: "")
    private let slider = NSSlider(value: 50, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let onChange: (CGDirectDisplayID, Int) -> Void

    init(id: CGDirectDisplayID, name: String, level: Int?, onChange: @escaping (CGDirectDisplayID, Int) -> Void) {
        displayID = id
        self.name = name
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: SliderRowLayout.height))

        SliderRowLayout.apply(label: label, slider: slider, in: self)
        slider.target = self
        slider.action = #selector(slid)
        show(level)
    }

    required init?(coder: NSCoder) { nil }

    // A reading that arrives during a drag would pull the slider out from under the pointer.
    func show(_ level: Int?) {
        guard !isDragging else { return }
        slider.isEnabled = level != nil
        slider.integerValue = level ?? 50
        label.stringValue = level.map { "\(name)  \($0)%" } ?? "\(name)  (not responding)"
    }

    @objc private func slid() {
        isDragging = SliderRowLayout.isStillDragging
        label.stringValue = "\(name)  \(slider.integerValue)%"
        onChange(displayID, slider.integerValue)
        if !isDragging { onDragEnd?() }
    }
}

// A settings row with a label and a 0–1 slider; the owner turns the slider position into a value and a label.
final class ValueSliderView: NSView, SettingsSlider {
    var isDragging = false
    var onDragEnd: (() -> Void)?
    private let label = NSTextField(labelWithString: "")
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let describe: (Double) -> String
    private let onChange: (Double) -> Void

    init(position: Double?, unavailable: String, describe: @escaping (Double) -> String,
         onChange: @escaping (Double) -> Void) {
        self.describe = describe
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: SliderRowLayout.height))

        SliderRowLayout.apply(label: label, slider: slider, in: self)
        slider.target = self
        slider.action = #selector(slid)
        slider.isEnabled = position != nil
        slider.doubleValue = position ?? 0
        label.stringValue = position.map(describe) ?? unavailable
    }

    required init?(coder: NSCoder) { nil }

    @objc private func slid() {
        isDragging = SliderRowLayout.isStillDragging
        label.stringValue = describe(slider.doubleValue)
        onChange(slider.doubleValue)
        if !isDragging { onDragEnd?() }
    }
}

// The two slider rows share how they're laid out in a card.
private enum SliderRowLayout {
    static let height: CGFloat = 54

    // A continuous slider's last action comes with the mouse-up; arrow keys never start a drag.
    static var isStillDragging: Bool { [.leftMouseDown, .leftMouseDragged].contains(NSApp.currentEvent?.type) }

    static func apply(label: NSTextField, slider: NSSlider, in view: NSView) {
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        slider.isContinuous = true
        slider.controlSize = .small
        for child in [label, slider] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            // Two more than the padding, to line up with the text of the rows around it.
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: SettingsRowView.padding + 2),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -SettingsRowView.padding),
            label.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            slider.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: SettingsRowView.padding + 2),
            slider.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -SettingsRowView.padding),
            slider.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 4),
        ])
    }
}
