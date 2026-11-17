import AppKit

// Sends another app a few lines of AppleScript. macOS asks the user once whether RubberMAC may control that app; a "no"
// comes back as notPermitted, which the caller shows rather than retrying.
enum AppScript {
    static let notPermitted = Int(errAEEventNotPermitted)

    struct Failure: Error {
        let code: Int
        let message: String
    }

    static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    @discardableResult
    static func run(_ source: String) throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: source) else { throw Failure(code: -1, message: "couldn't compile") }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            throw Failure(code: error[NSAppleScript.errorNumber] as? Int ?? -1, message: error[NSAppleScript.errorMessage] as? String ?? "")
        }
        return result
    }

    // Quotes text for an AppleScript string literal.
    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
