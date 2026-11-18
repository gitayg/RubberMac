import AppKit

// Presses a zoom item in its app through Accessibility, as choosing it from the menu does, not by typing its shortcut:
// in Claude, ⌘⇧= posted to its process (with + as the character) did nothing and ⌘- didn't zoom out, while pressing the
// items zoomed it in and back out (--selftest wheelzoom-live).
enum ZoomKeys {
    static let presser = ZoomPresser()

    static func press(_ item: ZoomItem, in pid: pid_t) {
        presser.press(item, in: pid)
    }
}

// One press at a time, in the order they came, on a queue of its own: the tap's thread never waits for another app to
// answer, and a zoom in then out can't land the other way round. An app that hangs gets at most `limit` presses waiting,
// and none is sent to it while it doesn't answer: the notches meanwhile are dropped, not saved up for when it wakes.
final class ZoomPresser {
    static let limit = 2
    // Each item's own, never the system-wide one: a press that waits longer gives up.
    static let timeout: Float = 0.5

    var limit = ZoomPresser.limit
    var queue = DispatchQueue(label: "wheel zoom presses", qos: .userInitiated)
    var ask: (AXUIElement) -> AXError = ZoomPresser.askEnabled
    var pressElement: (AXUIElement) -> AXError = ZoomPresser.axPress
    var read: (pid_t) -> [ZoomMenus.Entry]? = ZoomMenus.read
    private let lock = NSLock()
    private var pending = 0
    // The zoom items read again after an app built its menus anew, until the cache's own next read. On the queue only.
    private var found: [pid_t: [ZoomItem]] = [:]

    // false when dropped: too many presses still waiting.
    @discardableResult
    func press(_ item: ZoomItem, in pid: pid_t) -> Bool {
        lock.lock()
        guard pending < limit else {
            lock.unlock()
            return false
        }
        pending += 1
        lock.unlock()
        queue.async {
            self.pressNow(item, pid)
            self.lock.lock()
            self.pending -= 1
            self.lock.unlock()
        }
        return true
    }

    // The item is asked whether it's enabled before it's pressed, as measured in a scratch app: AppKit presses an item
    // only if it was enabled when it last checked, and being asked makes it check again (at most once a second). An app
    // that doesn't answer gets no press, as one that times out still lands once the app wakes. An item gone since its
    // menus were read (Claude built its menus anew three minutes into a six-minute watch) is found again by its title
    // and shortcut.
    private func pressNow(_ item: ZoomItem, _ pid: pid_t) {
        guard let element = item.element else { return }
        func send(_ element: AXUIElement) -> AXError {
            let asked = ask(element)
            if asked != .cannotComplete, asked != .invalidUIElement { _ = pressElement(element) }
            return asked
        }
        guard send(element) == .invalidUIElement else { return }
        func match(_ items: [ZoomItem]?) -> AXUIElement? {
            items?.first { $0.title == item.title && $0.key == item.key && $0.modifiers == item.modifiers }?.element
        }
        if let kept = match(found[pid]), send(kept) != .invalidUIElement { return }
        found[pid] = read(pid)?.map(\.item).filter(ZoomMenus.looksLikeZoom)
        if let fresh = match(found[pid]) { _ = send(fresh) }
    }

    static func axPress(_ element: AXUIElement) -> AXError {
        AXUIElementSetMessagingTimeout(element, timeout)
        return AXUIElementPerformAction(element, kAXPressAction as CFString)
    }

    static func askEnabled(_ element: AXUIElement) -> AXError {
        AXUIElementSetMessagingTimeout(element, timeout)
        var enabled: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabled)
    }
}
