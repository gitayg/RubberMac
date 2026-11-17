import AppKit

// "Send a Feature Request…": a short form whose text goes to RubberMAC's request server, no account needed.
enum FeatureRequest {
    // The production server; its sandbox twin is https://rubbermac-requests-sandbox.crane.glick.run.
    static let server = URL(string: "https://rubbermac-requests.crane.glick.run")!
    // AppCrane can let a path through without sign-in, but not one under /api, so the app posts here.
    static let path = "requests"
    static let maxCharacters = 2000
    // The server turns away anything bigger, so the form checks before sending.
    static let maxBodyBytes = 8 * 1024
    static let maxEmail = 254

    private static var form: FeatureRequestWindow?

    // Opens the form. Main thread.
    static func open() {
        if form == nil {
            let window = FeatureRequestWindow(server: server)
            window.onClose = { form = nil }
            form = window
        }
        form?.show()
    }

    // Characters are counted as Unicode code points, as the server counts them.
    static func length(_ text: String) -> Int {
        trimmed(text).unicodeScalars.count
    }

    static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var appVersion: String {
        UpdateInstaller.version(of: Bundle.main.bundleURL) ?? "0"
    }

    // As sw_vers writes it: 27.0, 27.0.1.
    static var macOSVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let short = "\(version.majorVersion).\(version.minorVersion)"
        return version.patchVersion == 0 ? short : "\(short).\(version.patchVersion)"
    }

    // Why the form can't go as it is, or nil when it can.
    static func problem(text: String, email: String) -> String? {
        let count = length(text)
        if count == 0 { return "Write your idea first." }
        if count > maxCharacters { return "Keep it to 2,000 characters." }
        let address = trimmed(email)
        if !address.isEmpty, address.count > maxEmail || address.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) == nil {
            return "That email doesn't look right. Leave it empty if you'd rather not have a reply."
        }
        if body(text: text, email: email).count > maxBodyBytes { return "That's too long to send. Please shorten it a little." }
        return nil
    }

    private struct Body: Encodable {
        let text: String
        let email: String?
        let appVersion: String
        let macOS: String
    }

    // What's sent: the text, the email if there is one, and the two versions. Nothing else.
    static func body(text: String, email: String) -> Data {
        let address = trimmed(email)
        let body = Body(text: trimmed(text), email: address.isEmpty ? nil : address, appVersion: appVersion, macOS: macOSVersion)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return try! encoder.encode(body)
    }
}
