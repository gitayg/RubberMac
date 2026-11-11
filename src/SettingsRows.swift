import AppKit

// A slider row: while it's being dragged the panel holds off re-rendering, which would swap it out mid-drag.
protocol SettingsSlider: AnyObject {
    var isDragging: Bool { get }
    var onDragEnd: (() -> Void)? { get set }
}

// A card of rows, as in System Settings: rounded, with a thin separator between rows.
final class SettingsCardView: NSView {
    static let radius: CGFloat = 10

    var separators: [CGFloat] = []

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: Self.radius, yRadius: Self.radius)
        // Not controlBackgroundColor: from macOS 26 on it's the same as the window's, and a card would be only an outline.
        NSColor.tertiarySystemFill.setFill()
        shape.fill()
        NSColor.separatorColor.setStroke()
        shape.lineWidth = 0.5
        shape.stroke()
        NSColor.separatorColor.setFill()
        for y in separators {
            NSRect(x: SettingsRowView.padding, y: y - 0.25, width: bounds.width - SettingsRowView.padding, height: 0.5).fill()
        }
    }
}

final class SettingsRowView: NSView {
    typealias Perform = (_ action: Selector, _ target: AnyObject?, _ sender: Any, _ closesPanel: Bool) -> Void

    static let padding: CGFloat = 12
    static let minimumHeight: CGFloat = 40
    private static let noteHeight: CGFloat = 30
    private static let gap: CGFloat = 12
    private static let noteGap: CGFloat = 2
    private static let verticalPadding: CGFloat = 8

    private(set) var row: SettingsRow
    private let perform: Perform
    private let title = NSTextField(wrappingLabelWithString: "")
    private let note = NSTextField(wrappingLabelWithString: "")
    private var control: NSView?

    override var isFlipped: Bool { true }

    init(row: SettingsRow, width: CGFloat, perform: @escaping Perform) {
        self.row = row
        self.perform = perform
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.minimumHeight))
        if case .custom(let view) = row.control {
            embed(view)
        } else {
            setUpLabels()
            control = makeControl()
            if let control { addSubview(control) }
        }
        layoutRow(width: width)
    }

    required init?(coder: NSCoder) { nil }

    var customView: NSView? { if case .custom(let view) = row.control { view } else { nil } }

    private func setUpLabels() {
        let isNote: Bool
        if case .note = row.control { isNote = true } else { isNote = false }
        for label in [title, note] {
            label.isSelectable = false
            label.maximumNumberOfLines = 0
            label.lineBreakMode = .byWordWrapping
        }
        title.font = .systemFont(ofSize: isNote ? 11 : 13)
        title.textColor = isNote ? .secondaryLabelColor : .labelColor
        title.stringValue = row.title
        addSubview(title)
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.stringValue = row.note ?? ""
        note.isHidden = row.note == nil
        addSubview(note)
    }

    private func makeControl() -> NSView? {
        switch row.control {
        case .none, .note, .custom:
            return nil
        case .toggle(let on):
            let toggle = NSSwitch()
            toggle.controlSize = .mini
            toggle.state = on ? .on : .off
            toggle.target = self
            toggle.action = #selector(controlUsed(_:))
            return toggle
        case .popup(let items):
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.controlSize = .small
            popup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            fill(popup, with: items)
            return popup
        case .button(let title, let enabled):
            let button = NSButton(title: title, target: self, action: #selector(controlUsed(_:)))
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            button.isEnabled = enabled
            return button
        case .status(let text, let isOn, let button):
            return SettingsStatusView(text: text, isOn: isOn, button: button.map {
                let view = NSButton(title: $0, target: self, action: #selector(controlUsed(_:)))
                view.controlSize = .small
                view.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                return view
            })
        }
    }

    // The items shown are copies, so each original keeps its own target and action and still arrives as the sender.
    private func fill(_ popup: NSPopUpButton, with items: [NSMenuItem]) {
        popup.removeAllItems()
        for item in items {
            if item.isSeparatorItem {
                popup.menu?.addItem(.separator())
                continue
            }
            let copy = NSMenuItem(title: item.title, action: #selector(itemChosen(_:)), keyEquivalent: "")
            copy.target = self
            copy.representedObject = item
            popup.menu?.addItem(copy)
        }
        select(in: popup, items)
    }

    private func select(in popup: NSPopUpButton, _ items: [NSMenuItem]) {
        for (copy, item) in zip(popup.itemArray, items) where item.state == .on {
            popup.select(copy)
        }
    }

    @objc private func controlUsed(_ sender: Any) {
        guard let action = row.action else { return }
        perform(action, row.target, sender, row.closesPanel)
    }

    @objc private func itemChosen(_ copy: NSMenuItem) {
        guard let item = copy.representedObject as? NSMenuItem, let action = item.action else { return }
        perform(action, item.target, item, row.closesPanel)
    }

    // Takes the state of a row of the same shape, leaving the views where they are.
    func update(with new: SettingsRow) {
        row = new
        switch new.control {
        case .toggle(let on):
            let state: NSControl.StateValue = on ? .on : .off
            if let toggle = control as? NSSwitch, toggle.state != state { toggle.state = state }
        case .popup(let items):
            if let popup = control as? NSPopUpButton {
                for (copy, item) in zip(popup.itemArray, items) where copy.representedObject != nil { copy.representedObject = item }
                select(in: popup, items)
            }
        case .button(_, let enabled):
            (control as? NSButton)?.isEnabled = enabled
        case .custom(let view):
            subviews.forEach { $0.removeFromSuperview() }
            embed(view)
        case .none, .note, .status:
            break
        }
    }

    private func embed(_ view: NSView) {
        view.frame = NSRect(x: 0, y: 0, width: frame.width, height: view.frame.height)
        view.autoresizingMask = [.width]
        addSubview(view)
    }

    private func layoutRow(width: CGFloat) {
        if let view = customView {
            frame.size = NSSize(width: width, height: view.frame.height)
            return
        }
        var controlSize = NSSize.zero
        if let control {
            (control as? NSControl)?.sizeToFit()
            (control as? SettingsStatusView)?.fit()
            controlSize = control.frame.size
        }
        let textWidth = width - 2 * Self.padding - (control == nil ? 0 : controlSize.width + Self.gap)
        let titleHeight = Self.height(of: title, width: textWidth)
        let noteHeight = note.isHidden ? 0 : Self.height(of: note, width: textWidth)
        let textHeight = titleHeight + (note.isHidden ? 0 : Self.noteGap + noteHeight)
        let height = max(row.isNote ? Self.noteHeight : Self.minimumHeight, textHeight + 2 * Self.verticalPadding)
        frame.size = NSSize(width: width, height: height)

        let top = ((height - textHeight) / 2).rounded()
        title.frame = NSRect(x: Self.padding, y: top, width: textWidth, height: titleHeight)
        note.frame = NSRect(x: Self.padding, y: top + titleHeight + Self.noteGap, width: textWidth, height: noteHeight)
        if let control {
            control.frame.origin = NSPoint(x: width - Self.padding - controlSize.width, y: ((height - controlSize.height) / 2).rounded())
        }
    }

    private static func height(of label: NSTextField, width: CGFloat) -> CGFloat {
        guard !label.stringValue.isEmpty, let cell = label.cell else { return 0 }
        return ceil(cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height)
    }
}

// On or off with a dot, and a button beside it.
final class SettingsStatusView: NSView {
    private static let dot: CGFloat = 8
    private static let gap: CGFloat = 6

    let button: NSButton?
    private let isOn: Bool?
    private let label: NSTextField

    override var isFlipped: Bool { true }

    init(text: String, isOn: Bool?, button: NSButton?) {
        self.isOn = isOn
        self.button = button
        label = NSTextField(labelWithString: text)
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.sizeToFit()
        addSubview(label)
        if let button { addSubview(button) }
        fit()
    }

    required init?(coder: NSCoder) { nil }

    func fit() {
        button?.sizeToFit()
        let dot = isOn == nil ? 0 : Self.dot + Self.gap
        let buttonWidth = button.map { $0.frame.width + 10 } ?? 0
        let height = max(label.frame.height, button?.frame.height ?? 0, Self.dot)
        frame.size = NSSize(width: dot + label.frame.width + buttonWidth, height: height)
        label.frame.origin = NSPoint(x: dot, y: ((height - label.frame.height) / 2).rounded())
        button?.frame.origin = NSPoint(x: frame.width - (button?.frame.width ?? 0), y: ((height - (button?.frame.height ?? 0)) / 2).rounded())
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let isOn else { return }
        (isOn ? NSColor.systemGreen : NSColor.systemOrange).setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: (bounds.height - Self.dot) / 2, width: Self.dot, height: Self.dot)).fill()
    }
}
