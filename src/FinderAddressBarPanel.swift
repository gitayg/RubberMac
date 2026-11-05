import AppKit

// The strip itself: a path field on a slim bar. It never activates RubberMAC, so Finder stays the app in front;
// a click makes it key for typing, with the whole path selected.
final class FinderAddressBarPanel: NSPanel, NSTextFieldDelegate {
    var onCommit: () -> Void = {}
    var onCancel: () -> Void = {}
    var onResignKey: () -> Void = {}

    private let field = AddressField()
    private let tint = NSView()
    private var shown = ""
    private var rejections = 0

    // While the red tint for text that isn't a path is showing.
    private(set) var isRejected = false

    var text: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    var isEditing: Bool { field.currentEditor() != nil }

    init() {
        let size = NSSize(width: 400, height: FinderAddressBarLayout.height)
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .normal
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        // In the Space it's shown in, as Finder's window is, and left out of Exposé and window cycling.
        collectionBehavior = [.moveToActiveSpace, .transient, .ignoresCycle, .fullScreenAuxiliary]

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.masksToBounds = true

        tint.frame = background.bounds
        tint.autoresizingMask = [.width, .height]
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.35).cgColor
        tint.alphaValue = 0

        let icon = NSImageView(image: NSImage(systemSymbolName: "folder", accessibilityDescription: "Folder")!)
        icon.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        icon.frame = NSRect(x: 9, y: (size.height - 16) / 2, width: 16, height: 16)

        field.frame = NSRect(x: 31, y: (size.height - 18) / 2, width: size.width - 31 - 10, height: 18)
        field.autoresizingMask = [.width]
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.textColor = .labelColor
        // A long path keeps its end, the folder it's in, in view.
        field.lineBreakMode = .byTruncatingHead
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = false
        field.isAutomaticTextCompletionEnabled = false
        field.placeholderString = "Paste or type a path"
        field.delegate = self

        [tint, icon, field].forEach(background.addSubview)
        contentView = background
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResignKey()
    }

    // The path of the folder the window shows; what the user is typing stays until they're done.
    func show(_ path: String, placeholder: String) {
        shown = path
        field.placeholderString = placeholder
        if !isEditing { field.stringValue = path }
    }

    // Back to the folder's path, with typing over.
    func revert() {
        field.abortEditing()
        field.stringValue = shown
    }

    // Typing over, with what was typed kept until the window shows the folder.
    func finishEditing() {
        let typed = field.stringValue
        if isEditing { makeFirstResponder(nil) }
        field.stringValue = typed
    }

    // Text that isn't a path: a brief red tint, and the field stays as it is to fix.
    func reject() {
        rejections += 1
        let rejection = rejections
        isRejected = true
        tint.alphaValue = 1
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 1
            tint.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            if self?.rejections == rejection { self?.isRejected = false }
        }
    }

    // ↩ goes to the path, Esc puts the folder's path back and returns the keyboard to Finder.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onCommit()
            return true
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.complete(_:)):
            onCancel()
            return true
        default:
            return false
        }
    }
}

// The first click selects the whole path, ready to paste or type over, as in a browser's address bar; clicks after
// that place the cursor as usual.
private final class AddressField: NSTextField {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard currentEditor() == nil, let window else { return super.mouseDown(with: event) }
        window.makeKey()
        window.makeFirstResponder(self)
        currentEditor()?.selectAll(nil)
    }
}
