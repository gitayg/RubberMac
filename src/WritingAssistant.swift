import AppKit

// ⌘⇧Space in any app opens a pad to write the reply in. It's fixed while it's typed, ↩ pastes the fixed text
// into the app's message box, and the reply is saved with the text of the window it answered.
final class WritingAssistant {
    // A pause in typing this long starts a fix.
    private static let pause: TimeInterval = 0.6
    // A fix usually takes about a second; under heavy load one has taken minutes.
    private static let limit: TimeInterval = 15

    private struct Target {
        let pid: pid_t
        let app: String
        let bundleID: String?
        let window: AXUIElement?
        let id: CGWindowID?
    }

    private let pad = WritingPad()
    private let store: URL
    private var target: Target?
    private var screen = ""
    private var screenNote = ""
    private var fixNote = ""
    private var reading: Task<Void, Never>?
    private var fixing: Task<Void, Never>?
    private var fixingText: String?
    private var failedText: String?
    private var pending: DispatchWorkItem?
    private var deadline: DispatchWorkItem?
    private var fix: (draft: String, fixed: String)?
    private var sendWhenFixed = false
    private var drafts: [CGWindowID: String] = [:]

    var isShown: Bool { pad.isShown }
    var text: String { pad.text }
    // The fixed version of what's in the pad now, once it's ready.
    var fixedText: String? { fix.flatMap { $0.draft == pad.text ? $0.fixed : nil } }

    init(store: URL = ReplyStore.folder) {
        self.store = store
        pad.onChange = { [weak self] in self?.changed($0) }
        pad.onSend = { [weak self] in self?.send(asTyped: $0) }
        pad.onClose = { [weak self] in self?.finish(keepDraft: true) }
    }

    func toggle() {
        pad.isShown ? finish(keepDraft: true) : open()
    }

    func open() {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return }
        let window = AX.focusedWindow(of: app.processIdentifier)
        let target = Target(pid: app.processIdentifier, app: app.localizedName ?? "the app", bundleID: app.bundleIdentifier,
                            window: window, id: window.flatMap(AX.windowID))
        self.target = target
        screen = ""
        fix = nil
        fixNote = ""
        failedText = nil
        sendWhenFixed = false
        pad.show(app: target.app, over: window.flatMap(AX.frame).map(Self.appKitFrame), text: target.id.flatMap { drafts[$0] } ?? "")
        if TextFixer.isAvailable { TextFixer.prewarm() } else { fixNote = "Fixing needs Apple Intelligence" }
        readScreen(target.id)
        if !pad.text.isEmpty { changed(pad.text) }
        log("writing pad: open for \(target.app)")
    }

    private func readScreen(_ id: CGWindowID?) {
        reading?.cancel()
        guard let id else { screenNote = ""; return refresh() }
        guard ScreenText.hasPermission else { screenNote = "Not reading the screen: no permission"; return refresh() }
        screenNote = "Reading the screen…"
        refresh()
        reading = Task { @MainActor [weak self] in
            let text = await ScreenText.read(window: id)
            guard let self, !Task.isCancelled, self.target?.id == id else { return }
            self.screen = text
            self.screenNote = text.isEmpty ? "Couldn't read the screen" : ""
            self.refresh()
        }
    }

    private func changed(_ text: String) {
        pending?.cancel()
        pending = nil
        fix = nil
        failedText = nil
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fixing?.cancel()
            fixingText = nil
            pad.showFix(nil)
            fixNote = ""
            return refresh()
        }
        let work = DispatchWorkItem { [weak self] in self?.runFix(text) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pause, execute: work)
    }

    private func runFix(_ text: String) {
        pending = nil
        fixing?.cancel()
        fixingText = text
        fixNote = sendWhenFixed ? "Fixing, then sending…" : "Fixing…"
        refresh()
        deadline?.cancel()
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, self.fixingText == text else { return }
            self.fixing?.cancel()
            self.failed(text, TextFixer.Failure.unavailable("Fixing took longer than \(Int(Self.limit))s"))
        }
        self.deadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.limit, execute: deadline)
        let context = screen
        let start = Date()
        fixing = Task { @MainActor [weak self] in
            do {
                let fixed = try await TextFixer.fix(text, context: context)
                guard let self, !Task.isCancelled, self.pad.text == text else { return }
                self.fixed(text, fixed, seconds: -start.timeIntervalSinceNow)
            } catch is CancellationError {
            } catch {
                guard let self, !Task.isCancelled, self.pad.text == text else { return }
                self.failed(text, error)
            }
        }
    }

    private func fixed(_ text: String, _ fixed: String, seconds: TimeInterval) {
        fixingText = nil
        deadline?.cancel()
        fix = (text, fixed)
        pad.showFix(fix)
        fixNote = fixed == text ? "Nothing to fix" : String(format: "Fixed in %.1fs", seconds)
        refresh()
        if sendWhenFixed { deliver(fixed) }
    }

    private func failed(_ text: String, _ error: Error) {
        fixingText = nil
        deadline?.cancel()
        failedText = text
        sendWhenFixed = false
        fixNote = "Couldn't fix (\(error.localizedDescription.prefix(60))), ⌥↩ sends as typed"
        refresh()
        log("writing pad: fix failed: \(String(describing: error).prefix(300))")
    }

    private func send(asTyped: Bool) {
        let text = pad.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if asTyped { return deliver(text) }
        if let fix, fix.draft == text { return deliver(fix.fixed) }
        if failedText == text { return }
        sendWhenFixed = true
        if fixingText == text { fixNote = "Fixing, then sending…"; refresh() } else { runFix(text) }
    }

    private func deliver(_ text: String) {
        guard let target else { return }
        let typed = pad.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let sent = text.trimmingCharacters(in: .whitespacesAndNewlines)
        finish(keepDraft: false)
        do {
            try ReplyStore.save(SavedReply(date: Date(), app: target.app, bundleID: target.bundleID, screen: screen,
                                           typed: typed, sent: sent), in: store)
        } catch {
            log("writing pad: couldn't save the reply: \(error)")
        }
        // After the ↩ that sent it is released, so the app doesn't get a stray Return.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            Paster.paste(sent, into: target.pid, window: target.window)
        }
        log("writing pad: sent \(sent == typed ? "as typed" : "fixed"), \(sent.count) characters, to \(target.app)")
    }

    private func finish(keepDraft: Bool) {
        pending?.cancel()
        pending = nil
        fixing?.cancel()
        fixingText = nil
        deadline?.cancel()
        reading?.cancel()
        sendWhenFixed = false
        if let id = target?.id { drafts[id] = keepDraft && !pad.text.isEmpty ? pad.text : nil }
        pad.hide()
    }

    private func refresh() {
        pad.showStatus([fixNote, screenNote].filter { !$0.isEmpty }.joined(separator: " · "))
    }

    private static func appKitFrame(_ frame: CGRect) -> NSRect {
        let primary = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: frame.minX, y: primary - frame.maxY, width: frame.width, height: frame.height)
    }
}
