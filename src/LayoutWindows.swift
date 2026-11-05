import AppKit

// Reads and moves real windows through the Accessibility API. Only sees windows on the current Space.
enum LayoutWindows {
    struct Live {
        let element: AXUIElement
        let title: String
        let index: Int
        let frame: CGRect
        let minimized: Bool
    }

    struct RestoreResult {
        var moved = 0, alreadyThere = 0, offScreen = 0, minimized = 0, unmatched = 0
    }

    static func snapshot() -> [LayoutWindow] {
        appsByBundle().flatMap { bundleID, apps in
            windows(of: apps).map {
                LayoutWindow(bundleID: bundleID, appName: apps[0].localizedName ?? bundleID, title: $0.title,
                             index: $0.index, frame: $0.frame, minimized: $0.minimized)
            }
        }
    }

    static func restore(_ snapshot: LayoutSnapshot, screens: [CGRect]) -> RestoreResult {
        let wanted = Dictionary(grouping: snapshot.windows, by: \.bundleID)
        var result = RestoreResult()
        var matched = 0
        for (bundleID, apps) in appsByBundle() {
            guard let saved = wanted[bundleID] else { continue }
            let live = windows(of: apps)
            let pairs = LayoutMatcher.match(saved: saved.map { ($0.title, $0.index) }, current: live.map { ($0.title, $0.index) })
            matched += pairs.count
            for (s, c) in pairs {
                let target = saved[s].frame, window = live[c]
                if window.minimized {
                    result.minimized += 1
                } else if !LayoutMatcher.isOnScreen(target, screens: screens) {
                    result.offScreen += 1
                } else if LayoutMatcher.isSame(window.frame, target) {
                    result.alreadyThere += 1
                } else {
                    AX.setFrame(window.element, target)
                    result.moved += 1
                }
            }
        }
        result.unmatched = snapshot.windows.count - matched
        return result
    }

    // Several running copies of one app (rare) share a bundle ID; treat their windows as one list.
    private static func appsByBundle() -> [(String, [NSRunningApplication])] {
        let mine = getpid()
        var order: [String] = []
        var apps: [String: [NSRunningApplication]] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier != mine {
            guard let id = app.bundleIdentifier else { continue }
            if apps[id] == nil { order.append(id) }
            apps[id, default: []].append(app)
        }
        return order.map { ($0, apps[$0]!) }
    }

    private static func windows(of apps: [NSRunningApplication]) -> [Live] {
        var result: [Live] = []
        for app in apps {
            for element in AX.windows(of: app.processIdentifier) {
                guard let frame = AX.frame(of: element), frame.width > 0, frame.height > 0 else { continue }
                result.append(Live(element: element, title: AX.string(element, kAXTitleAttribute) ?? "", index: result.count,
                                   frame: frame, minimized: AX.bool(element, kAXMinimizedAttribute) ?? false))
            }
        }
        return result
    }
}
