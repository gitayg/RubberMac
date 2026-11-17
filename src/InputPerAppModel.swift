import Foundation

// What the per-app languages decide, apart from the system around them: which language an app gets when it comes
// forward, which changes were the user's to remember, and what a search puts back when it closes. InputPerApp feeds
// it the real events on the main thread; the self-test feeds it made-up ones.
final class InputPerAppModel {
    struct System {
        var current: () -> String
        // Returns the source in use afterwards: the one asked for, unless it's no longer enabled.
        var select: (String) -> String
        var english: () -> String?
        var save: ([String: String]) -> Void
    }

    // Not apps to the user, so they neither get a language nor count as switching apps: Spotlight's search bar and
    // its Apps view. RubberMAC's own panels join them.
    static let notApps: Set<String> = ["com.apple.Siri", "com.apple.Spotlight", "com.apple.apps.launcher"]

    var perApp = true
    var searchEnglish = true
    private(set) var memory: [String: String]
    // The last real app in front; Spotlight or a RubberMAC panel coming forward leaves it as it was.
    private(set) var app: String?
    // The app a search was opened over, and the language it had then.
    private(set) var search: (app: String?, source: String)?
    private let system: System
    private let notApps: Set<String>
    private var front: String?
    // The source as last seen or set. A change notice that finds it still in use is a switch RubberMAC made itself,
    // or a second notice for one switch.
    private var known: String

    init(system: System, memory: [String: String], ownBundleID: String?, front: String?) {
        self.system = system
        self.memory = memory
        notApps = Self.notApps.union([ownBundleID].compactMap { $0 })
        known = system.current()
        self.front = front
        if let front, !notApps.contains(front) { app = front }
    }

    func activated(_ bundleID: String?) {
        // A switch whose notice hasn't come yet was made in the app that's leaving.
        sourceChanged()
        front = bundleID
        guard let bundleID, !notApps.contains(bundleID) else { return }
        app = bundleID
        if let search {
            // Back in the app it was opened over: the search closed. Anywhere else, it was left for that app.
            if search.app == bundleID { return searchEnded() }
            self.search = nil
        }
        if perApp, let wanted = memory[bundleID] { set(wanted) }
    }

    func sourceChanged() {
        let now = system.current()
        guard now != known else { return }
        known = now
        guard perApp, search == nil, let app, front == app, memory[app] != now else { return }
        memory[app] = now
        system.save(memory)
    }

    func searchStarted() {
        guard searchEnglish, search == nil else { return }
        sourceChanged()
        search = (app, known)
        if let english = system.english() { set(english) }
    }

    func searchEnded() {
        guard let search else { return }
        // A switch made in the search was for the search, not the app.
        sourceChanged()
        self.search = nil
        if search.app == app { set(search.source) }
    }

    private func set(_ source: String) {
        guard source != known else { return }
        known = system.select(source)
    }
}
