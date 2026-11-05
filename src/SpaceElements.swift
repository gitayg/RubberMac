import ApplicationServices
import Foundation
import Synchronization

// Accessibility elements of windows, per app and window number, so a window on another Space, which
// kAXWindowsAttribute leaves out, can still be listed and focused. Each snapshot adds the windows it was given, and
// the rest are found in the background by trying the app's element numbers. A cached element only reaches a
// window: the snapshot checks every time that the window is still there.
enum SpaceElements {
    private struct App {
        var elements: [CGWindowID: AXUIElement] = [:]
        // Windows searched for and not found: when, whether they were ordered in then, and whether the app answered
        // every try (if it did, the window isn't one Accessibility shows, and looking again won't change that).
        var missed: [CGWindowID: (at: Date, orderedIn: Bool, answered: Bool)] = [:]
        var searching = false
    }

    private static let apps = Mutex<[pid_t: App]>([:])
    private static let queue = DispatchQueue(label: "space elements", qos: .utility,
                                             attributes: .concurrent)
    // A hung app would otherwise block each try for the 6 s default.
    private static let timeout: Float = 0.25
    // An app that has run for long has handed out higher element numbers (Chrome's reached 2,780 after a week). A
    // window shown on another Space is surely there to find, so for one the search goes further from the start.
    private static let firstLimit: UInt64 = 5_000
    private static let shownLimit: UInt64 = 20_000
    private static let lastLimit: UInt64 = 80_000
    // After an app stopped answering partway.
    private static let retry: TimeInterval = 60

    static func element(pid: pid_t, window: CGWindowID) -> AXUIElement? {
        apps.withLock { $0[pid]?.elements[window] }
    }

    static func remember(pid: pid_t, _ found: [CGWindowID: AXUIElement]) {
        guard !found.isEmpty else { return }
        apps.withLock { apps in
            apps[pid, default: App()].elements.merge(found) { _, new in new }
            for id in found.keys { apps[pid]?.missed[id] = nil }
        }
    }

    // A window whose element stopped answering (closed, then shown again with a new one).
    static func forget(pid: pid_t, window: CGWindowID) {
        apps.withLock { _ = $0[pid]?.elements.removeValue(forKey: window) }
    }

    // Drops apps that quit and windows that are gone, so the cache stays the size of what's open.
    static func keep(pids: Set<pid_t>, windows: Set<CGWindowID>) {
        apps.withLock { apps in
            apps = apps.filter { pids.contains($0.key) }.mapValues { app in
                var app = app
                app.elements = app.elements.filter { windows.contains($0.key) }
                app.missed = app.missed.filter { windows.contains($0.key) }
                return app
            }
        }
    }

    // wanted: window number → whether it's ordered in. Searches in the background, one search per app at a time.
    static func find(pid: pid_t, _ wanted: [CGWindowID: Bool]) {
        let now = Date()
        let due: Set<CGWindowID>? = apps.withLock { apps in
            var app = apps[pid, default: App()]
            guard !app.searching else { return nil }
            let due = Set(wanted.filter { id, orderedIn in
                guard let miss = app.missed[id] else { return true }
                return miss.orderedIn != orderedIn || (!miss.answered && now.timeIntervalSince(miss.at) > retry)
            }.keys)
            guard !due.isEmpty else { return nil }
            app.searching = true
            apps[pid] = app
            return due
        }
        guard let due else { return }
        queue.async {
            let (found, answered) = search(pid: pid, for: due, far: due.contains { wanted[$0] == true })
            apps.withLock { apps in
                apps[pid, default: App()].searching = false
                apps[pid]?.elements.merge(found) { _, new in new }
                for id in due where found[id] == nil { apps[pid]?.missed[id] = (Date(), wanted[id] ?? false, answered) }
            }
        }
    }

    // Tries element numbers from 0 until every wanted window is found, keeping every window met on the way.
    // answered: false when the app stopped answering before the end.
    private static func search(pid: pid_t, for wanted: Set<CGWindowID>, far: Bool)
        -> (found: [CGWindowID: AXUIElement], answered: Bool) {
        var found: [CGWindowID: AXUIElement] = [:]
        var limit = far ? shownLimit : firstLimit
        var highest: UInt64 = 0
        var number: UInt64 = 0
        while number < limit {
            // Live elements past the middle mean there may be more beyond.
            if number == limit - 1, highest > limit / 2, limit < lastLimit { limit *= 4 }
            defer { number += 1 }
            guard let element = SpaceWindows.element(pid: pid, number: number) else { return (found, false) }
            AXUIElementSetMessagingTimeout(element, timeout)
            var role: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            if error == .cannotComplete { return (found, false) }
            guard error == .success else { continue }
            highest = number
            guard role as? String == kAXWindowRole as String, let id = AX.windowID(of: element) else { continue }
            found[id] = element
            if wanted.allSatisfy({ found[$0] != nil }) { break }
        }
        return (found, true)
    }

    // For the self-test.
    static func clear() {
        apps.withLock { $0 = [:] }
    }

    static var isSearching: Bool {
        apps.withLock { $0.values.contains { $0.searching } }
    }
}
