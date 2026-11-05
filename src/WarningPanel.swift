import AppKit

final class WarningPanel {
    private var panels: [NSPanel] = []
    private var counters: [NSTextField] = []
    private(set) var isShown = false

    func show(secondsLeft: Int) {
        if !isShown {
            NSScreen.screens.forEach(build)
            isShown = true
        }
        counters.forEach { $0.stringValue = "Screen saver in \(secondsLeft)s" }
    }

    func hide() {
        guard isShown else { return }
        panels.forEach { $0.orderOut(nil) }
        panels = []
        counters = []
        isShown = false
    }

    private func build(on screen: NSScreen) {
        let size = NSSize(width: 460, height: 76)
        let frame = NSRect(x: screen.frame.midX - size.width / 2,
                           y: screen.visibleFrame.maxY - size.height - 20,
                           width: size.width, height: size.height)

        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = ScreenOverlay.warningLevel
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.appearance = NSAppearance(named: .vibrantDark)
        background.wantsLayer = true
        background.layer?.cornerRadius = 16
        background.layer?.masksToBounds = true

        let icon = NSImageView(image: NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Lock")!)
        icon.symbolConfiguration = .init(pointSize: 26, weight: .semibold)
        icon.contentTintColor = .systemOrange

        let counter = NSTextField(labelWithString: "")
        counter.font = .monospacedDigitSystemFont(ofSize: 20, weight: .semibold)
        counter.textColor = .white

        let hint = NSTextField(labelWithString: "Locks right after. Move the mouse or press any key to stay.")
        hint.font = .systemFont(ofSize: 13)
        hint.textColor = .secondaryLabelColor

        let text = NSStackView(views: [counter, hint])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        let row = NSStackView(views: [icon, text])
        row.orientation = .horizontal
        row.spacing = 14
        row.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(row)
        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            row.centerYAnchor.constraint(equalTo: background.centerYAnchor),
        ])

        panel.contentView = background
        panel.orderFrontRegardless()
        panels.append(panel)
        counters.append(counter)
    }
}
