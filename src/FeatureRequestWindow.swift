import AppKit

// The form, in a window of its own: the settings panel closes when it loses focus, and an idea can take a while to write.
final class FeatureRequestWindow: NSObject, NSWindowDelegate, NSTextViewDelegate, NSTextFieldDelegate {
    private static let disclosure = "Goes to RubberMAC's developer with your RubberMAC and macOS versions, nothing else"
    private static let emailLabel = "Your email, if you'd like a reply"
    private static let sentMessage = "Sent. Thank you."

    let window: NSWindow
    let textView: NSTextView
    let textScroll: NSScrollView
    let countLabel = NSTextField(labelWithString: "")
    let emailField = NSTextField()
    let statusLabel = NSTextField(wrappingLabelWithString: "")
    let sendButton = NSButton(title: "Send", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    var onClose: (() -> Void)?
    private let server: URL
    private(set) var isSending = false
    private(set) var isClosed = false

    private static let counter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        return formatter
    }()

    init(server: URL) {
        self.server = server
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 360), styleMask: [.titled, .closable],
                          backing: .buffered, defer: true)
        textScroll = NSTextView.scrollableTextView()
        textView = textScroll.documentView as! NSTextView
        super.init()

        window.title = "Send a Feature Request"
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.delegate = self

        let prompt = NSTextField(labelWithString: "What would you like RubberMAC to do?")
        prompt.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)

        textScroll.borderType = .bezelBorder
        textScroll.hasVerticalScroller = true
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.delegate = self
        textView.setAccessibilityLabel("Your idea")

        countLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        countLabel.alignment = .right

        let emailTitle = NSTextField(labelWithString: Self.emailLabel)
        emailField.placeholderString = "Optional"
        emailField.delegate = self
        emailField.setAccessibilityLabel(Self.emailLabel)
        emailField.contentType = .emailAddress

        let disclosure = NSTextField(wrappingLabelWithString: Self.disclosure)
        disclosure.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        disclosure.textColor = .secondaryLabelColor

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        sendButton.target = self
        sendButton.action = #selector(send)
        sendButton.keyEquivalent = "\r"
        sendButton.keyEquivalentModifierMask = .command
        sendButton.toolTip = "⌘↩"
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [statusLabel, cancelButton, sendButton])
        buttons.orientation = .horizontal
        buttons.alignment = .firstBaseline
        buttons.spacing = 12
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [prompt, textScroll, countLabel, emailTitle, emailField, disclosure, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(4, after: textScroll)
        stack.setCustomSpacing(4, after: emailTitle)
        stack.setCustomSpacing(16, after: disclosure)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        window.contentView = content
        let width: CGFloat = 420
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            textScroll.widthAnchor.constraint(equalToConstant: width),
            textScroll.heightAnchor.constraint(equalToConstant: 150),
            countLabel.widthAnchor.constraint(equalToConstant: width),
            emailField.widthAnchor.constraint(equalToConstant: width),
            disclosure.widthAnchor.constraint(equalToConstant: width),
            buttons.widthAnchor.constraint(equalToConstant: width),
            sendButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
            cancelButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
        ])
        window.setContentSize(content.fittingSize)
        update()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
    }

    var text: String {
        get { textView.string }
        set {
            textView.string = newValue
            update()
        }
    }

    var email: String {
        get { emailField.stringValue }
        set { emailField.stringValue = newValue }
    }

    // The count goes red past the limit, and Send waits for something within it.
    func update() {
        let count = FeatureRequest.length(text)
        let number = { (value: Int) in Self.counter.string(from: NSNumber(value: value)) ?? String(value) }
        countLabel.stringValue = "\(number(count)) / \(number(FeatureRequest.maxCharacters))"
        countLabel.textColor = count > FeatureRequest.maxCharacters ? .systemRed : .secondaryLabelColor
        sendButton.isEnabled = !isSending && count > 0 && count <= FeatureRequest.maxCharacters
    }

    func textDidChange(_ notification: Notification) {
        update()
    }

    // Esc in the text box cancels rather than offer word completions.
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        cancel()
        return true
    }

    // In the email box, ↩ sends and Esc cancels.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if sendButton.isEnabled { send() }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancel()
            return true
        default:
            return false
        }
    }

    @objc func send() {
        if let problem = FeatureRequest.problem(text: text, email: email) {
            return say(problem, isError: true)
        }
        isSending = true
        setEditable(false)
        update()
        say("Sending…", isError: false)
        FeatureRequest.send(text: text, email: email, to: server) { [weak self] outcome in
            self?.finish(outcome)
        }
    }

    private func finish(_ outcome: FeatureRequest.Outcome) {
        isSending = false
        switch outcome {
        case .sent:
            say(Self.sentMessage, isError: false)
            sendButton.isEnabled = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.close() }
        case .failed(let reason):
            say(reason, isError: true)
            setEditable(true)
            update()
        }
    }

    @objc func cancel() {
        close()
    }

    func close() {
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        isClosed = true
        onClose?()
    }

    private func setEditable(_ editable: Bool) {
        textView.isEditable = editable
        emailField.isEditable = editable
    }

    private func say(_ message: String, isError: Bool) {
        statusLabel.stringValue = message
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }
}
