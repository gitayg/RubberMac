import AppKit

// The pad a reply is written in: what the user types on top, the fixed version below with the changes marked.
// A non-activating panel, so the app being replied in stays frontmost and keeps its cursor for the paste.
final class WritingPad: NSObject, NSTextViewDelegate, NSWindowDelegate {
    static let size = NSSize(width: 640, height: 300)

    var onChange: (String) -> Void = { _ in }
    var onSend: (_ asTyped: Bool) -> Void = { _ in }
    var onClose: () -> Void = {}

    private var panel: NSPanel?
    private var draft: NSTextView!
    private var fixed: NSTextView!
    private let heading = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private var hiding = false

    var isShown: Bool { panel?.isVisible == true }
    var text: String { draft?.string ?? "" }

    // frame: the window being replied in, in AppKit coordinates; the pad sits over its bottom, where the
    // message box usually is.
    func show(app: String, over frame: NSRect?, text: String) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if panel.contentView?.subviews.isEmpty != false { panel.contentView = makeContent() }
        heading.stringValue = "Reply in \(app)"
        draft.string = text
        showFix(nil)
        panel.setFrameOrigin(Self.origin(over: frame, size: Self.size))
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(draft)
    }

    func hide() {
        hiding = true
        panel?.orderOut(nil)
        hiding = false
    }

    func setText(_ text: String) {
        draft.string = text
        onChange(text)
    }

    func showStatus(_ text: String) {
        status.stringValue = text
    }

    // nil clears it; the fixed text is shown with added words marked green and dropped words struck out in red.
    func showFix(_ fix: (draft: String, fixed: String)?) {
        guard let fix else { fixed.string = ""; return }
        let marked = NSMutableAttributedString()
        for (text, kind) in FixDiff.segments(from: fix.draft, to: fix.fixed) {
            var style: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor]
            switch kind {
            case .same: break
            case .added: style[.backgroundColor] = NSColor.systemGreen.withAlphaComponent(0.35)
            case .removed:
                style[.foregroundColor] = NSColor.systemRed
                style[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                marked.append(NSAttributedString(string: String(text.dropLast()), attributes: style))
                marked.append(NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: 14)]))
                continue
            }
            marked.append(NSAttributedString(string: text, attributes: style))
        }
        fixed.textStorage?.setAttributedString(marked)
    }

    // Builds the pad's view without showing it, so it can also be rendered off screen.
    func makeContent() -> NSView {
        let size = Self.size
        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.appearance = NSAppearance(named: .vibrantDark)
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true

        let inset: CGFloat = 14
        let width = size.width - 2 * inset
        heading.font = .boldSystemFont(ofSize: 12)
        heading.textColor = .secondaryLabelColor
        heading.frame = NSRect(x: inset, y: size.height - 30, width: width / 2, height: 16)
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.alignment = .right
        status.lineBreakMode = .byTruncatingTail
        status.frame = NSRect(x: inset + width / 2, y: size.height - 30, width: width / 2, height: 16)

        let (draftScroll, draft) = Self.textArea(NSRect(x: inset, y: 150, width: width, height: 110), editable: true)
        draft.delegate = self
        self.draft = draft
        let label = NSTextField(labelWithString: "Fixed")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .tertiaryLabelColor
        label.frame = NSRect(x: inset, y: 130, width: width, height: 14)
        let (fixedScroll, fixed) = Self.textArea(NSRect(x: inset, y: 34, width: width, height: 94), editable: false)
        self.fixed = fixed
        let hint = NSTextField(labelWithString: "↩ Send fixed    ⌥↩ Send as typed    ⇧↩ New line    Esc Close")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.frame = NSRect(x: inset, y: 10, width: width, height: 14)

        [heading, status, draftScroll, label, fixedScroll, hint].forEach(background.addSubview)
        return background
    }

    private static func textArea(_ frame: NSRect, editable: Bool) -> (NSScrollView, NSTextView) {
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = frame
        scroll.drawsBackground = false
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 8
        scroll.layer?.backgroundColor = NSColor.white.withAlphaComponent(editable ? 0.10 : 0.04).cgColor
        let text = scroll.documentView as! NSTextView
        text.isEditable = editable
        text.isRichText = false
        text.allowsUndo = true
        text.drawsBackground = false
        text.font = .systemFont(ofSize: 14)
        text.textColor = .labelColor
        text.insertionPointColor = .labelColor
        text.textContainerInset = NSSize(width: 6, height: 6)
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        return (scroll, text)
    }

    private func makePanel() -> NSPanel {
        let panel = KeyPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.delegate = self
        return panel
    }

    static func origin(over frame: NSRect?, size: NSSize) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { screen in frame.map { NSPointInRect(NSPoint(x: $0.midX, y: $0.midY), screen.frame) } ?? false }
            ?? NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!
        let area = screen.visibleFrame
        let target = frame ?? area
        let x = min(max(target.midX - size.width / 2, area.minX + 8), area.maxX - size.width - 8)
        let y = min(max(target.minY + 24, area.minY + 8), area.maxY - size.height - 8)
        return NSPoint(x: x.rounded(), y: y.rounded())
    }

    func textDidChange(_ notification: Notification) {
        onChange(draft.string)
    }

    // ↩ sends the fixed text, ⌥↩ what was typed, ⇧↩ starts a new line (as in Teams), Esc closes. Sending and
    // closing wait until the key is handled: hiding the pad in the middle of it leaves the text view taking commands
    // but no more typing the next time it opens.
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.shift) {
                textView.insertText("\n", replacementRange: textView.selectedRange())
            } else {
                let asTyped = flags.contains(.option)
                DispatchQueue.main.async { self.onSend(asTyped) }
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.complete(_:)):
            DispatchQueue.main.async { self.onClose() }
            return true
        default:
            return false
        }
    }

    // Clicking back into the app being replied in closes the pad; the draft is kept for next time.
    func windowDidResignKey(_ notification: Notification) {
        if isShown, !hiding { onClose() }
    }
}

// Borderless panels can't become key by default, and the pad has to take typing.
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
