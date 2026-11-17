import Foundation

// Another app's settings, read and written through the preferences system so a copy cached for that app stays in step.
// A sandboxed app (TextEdit, Mail) keeps them in its container, which macOS only finds by the plist's full path: by
// bundle ID alone, from outside the sandbox, they'd go to a new file in ~/Library/Preferences that the app never reads.
struct AppPrefs {
    let domain: String

    static func sandboxed(_ bundleID: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> AppPrefs {
        AppPrefs(domain: home.appendingPathComponent("Library/Containers/\(bundleID)/Data/Library/Preferences/\(bundleID).plist").path)
    }

    // Only what the app's own settings hold: a lookup that falls back further, inside an AppKit app like this one,
    // also answers with AppKit's built-in fonts (Helvetica, Menlo) for a key the app never set.
    func value(_ key: String) -> Any? {
        CFPreferencesCopyValue(key as CFString, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    func string(_ key: String) -> String? { value(key) as? String }

    func set(_ values: [String: Any], removing removed: [String] = []) throws {
        let user = kCFPreferencesCurrentUser, host = kCFPreferencesAnyHost
        for (key, value) in values { CFPreferencesSetValue(key as CFString, value as CFPropertyList, domain as CFString, user, host) }
        for key in removed { CFPreferencesSetValue(key as CFString, nil, domain as CFString, user, host) }
        guard CFPreferencesSynchronize(domain as CFString, user, host) else { throw AppPrefsError.notSaved(domain) }
    }

    // The keys that have a value now, with it; restore() with the same keys removes the ones that had none.
    func snapshot(_ keys: [String]) -> [String: Any] {
        keys.reduce(into: [:]) { $0[$1] = value($1) }
    }

    func restore(_ keys: [String], from snapshot: [String: Any]) throws {
        try set(snapshot.filter { keys.contains($0.key) }, removing: keys.filter { snapshot[$0] == nil })
    }
}

enum AppPrefsError: Error {
    case notSaved(String)
}
