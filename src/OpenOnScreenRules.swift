import AppKit

// An app whose new windows always open on one screen, known by vendor, model and serial as CameraArea keys it.
struct OpenOnScreenRule: Codable, Equatable {
    // The app's bundle ID.
    let app: String
    let appName: String
    var screen: String
    // The screen's name when it was chosen, for the popup while it's not connected.
    var screenName: String

    struct Choice: Equatable {
        let title: String
        let key: String
        let on: Bool
    }

    // Each connected screen; the chosen one stays listed, as chosen, while it isn't connected.
    func choices(_ displays: [DockScreen.Display]) -> [Choice] {
        var list = displays.map { Choice(title: $0.name, key: $0.key, on: $0.key == screen) }
        if !displays.contains(where: { $0.key == screen }) {
            list.append(Choice(title: "\(screenName) (not connected)", key: screen, on: true))
        }
        return list
    }

    static func encode(_ rules: [OpenOnScreenRule]) -> Data? {
        try? JSONEncoder().encode(rules)
    }

    static func decode(_ data: Data?) -> [OpenOnScreenRule] {
        data.flatMap { try? JSONDecoder().decode([OpenOnScreenRule].self, from: $0) } ?? []
    }
}

extension Settings {
    // Off unless turned on: windows jumping screens is a surprise to anyone who didn't ask for it.
    static var openOnScreenEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "openOnScreenEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "openOnScreenEnabled") }
    }

    // In the order they were added.
    static var openOnScreenRules: [OpenOnScreenRule] {
        get { OpenOnScreenRule.decode(UserDefaults.standard.data(forKey: "openOnScreenRules")) }
        set { UserDefaults.standard.set(OpenOnScreenRule.encode(newValue), forKey: "openOnScreenRules") }
    }
}
