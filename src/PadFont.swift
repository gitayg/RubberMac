import Foundation

// RubberMAC's own Writing Pad: what's typed in it and the fixed version.
struct PadFont: FontTarget {
    static let postScriptName = "AtkinsonHyperlegibleNext-Regular"

    let id = "pad"
    let appName = "Writing Pad"
    let bundleID = Bundle.main.bundleIdentifier ?? "app.rubbermac.RubberMAC"
    let whatChanges = "what you type and the fixed version"
    var isOn: Bool { Settings.padUsesAtkinson }
    func turnOn() throws { Settings.padUsesAtkinson = true }
    func turnOff() throws { Settings.padUsesAtkinson = false }
}
