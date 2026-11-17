import AppKit

// An app on the Start grid, by the path it was found at.
struct StartMenuApp: Equatable {
    let path: String
    let name: String
    // Under /System, as Safari is behind its link in /Applications: read-only, so it can't go to the Trash.
    let isSystem: Bool

    var url: URL { URL(fileURLWithPath: path) }
}

// The apps in the Applications folders, as Spotlight's Apps view lists them.
enum StartMenuApps {
    static let roots = [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"),
                        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
    // Folders such as Utilities, or a vendor's folder holding its app and uninstaller, are looked in; deeper ones aren't.
    static let depth = 3

    // By name. An app reached twice (a link to another listed app) is listed once.
    static func scan(_ roots: [URL] = roots) -> [StartMenuApp] {
        var found: [StartMenuApp] = []
        var seen = Set<String>()
        func visit(_ folder: URL, _ depth: Int) {
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .isHiddenKey]
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in names where !name.hasPrefix(".") {
                // Under the folder's path as given: the listing would write /var/folders as /private/var/folders.
                let entry = folder.appendingPathComponent(name)
                guard let values = try? entry.resourceValues(forKeys: keys) else { continue }
                if entry.pathExtension == "app" {
                    let real = entry.resolvingSymlinksInPath()
                    let isSystem = real.path.hasPrefix("/System/")
                    // Safari's link in /Applications is flagged hidden, yet Finder and Spotlight show it; other hidden
                    // apps stay hidden.
                    guard values.isHidden != true || isSystem,
                          (try? real.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                          seen.insert(real.path).inserted else { continue }
                    found.append(StartMenuApp(path: entry.path, name: Self.name(of: entry), isSystem: isSystem))
                    continue
                }
                // Not into links, which can loop, nor into packages such as a .bundle, nor into hidden folders.
                guard depth > 1, values.isDirectory == true, values.isSymbolicLink != true, values.isPackage != true,
                      values.isHidden != true else { continue }
                visit(entry, depth - 1)
            }
        }
        roots.forEach { visit($0, depth) }
        return found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // The name Finder shows, in the user's language ("System Settings", not "System Settings.app").
    static func name(of url: URL) -> String {
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}

// App icons, read once each.
enum StartMenuIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(_ path: String) -> NSImage {
        if let icon = cache[path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: path)
        cache[path] = icon
        return icon
    }
}
