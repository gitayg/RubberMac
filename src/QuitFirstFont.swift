import Foundation

// For an app that writes its settings back from memory, like a browser: changed while it's open, its own copy would
// overwrite the change within seconds. So a click while it's open is kept as a wish, the icon shows it, and the change
// is made the moment the app quits, or when RubberMAC next starts with the app closed.
protocol QuitFirstFont: FontTarget {
    var isRunning: () -> Bool { get }
    var isApplied: Bool { get }
    func apply() throws
    func undo() throws
}

extension QuitFirstFont {
    private var pendingKey: String { "fontTarget.\(id).pending" }

    // true or false while a change waits for the app to quit.
    var pending: Bool? { UserDefaults.standard.object(forKey: pendingKey) as? Bool }

    var isOn: Bool { pending ?? isApplied }

    func turnOn() throws { try change(to: true) }
    func turnOff() throws { try change(to: false) }

    private func change(to on: Bool) throws {
        guard !isRunning() else {
            if on == isApplied { UserDefaults.standard.removeObject(forKey: pendingKey) } else { UserDefaults.standard.set(on, forKey: pendingKey) }
            return
        }
        UserDefaults.standard.removeObject(forKey: pendingKey)
        if on, !isApplied { try apply() }
        if !on, isApplied { try undo() }
    }

    // Makes a waiting change, if there is one and the app is closed. Returns whether it did.
    @discardableResult
    func applyPending() throws -> Bool {
        guard let on = pending, !isRunning() else { return false }
        try change(to: on)
        return true
    }
}
