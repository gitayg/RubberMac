import Foundation

// Terminal's default profile (and the startup one, if it's another) in Atkinson Hyperlegible Mono: a terminal lays text
// out in equal cells, which leaves gaps around narrow letters of a proportional font. While Terminal is open it's told
// over AppleScript, so open windows using the profile change at once, at their size; while it's closed, the profile in
// its settings is rewritten. Turning it off puts back each profile's own font, as it was archived.
struct TerminalFont: FontTarget {
    var id = "terminal"
    let appName = "Terminal"
    let bundleID = "com.apple.Terminal"
    let whatChanges = "its default profile, open windows included"
    var prefs = AppPrefs(domain: "com.apple.Terminal")
    var isRunning: () -> Bool = { AppScript.isRunning("com.apple.Terminal") }

    var profiles: [String] {
        var names: [String] = []
        for key in ["Default Window Settings", "Startup Window Settings"] {
            if let name = prefs.string(key), !names.contains(name) { names.append(name) }
        }
        return names
    }

    private var windowSettings: [String: Any] { prefs.value("Window Settings") as? [String: Any] ?? [:] }

    func fontData(_ profile: String) -> Data? {
        (windowSettings[profile] as? [String: Any])?["Font"] as? Data
    }

    var isOn: Bool {
        let names = profiles
        return !names.isEmpty && names.allSatisfy { ArchivedFont.name(in: fontData($0)) == BundledFont.monoRegular }
    }

    func turnOn() throws {
        guard !isOn else { return }
        let before = profiles.reduce(into: [String: Any]()) { $0[$1] = fontData($1) }
        FontTargetMemory.remember(id, before)
        for profile in profiles {
            if isRunning() {
                try AppScript.run("tell application id \"com.apple.Terminal\" to set font name of settings set \(AppScript.quoted(profile)) to \(AppScript.quoted(BundledFont.monoRegular))")
            } else {
                let size = ArchivedFont.size(in: fontData(profile)) ?? 12
                guard let font = ArchivedFont.data(name: BundledFont.monoRegular, size: size) else { throw ArchivedFont.Missing() }
                try setFontData(font, for: profile)
            }
        }
    }

    func turnOff() throws {
        let before = FontTargetMemory.before(id) ?? [:]
        for (profile, value) in before {
            guard let data = value as? Data else { continue }
            if isRunning() {
                guard let name = ArchivedFont.name(in: data) else { continue }
                try AppScript.run("tell application id \"com.apple.Terminal\" to set font name of settings set \(AppScript.quoted(profile)) to \(AppScript.quoted(name))")
            } else {
                try setFontData(data, for: profile)
            }
        }
        FontTargetMemory.forget(id)
    }

    // Only while Terminal is closed: it writes its profiles back from memory.
    private func setFontData(_ data: Data, for profile: String) throws {
        var all = windowSettings
        guard var settings = all[profile] as? [String: Any] else { return }
        settings["Font"] = data
        all[profile] = settings
        try prefs.set(["Window Settings": all])
    }
}
