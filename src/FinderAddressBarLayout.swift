import AppKit

// Where the address bar's strip goes on a Finder window, and how a folder reads in it. Pure, so the self-test can
// check it without Finder.
enum FinderAddressBarLayout {
    static let height: CGFloat = 28
    static let inset: CGFloat = 8
    static let gap: CGFloat = 2
    // A window with its toolbar hidden still has a title bar this tall.
    static let titleBar: CGFloat = 28
    // A tab bar is a slim row; a taller tab group is part of what the window shows.
    static let tabBarLimit: CGFloat = 48

    // How far below the window's top edge the strip starts: under the toolbar, and under the tab bar when there are
    // several tabs, else under the title bar. Frames are in Accessibility coordinates (y grows down).
    static func top(window: CGRect, toolbar: CGRect?, tabGroups: [CGRect]) -> CGFloat {
        let bars = barsBottom(window: window, toolbar: toolbar)
        let bottom = max(bars, tabBar(window: window, toolbar: toolbar, tabGroups: tabGroups)?.maxY ?? bars)
        return bottom - window.minY + gap
    }

    // The tab bar starts where the toolbar ends, or inside it; a tab group lower down is part of the window's content.
    static func tabBar(window: CGRect, toolbar: CGRect?, tabGroups: [CGRect]) -> CGRect? {
        let bars = barsBottom(window: window, toolbar: toolbar)
        return tabGroups.first { $0.height <= tabBarLimit && $0.minY >= window.minY - 1 && $0.minY <= bars + 8 }
    }

    private static func barsBottom(window: CGRect, toolbar: CGRect?) -> CGFloat {
        max(toolbar?.maxY ?? 0, window.minY + titleBar)
    }

    // The strip across a window, from its Accessibility frame to AppKit coordinates (origin at the bottom left of the
    // primary screen), which places it right on any screen. It stays inside a window too short for it.
    static func strip(window: CGRect, top: CGFloat, primaryHeight: CGFloat) -> NSRect {
        let y = window.minY + min(top, max(0, window.height - height))
        return NSRect(x: (window.minX + inset).rounded(), y: (primaryHeight - y - height).rounded(),
                      width: max(0, window.width - 2 * inset).rounded(), height: height)
    }

    // A folder's full path, with the home folder as ~.
    static func shown(_ folder: URL, home: String = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)) -> String {
        func trimmed(_ path: String) -> String { path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path }
        let path = trimmed(folder.path(percentEncoded: false)), home = trimmed(home)
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
