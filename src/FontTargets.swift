import AppKit

// The apps on the Writing page that can use Atkinson Hyperlegible, in the order their icons show; only installed ones.
enum FontTargets {
    static var all: [FontTarget] { [PadFont(), TextEditFont(), MailFont(), TerminalFont(), ChromeFont(), FirefoxFont()] }

    // Changes that waited for an app to quit: run when one quits, and as RubberMAC starts.
    static func applyPending(_ targets: [FontTarget] = all) {
        for case let target as QuitFirstFont in targets {
            do {
                if try target.applyPending() { log("font: \(target.appName) \(target.isApplied ? "on" : "off"), now that it's quit") }
            } catch {
                log("font: couldn't change \(target.appName) now that it's quit (error \((error as NSError).code))")
            }
        }
    }
    static var installed: [FontTarget] { all.filter(\.isInstalled) }

    static func apps(_ targets: [FontTarget] = installed) -> [FontAppIcons.App] {
        targets.map { FontAppIcons.App(id: $0.id, name: $0.appName, whatChanges: $0.whatChanges, isOn: $0.isOn, icon: $0.icon) }
    }

    // Turns one on or off, and what to tell the user if that didn't work.
    static func toggle(_ id: String, in targets: [FontTarget] = all) -> String? {
        guard let target = targets.first(where: { $0.id == id }) else { return nil }
        let turningOn = !target.isOn
        do {
            if turningOn { try target.turnOn() } else { try target.turnOff() }
            log("font: \(target.appName) \(turningOn ? "on" : "off")")
            return nil
        } catch let failure as AppScript.Failure where failure.code == AppScript.notPermitted {
            log("font: couldn't turn \(target.appName) \(turningOn ? "on" : "off"), RubberMAC isn't allowed to control it")
            return "RubberMAC isn't allowed to control \(target.appName). You can allow it in System Settings, under Privacy & Security, Automation."
        } catch {
            log("font: couldn't turn \(target.appName) \(turningOn ? "on" : "off") (error \((error as NSError).code))")
            return "Couldn't change \(target.appName)'s font."
        }
    }

    // Before the font files go: every app RubberMAC set gets its own font back, so none is left asking for a missing one.
    static func turnAllOff(_ targets: [FontTarget] = all) {
        for target in targets where target.isOn {
            _ = toggle(target.id, in: targets)
        }
    }
}
