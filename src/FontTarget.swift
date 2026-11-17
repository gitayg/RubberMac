import AppKit

// One app whose text RubberMAC can set in Atkinson Hyperlegible, shown by its icon on the Writing page. Whether it's on
// is read from the app's own settings each time, so a font the user picked there since shows as off; turning it off puts
// back what the app had before, which RubberMAC keeps from the moment it turned it on.
protocol FontTarget {
    var id: String { get }
    var appName: String { get }
    var bundleID: String { get }
    // What changes, in a few words, shown under the row's title while the pointer is on the icon.
    var whatChanges: String { get }
    var isOn: Bool { get }
    func turnOn() throws
    func turnOff() throws
}

extension FontTarget {
    var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }
    var isInstalled: Bool { appURL != nil }
    var icon: NSImage { appURL.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage() }
}

// What each app had before RubberMAC changed it, so turning it off restores exactly that, a missing setting included.
enum FontTargetMemory {
    private static let defaults = UserDefaults.standard
    private static func key(_ id: String) -> String { "fontTarget.\(id).before" }

    static func before(_ id: String) -> [String: Any]? { defaults.dictionary(forKey: key(id)) }
    static func remember(_ id: String, _ values: [String: Any]) { defaults.set(values, forKey: key(id)) }
    static func forget(_ id: String) { defaults.removeObject(forKey: key(id)) }
}
