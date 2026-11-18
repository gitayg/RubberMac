import AppKit

// A Zoom In or Zoom Out item in an app's menus, as Accessibility shows it.
struct ZoomItem {
    var title: String
    // The shortcut's character, nil without one, and AXMenuItemCmdModifiers: 0 is ⌘ alone; 1 adds ⇧, 2 ⌥, 4 ⌃, 8 drops ⌘.
    var key: String?
    var modifiers = 0
    var element: AXUIElement?

    var shortcut: String {
        guard let key else { return "none" }
        let mods = (modifiers & 4 != 0 ? "⌃" : "") + (modifiers & 2 != 0 ? "⌥" : "") + (modifiers & 1 != 0 ? "⇧" : "")
        return mods + (modifiers & 8 != 0 ? "" : "⌘") + key
    }
}

struct ZoomMenu {
    var zoomIn: ZoomItem
    var zoomOut: ZoomItem
}

enum ZoomLookup {
    case reading
    case none
    case found(ZoomMenu)
}

// Finds an app's Zoom In and Zoom Out by reading its menus through Accessibility, never opening or pressing them.
enum ZoomMenus {
    // Each item read, with the menu it's in.
    struct Entry {
        var item: ZoomItem
        var menu: Int
    }

    // A view's own zoom first: TextEdit's and Notes' Bigger (⌘+) changes the size of the selected text, their Zoom In
    // (⇧⌘.) the view's, which is what Ctrl + wheel does on Windows. Terminal and Messages have only a Bigger, for the view.
    static let inTitles: Set<String> = ["zoom in"]
    static let outTitles: Set<String> = ["zoom out"]
    static let biggerTitles: Set<String> = ["bigger", "make text bigger", "make bigger", "increase font size", "increase text size",
                                            "larger", "make text larger"]
    static let smallerTitles: Set<String> = ["smaller", "make text smaller", "make smaller", "decrease font size", "decrease text size"]
    // Enough for the biggest menus seen; a lookup never walks on for ever in an app that builds them without end.
    static let limit = 3000

    static func title(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "….")))
    }

    // ⌘+ or ⌘= (⇧ allowed, as + is ⇧= on most keyboards), and ⌘- or ⌘− (a minus sign, as some apps show it).
    static func zoomsIn(_ item: ZoomItem) -> Bool { ["+", "="].contains(item.key) && item.modifiers & ~1 == 0 }
    static func zoomsOut(_ item: ZoomItem) -> Bool { ["-", "−"].contains(item.key) && item.modifiers & ~1 == 0 }

    static func looksLikeZoom(_ item: ZoomItem) -> Bool {
        let name = title(item.title)
        return [inTitles, outTitles, biggerTitles, smallerTitles].contains { $0.contains(name) } || zoomsIn(item) || zoomsOut(item)
    }

    // The best pair: Zoom In over Bigger, either better with the usual shortcut, and better again in the same menu.
    // Titles are English; for an app in another language, the usual shortcuts side by side in one menu will do.
    static func pick(_ entries: [Entry]) -> ZoomMenu? {
        func score(_ entry: Entry, _ zoom: Set<String>, _ size: Set<String>, key: (ZoomItem) -> Bool) -> Int {
            let name = title(entry.item.title)
            return (zoom.contains(name) ? 4 : size.contains(name) ? 2 : 0) + (key(entry.item) ? 1 : 0)
        }
        let ins = entries.map { ($0, score($0, inTitles, biggerTitles, key: zoomsIn)) }.filter { $0.1 > 0 }
        let outs = entries.map { ($0, score($0, outTitles, smallerTitles, key: zoomsOut)) }.filter { $0.1 > 0 }
        var best: (ZoomMenu, Int)?
        for (i, inScore) in ins {
            for (o, outScore) in outs {
                let together = i.menu == o.menu
                // Shortcuts alone are only trusted side by side: Word's ⌘= is Subscript.
                if inScore < 2 || outScore < 2, !together { continue }
                let total = inScore + outScore + (together ? 1 : 0)
                if total > best?.1 ?? 0 { best = (ZoomMenu(zoomIn: i.item, zoomOut: o.item), total) }
            }
        }
        return best?.0
    }

    // Menu bar, its menus and up to two levels of submenus, skipping the Apple menu. Off the main thread: an app
    // answers on its own main thread, and a busy one can take a while. nil when there was nothing to read: no menu bar
    // or an empty one, as an app has in the first moments after it opens (Claude's read in 0 ms as it relaunched).
    static func read(_ pid: pid_t) -> [Entry]? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        guard let bar = element(app, kAXMenuBarAttribute) else { return nil }
        var entries: [Entry] = []
        var menus = 0
        func walk(_ menu: AXUIElement, depth: Int) {
            menus += 1
            let id = menus
            for item in children(menu) where entries.count < limit {
                let names = [kAXTitleAttribute, kAXMenuItemCmdCharAttribute, kAXMenuItemCmdModifiersAttribute, kAXChildrenAttribute]
                var values: CFArray?
                guard AXUIElementCopyMultipleAttributeValues(item, names as CFArray, [], &values) == .success,
                      let list = values as? [AnyObject], list.count == names.count else { continue }
                let key = (list[1] as? String).flatMap { $0.isEmpty ? nil : $0 }
                entries.append(Entry(item: ZoomItem(title: list[0] as? String ?? "", key: key, modifiers: (list[2] as? Int) ?? 0,
                                                    element: item), menu: id))
                if depth < 3, let submenu = (list[3] as? [AXUIElement])?.first { walk(submenu, depth: depth + 1) }
            }
        }
        for top in children(bar).dropFirst() {
            if let menu = children(top).first { walk(menu, depth: 1) }
        }
        return entries.isEmpty ? nil : entries
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return (value as? [AXUIElement]) ?? []
    }
}

// Each app's Zoom In and Zoom Out, read in the background and kept a while, so a scroll never waits on Accessibility.
// An app whose menus can't be read yet is tried again shortly, not taken as having no zoom. Main thread.
final class ZoomMenuCache {
    // What a read found: the app's zoom or none (nil), or nothing to go by yet.
    enum Read {
        case failed
        case read(ZoomMenu?)
    }

    // Menus rarely change; an app found with none may still be building its menus, so it's read again sooner.
    static let fresh: TimeInterval = 300
    static let freshNone: TimeInterval = 30
    // An app just opened has no menu bar to read for a moment: tried again every second, for half a minute.
    static let retry: TimeInterval = 1
    static let tries = 30

    var read: (pid_t) -> Read = { pid in ZoomMenus.read(pid).map { .read(ZoomMenus.pick($0)) } ?? .failed }
    var report: (String) -> Void = { log($0) }
    var after: (TimeInterval, @escaping () -> Void) -> Void = { delay, work in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) }
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var reader = DispatchQueue(label: "wheel zoom menus", qos: .userInitiated)
    private var known: [pid_t: (lookup: ZoomLookup, at: TimeInterval)] = [:]
    private var reading: Set<pid_t> = []
    private var failures: [pid_t: Int] = [:]

    // What's known now; read again in the background if it's missing or old.
    func lookup(_ pid: pid_t) -> ZoomLookup {
        let entry = known[pid]
        let age: TimeInterval
        if case .found = entry?.lookup { age = Self.fresh } else { age = Self.freshNone }
        if entry.map({ now() - $0.at > age }) ?? true { refresh(pid) }
        return entry?.lookup ?? .reading
    }

    func forget(_ pid: pid_t) {
        known[pid] = nil
        failures[pid] = nil
    }

    private func refresh(_ pid: pid_t) {
        guard pid > 0, !reading.contains(pid) else { return }
        reading.insert(pid)
        let read = self.read
        let now = self.now
        reader.async { [weak self] in
            let start = now()
            let result = read(pid)
            let took = Int((now() - start) * 1000)
            DispatchQueue.main.async { self?.finished(pid, result, took: took) }
        }
    }

    private func finished(_ pid: pid_t, _ result: Read, took: Int) {
        reading.remove(pid)
        let app = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "pid \(pid)"
        guard case .read(let menu) = result else {
            // A read again that fails keeps what was found before, until it's next due.
            if known[pid] != nil {
                known[pid]?.at = now()
                return
            }
            let tried = (failures[pid] ?? 0) + 1
            failures[pid] = tried
            if tried < Self.tries {
                // Still unknown, so a scroll goes by as it came meanwhile; the next try needs no scroll to start it.
                after(Self.retry) { [weak self] in
                    guard let self, self.failures[pid] != nil else { return }
                    self.refresh(pid)
                }
                return
            }
            failures[pid] = nil
            known[pid] = (.none, now())
            report("wheel zoom: \(app)'s menus couldn't be read in \(tried) tries; trying again in \(Int(Self.freshNone)) s")
            return
        }
        let first = known[pid] == nil
        let tries = failures.removeValue(forKey: pid).map { " after \($0 + 1) tries" } ?? ""
        known[pid] = (menu.map { .found($0) } ?? .none, now())
        guard first else { return }
        report("wheel zoom: \(app) " + (menu.map { "zooms with \($0.zoomIn.title) \($0.zoomIn.shortcut) and \($0.zoomOut.title) \($0.zoomOut.shortcut)" }
            ?? "has no Zoom In and Zoom Out") + " (menus read in \(took) ms\(tries))")
    }
}
