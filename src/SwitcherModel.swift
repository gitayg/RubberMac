import CoreGraphics
import Foundation

protocol SwitcherOrderable {
    var windowID: CGWindowID? { get }
    var isMinimized: Bool { get }
}

// The switcher's pure rules, kept free of Accessibility calls so they can be tested.
enum SwitcherModel {
    static let standardWindowSubrole = "AXStandardWindow"
    static let dialogSubrole = "AXDialog"

    // AppKit reports a window that isn't ordered in (minimized, or its app hidden) as a dialog.
    static func keeps(subrole: String?, minimized: Bool, appHidden: Bool = false) -> Bool {
        minimized || subrole == standardWindowSubrole || (appHidden && subrole == dialogSubrole)
    }

    // A window on another Space, which kAXWindowsAttribute leaves out. One that isn't ordered in is minimized or
    // closed (an app may keep a closed window, and it stays on its Space), so only a minimized one counts.
    static func keepsElsewhere(subrole: String?, minimized: Bool, orderedIn: Bool) -> Bool {
        orderedIn ? subrole == standardWindowSubrole : minimized
    }

    static func displayTitle(_ title: String?, appName: String) -> String {
        guard let title, !title.trimmingCharacters(in: .whitespaces).isEmpty else { return appName }
        return title
    }

    // Normal windows of the frontmost layer, front to back, from CGWindowListCopyWindowInfo.
    static func layerZeroIDs(_ info: [[String: Any]]) -> [CGWindowID] {
        info.compactMap { window in
            guard (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else { return nil }
            return (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }
    }

    // Most recently used first: on-screen windows in the order they last had focus, then the rest by z-order
    // (activating an app raises all its windows, so z-order alone puts them ahead of the window used before).
    // Windows that aren't on screen (hidden apps) follow, minimized windows come last, each also by focus.
    static func ordered<T: SwitcherOrderable>(_ items: [T], recent: [CGWindowID] = [], zOrder: [CGWindowID]) -> [T] {
        let depth = positions(zOrder)
        let rank = positions(recent)
        func key(_ i: Int) -> (Int, Int, Int, Int) {
            let item = items[i]
            let used = item.windowID.flatMap { rank[$0] } ?? Int.max
            if item.isMinimized { return (2, used, 0, i) }
            if let id = item.windowID, let z = depth[id] { return (0, used, z, i) }
            return (1, used, 0, i)
        }
        return items.indices.sorted { key($0) < key($1) }.map { items[$0] }
    }

    private static func positions(_ ids: [CGWindowID]) -> [CGWindowID: Int] {
        Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // The previous window (index 1), or the last one when going backwards. When the first window isn't the
    // focused app's (the desktop or a windowless app has focus), the first one is the window to go back to.
    static func initialSelection(count: Int, reverse: Bool, currentFirst: Bool = true) -> Int? {
        guard count > 0 else { return nil }
        guard count > 1 else { return 0 }
        if reverse { return count - 1 }
        return currentFirst ? 1 : 0
    }

    static func step(_ index: Int, count: Int, reverse: Bool) -> Int {
        guard count > 0 else { return 0 }
        return (index + (reverse ? count - 1 : 1)) % count
    }
}
