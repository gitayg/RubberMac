import AppKit

// Apps that remember where their windows were and how big: the frames AppKit saves under each window's and split
// view's autosave name in the app's preferences (in its container for a sandboxed app), and the windows macOS keeps in
// Saved Application State to reopen it with. Files are found by name, and only an app that's offered has its file
// opened, straight from disk rather than a trip to the preferences daemon for each of the hundreds of domains on a Mac.
// An Apple app's file can sit behind a macOS privacy question (opening Music's asked for its media library, in the
// live self-test), so those are never opened here: an Apple app with preferences or saved windows is listed unread,
// and which of its keys are window sizes is read through defaults once it has been chosen.
enum WindowResetSavedFrames {
    struct App: Equatable {
        let bundleID: String
        let name: String
        let url: URL
        var keys: [String] = []
        // A sandboxed app's preferences domain, as a path without .plist, which is how defaults takes one.
        var container: URL?
        var containerKeys: [String] = []
        // Where macOS keeps its windows, whether or not there are any.
        var savedState: URL
        var hasSavedState = false
        // An Apple app's preferences, listed without being opened.
        var unread = false
    }

    struct Places {
        var preferences: URL
        var savedState: URL
        // Nil when RubberMAC may not look into other apps' containers.
        var containers: URL?
    }

    struct Scan {
        var apps: [App] = []
        // A container macOS wouldn't let RubberMAC read.
        var refused = false
    }

    static let prefixes = ["NSWindow Frame ", "NSSplitView Subview Frames "]

    static func isFrameKey(_ key: String) -> Bool {
        prefixes.contains { key.hasPrefix($0) }
    }

    // Sorted by name. resolve gives the app for a bundle ID, nil for one not to offer.
    static func scan(_ places: Places, resolve: (String) -> (name: String, url: URL)?) -> Scan {
        let fm = FileManager.default
        var scan = Scan()
        var found: [String: App] = [:]
        func app(_ id: String) -> App? {
            if let known = found[id] { return known }
            return resolve(id).map {
                App(bundleID: id, name: $0.name, url: $0.url, savedState: places.savedState.appendingPathComponent("\(id).savedState"))
            }
        }
        for file in (try? fm.contentsOfDirectory(atPath: places.preferences.path)) ?? [] where file.hasSuffix(".plist") {
            let id = String(file.dropLast(6))
            guard var entry = app(id) else { continue }
            if mayOpen(id) {
                entry.keys = frameKeys(in: places.preferences.appendingPathComponent(file), refused: &scan.refused)
                guard !entry.keys.isEmpty else { continue }
            } else {
                entry.unread = true
            }
            found[id] = entry
        }
        if let containers = places.containers {
            for id in (try? fm.contentsOfDirectory(atPath: containers.path)) ?? [] {
                guard var entry = app(id) else { continue }
                let domain = containers.appendingPathComponent("\(id)/Data/Library/Preferences/\(id)")
                if mayOpen(id) {
                    entry.containerKeys = frameKeys(in: domain.appendingPathExtension("plist"), refused: &scan.refused)
                    guard !entry.containerKeys.isEmpty else { continue }
                } else {
                    guard fm.fileExists(atPath: domain.path + ".plist") else { continue }
                    entry.unread = true
                }
                entry.container = domain
                found[id] = entry
            }
        }
        for folder in (try? fm.contentsOfDirectory(at: places.savedState, includingPropertiesForKeys: nil)) ?? []
        where folder.pathExtension == "savedState" {
            guard var entry = app(folder.deletingPathExtension().lastPathComponent) else { continue }
            entry.hasSavedState = true
            found[entry.bundleID] = entry
        }
        scan.apps = found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return scan
    }

    static func mayOpen(_ bundleID: String) -> Bool {
        !bundleID.hasPrefix("com.apple.")
    }

    static func frameKeys(in plist: URL, refused: inout Bool) -> [String] {
        do {
            let data = try Data(contentsOf: plist)
            let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            return (dictionary ?? [:]).keys.filter(isFrameKey).sorted()
        } catch {
            if (error as NSError).code == NSFileReadNoPermissionError { refused = true }
            return []
        }
    }

    static func realPlaces() -> Places {
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        return Places(preferences: library.appendingPathComponent("Preferences"),
                      savedState: library.appendingPathComponent("Saved Application State"),
                      containers: hasFullDiskAccess ? library.appendingPathComponent("Containers") : nil)
    }

    // Other apps' containers are closed to an app without Full Disk Access: macOS asks the user about each look, or
    // refuses it. Told without asking by a file only Full Disk Access opens; macOS never asks about that one.
    static var hasFullDiskAccess: Bool {
        let probe = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
        let fd = open(probe.path, O_RDONLY)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    // The copy that's open, else the one Launch Services knows.
    static func installedApp(_ bundleID: String) -> (name: String, url: URL)? {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        guard let url = running?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              isOffered(url, bundleID: bundleID) else { return nil }
        let shown = FileManager.default.displayName(atPath: url.path)
        return (running?.localizedName ?? (shown.hasSuffix(".app") ? String(shown.dropLast(4)) : shown), url)
    }

    // An installed app with windows to lose: in a folder apps are installed in, not background-only, not RubberMAC.
    // Finder, the Dock and the login window live elsewhere in /System/Library and are left out with every app kept
    // anywhere else: reading even the name of one run from Downloads or Documents would need macOS's permission for
    // that folder.
    static func isOffered(_ url: URL, bundleID: String) -> Bool {
        bundleID != Bundle.main.bundleIdentifier && isInstalled(url) && !isBackgroundOnly(url)
    }

    static let appFolders = ["/Applications/", "/System/Applications/", "/System/Library/CoreServices/Applications/",
                             FileManager.default.homeDirectoryForCurrentUser.path + "/Applications/"]

    static func isInstalled(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return appFolders.contains { path.hasPrefix($0) }
    }

    static func isBackgroundOnly(_ url: URL) -> Bool {
        let value = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))?["LSBackgroundOnly"]
        return (value as? NSNumber)?.boolValue ?? (value as? NSString)?.boolValue ?? false
    }
}
