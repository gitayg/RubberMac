import AppKit

// What the question says, on the screen that changed and on the others.
struct ScreenResolutionQuestion: Equatable {
    let display: CGDirectDisplayID
    let name: String
    let chosen: String
    let previous: String
    let secondsLeft: Int

    func title(onChangedScreen: Bool) -> String {
        onChangedScreen ? "Keep this resolution?" : "Keep the new resolution on \(name)?"
    }

    var body: String {
        "\(name) is at \(chosen). Going back to \(previous) in \(secondsLeft) second\(secondsLeft == 1 ? "" : "s")."
    }
}

protocol ScreenResolutionPresenter: AnyObject {
    var onKeep: () -> Void { get set }
    var onGoBack: () -> Void { get set }
    func show(_ question: ScreenResolutionQuestion)
    func hide()
}

// The question on every screen, so it can be answered from another one while the changed screen shows nothing. ↩ and
// Esc go back: on a blank screen nobody can see which button is which, so a guess must be the safe one.
final class ScreenResolutionWindows: ScreenResolutionPresenter {
    // Above RubberMAC's own software dimming, so it reads at full strength on a dimmed screen.
    static let level = NSWindow.Level.screenSaver

    var onKeep: () -> Void = {}
    var onGoBack: () -> Void = {}
    // Screens by their visible frames, and how a panel comes on screen (with the keyboard or without); the self-test
    // gives its own, so nothing shows.
    var screens: () -> [(id: CGDirectDisplayID, visible: NSRect)] = {
        NSScreen.screens.compactMap { screen in screen.displayID.map { ($0, screen.visibleFrame) } }
    }
    var present: (ScreenResolutionPanel, Bool) -> Void = { panel, key in
        panel.orderFrontRegardless()
        if key { panel.makeKey() }
    }
    private(set) var panels: [CGDirectDisplayID: ScreenResolutionPanel] = [:]

    // Again on each tick, which also follows screens that came, went or changed size. Only the first showing takes the
    // keyboard, on the changed screen, so clicking into another app meanwhile isn't undone four times a second.
    func show(_ question: ScreenResolutionQuestion) {
        let screens = screens()
        let key = panels.isEmpty ? screens.first { $0.id == question.display }?.id ?? screens.first?.id : nil
        for gone in Set(panels.keys).subtracting(screens.map(\.id)) { panels.removeValue(forKey: gone)?.orderOut(nil) }
        for (id, visible) in screens {
            let panel = panels[id] ?? makePanel()
            panels[id] = panel
            panel.question.show(question, onChangedScreen: id == question.display)
            panel.place(in: visible)
            if !panel.isVisible { present(panel, id == key) }
        }
    }

    func hide() {
        panels.values.forEach { $0.orderOut(nil) }
        panels = [:]
    }

    func makePanel() -> ScreenResolutionPanel {
        let panel = ScreenResolutionPanel()
        panel.question.onKeep = { [weak self] in self?.onKeep() }
        panel.question.onGoBack = { [weak self] in self?.onGoBack() }
        return panel
    }
}

final class ScreenResolutionPanel: NSPanel {
    let question = ScreenResolutionQuestionView()

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: question.frame.size), styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        level = ScreenResolutionWindows.level
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        contentView = question
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        question.onGoBack()
    }

    // Across the middle, a little above it, as alerts sit.
    func place(in visible: NSRect) {
        let size = frame.size
        let origin = NSPoint(x: (visible.midX - size.width / 2).rounded(), y: (visible.midY + visible.height / 8 - size.height / 2).rounded())
        if frame.origin != origin { setFrameOrigin(origin) }
    }
}

final class ScreenResolutionQuestionView: NSView {
    static let width: CGFloat = 400

    let title = NSTextField(wrappingLabelWithString: "")
    let body = NSTextField(wrappingLabelWithString: "")
    let keep = NSButton(title: "Keep", target: nil, action: nil)
    let goBack = NSButton(title: "Go Back", target: nil, action: nil)
    var onKeep: () -> Void = {}
    var onGoBack: () -> Void = {}

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 150))
        let icon = NSImageView(image: NSImage(systemSymbolName: "display", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 34, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        body.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        body.textColor = .secondaryLabelColor
        for label in [title, body] {
            label.isSelectable = false
            label.preferredMaxLayoutWidth = Self.width - 104
        }
        keep.target = self
        keep.action = #selector(keepChosen)
        goBack.target = self
        goBack.action = #selector(goBackChosen)
        goBack.keyEquivalent = "\r"
        for button in [keep, goBack] { button.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true }

        let text = NSStackView(views: [title, body])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 6
        let top = NSStackView(views: [icon, text])
        top.alignment = .top
        top.spacing = 16
        let buttons = NSStackView(views: [keep, goBack])
        buttons.spacing = 12
        let stack = NSStackView(views: [top, buttons])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: Self.width),
            text.widthAnchor.constraint(equalToConstant: Self.width - 104),
        ])
        show(ScreenResolutionQuestion(display: 0, name: "", chosen: "", previous: "", secondsLeft: Int(ScreenResolutionChange.countdown)),
             onChangedScreen: true)
    }

    required init?(coder: NSCoder) { nil }

    // Under the see-through title bar too.
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }

    func show(_ question: ScreenResolutionQuestion, onChangedScreen: Bool) {
        let heading = question.title(onChangedScreen: onChangedScreen)
        if title.stringValue != heading { title.stringValue = heading }
        if body.stringValue != question.body { body.stringValue = question.body }
        layoutSubtreeIfNeeded()
        let height = fittingSize.height
        if frame.height != height {
            setFrameSize(NSSize(width: Self.width, height: height))
            window?.setContentSize(frame.size)
        }
    }

    @objc private func keepChosen() { onKeep() }
    @objc private func goBackChosen() { onGoBack() }
}
