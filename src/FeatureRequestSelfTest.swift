import AppKit

// --selftest requests <server folder>: what the form sends (the fields, nothing more, the versions as this Mac has
// them), what it refuses before sending, how it words the server's answers, the window laid out off screen (drawn to
// a PNG in the temporary folder), and with the request server's folder after it, real round trips to that server run
// on a free local port with a scratch data folder, plus one to a script that writes down every header that arrives.
// Never talks to the deployed server, shows no window and changes no setting.
extension FeatureRequest {
    typealias Check = (Bool, String) -> Void

    static func selfTestReport() -> String {
        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(what)")
        }

        NSApp.setActivationPolicy(.accessory)
        let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        let before = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]

        bodyChecks(check)
        settingsChecks(check)
        validationChecks(check)
        outcomeChecks(check)
        windowChecks(check, folder: FileManager.default.temporaryDirectory)
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "requests"), i + 1 < args.count {
            roundTripChecks(check, server: URL(fileURLWithPath: args[i + 1]))
        } else {
            check(false, "round trip: give the request server's folder after `requests`")
        }

        // The running copy of RubberMAC writes these two as you switch windows and pages, so they may change meanwhile.
        let after = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
        let changed = Set(before.keys).union(after.keys).subtracting(["focusHistory", "settingsPage"])
            .filter { (before[$0] as? NSObject) != (after[$0] as? NSObject) }
        check(changed.isEmpty, "no stored setting changed\(changed.isEmpty ? "" : ": \(changed.sorted())")")
        return (lines + [failures == 0 ? "PASS" : "FAIL: \(failures) failed"]).joined(separator: "\n")
    }

    static func json(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: What's sent

    private static func bodyChecks(_ check: Check) {
        let plist = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let swVers = run("/usr/bin/sw_vers", ["-productVersion"])
        let full = json(body(text: "  Let ⌘⇧T reopen a window.\n", email: " someone@example.com "))
        check(Set(full.keys) == ["text", "email", "appVersion", "macOS"], "with an email the body has exactly text, email, appVersion, macOS: \(full.keys.sorted())")
        check(full["text"] as? String == "Let ⌘⇧T reopen a window." && full["email"] as? String == "someone@example.com",
              "the text and email are sent trimmed, as typed")
        check(plist != nil && full["appVersion"] as? String == plist, "appVersion is the app's own, from Info.plist: \(full["appVersion"] ?? "none")")
        check(!swVers.isEmpty && full["macOS"] as? String == swVers, "macOS is the version sw_vers reports: \(full["macOS"] ?? "none") (sw_vers \(swVers))")
        let bare = json(body(text: "An idea", email: "   "))
        check(Set(bare.keys) == ["text", "appVersion", "macOS"], "without an email there's no email field at all: \(bare.keys.sorted())")
        let raw = String(decoding: body(text: "a/b", email: ""), as: UTF8.self)
        check(raw.contains(#""a/b""#), "slashes go as they are: \(raw)")

        let request = request(text: "An idea", email: "", to: URL(string: "https://example.invalid")!)
        check(request.url?.absoluteString == "https://example.invalid/requests" && request.httpMethod == "POST",
              "it posts to /requests on the server: \(request.url?.absoluteString ?? "none")")
        check(request.allHTTPHeaderFields == ["Content-Type": "application/json", "Accept": "application/json", "User-Agent": "RubberMAC",
                                              "Accept-Language": "en"],
              "its own headers are JSON's, a plain User-Agent and a fixed language: \(request.allHTTPHeaderFields ?? [:])")
        check(server.absoluteString == "https://rubbermac-requests.crane.glick.run", "the app sends to the production server: \(server)")
    }

    // MARK: Its row in the settings panel

    private static func settingsChecks(_ check: Check) {
        let delegate = AppDelegate(lockWarning: LockWarning(timeoutOverride: nil))
        let ideas = delegate.settingsPages(SettingsFacts()).first { $0.id == "general" }?.sections.last
        check(ideas?.title == "Ideas" && ideas?.rows.count == 1, "the General page ends with an Ideas section of one row")
        guard let row = ideas?.rows.first, let action = row.action else { return check(false, "with a button in it") }
        let button: Bool
        if case .button("Write", enabled: true) = row.control { button = true } else { button = false }
        check(row.title == "Send a Feature Request…" && button, "Send a Feature Request…, with a Write button")
        check(row.closesPanel && (row.target as? NSObject)?.responds(to: action) == true, "which closes the panel and reaches its action")
    }

    // MARK: What's refused before sending

    private static func validationChecks(_ check: Check) {
        let ok = { (text: String, email: String) in problem(text: text, email: email) == nil }
        check(!ok("", ""), "empty text is refused")
        check(!ok(" \n\t ", ""), "text of only spaces and newlines is refused")
        check(problem(text: "", email: "") == "Write your idea first.", "and says so")
        check(ok(String(repeating: "a", count: 2000), ""), "2,000 characters go")
        check(!ok(String(repeating: "a", count: 2001), ""), "2,001 don't")
        check(problem(text: String(repeating: "a", count: 2001), email: "") == "Keep it to 2,000 characters.", "and the form says why")
        check(ok(String(repeating: "a", count: 2000) + "\n\n  ", ""), "spaces after the text don't count")
        check(length("👍👍") == 2 && length("é") == 1, "an emoji or accented letter counts as one")
        check(length("🇮🇱") == 2, "a flag counts as two, its two code points, as the server counts it")
        check(ok("An idea", ""), "the email is optional")
        check(ok("An idea", "someone@example.com") && ok("An idea", "  first.last+tag@mail.example.co.uk "), "a real-looking email goes")
        for bad in ["someone", "someone@example", "some one@example.com", "@example.com", "someone@.com x", "a@b@c.com"] {
            check(!ok("An idea", bad), "\"\(bad)\" isn't taken as an email")
        }
        check(!ok("An idea", String(repeating: "a", count: 243) + "@example.com"), "nor an email of 255 characters")
        check(problem(text: "An idea", email: "someone")?.hasPrefix("That email doesn't look right.") == true, "and the form says why")
        // 2,000 four-byte emoji with a long email come to more than the server takes.
        let emoji = String(repeating: "👍", count: 2000)
        check(ok(emoji, ""), "2,000 emoji go: \(body(text: emoji, email: "").count) bytes")
        let big = String(repeating: "a", count: 230) + "@example.com"
        check(problem(text: emoji, email: big) == "That's too long to send. Please shorten it a little.",
              "with a long email they're more than 8 KB (\(body(text: emoji, email: big).count) bytes) and refused before sending")
    }

    // MARK: How the server's answers are worded

    private static func outcomeChecks(_ check: Check) {
        let reply = { (object: [String: Any]) in try! JSONSerialization.data(withJSONObject: object) }
        check(outcome(status: 201, data: reply(["ok": true, "id": "abc"]), error: nil) == .sent(id: "abc"), "201 with ok and an id is sent")
        check(outcome(status: 200, data: reply(["ok": false, "id": "abc"]), error: nil) != .sent(id: "abc"), "a 200 with an id but not ok isn't")
        check(outcome(status: 429, data: reply(["ok": false, "error": "That's a lot of requests in an hour. Please try again later."]), error: nil)
              == .failed("That's a lot of requests in an hour. Please try again later."), "429 shows the server's reason")
        check(outcome(status: 429, data: nil, error: nil) == .failed("Too many requests just now. Please try again later."), "or its own without one")
        check(outcome(status: 413, data: nil, error: nil) == .failed("That's too long to send. Please shorten it a little."), "413 says it's too long")
        check(outcome(status: 400, data: reply(["error": "The text is empty."]), error: nil) == .failed("The request server turned it down: The text is empty."),
              "400 says the server turned it down, and why")
        let long = String(repeating: "x", count: 500)
        if case .failed(let message) = outcome(status: 400, data: reply(["error": long]), error: nil) {
            check(message.count < 250, "a long reason is cut short: \(message.count) characters")
        } else {
            check(false, "a long reason is cut short")
        }
        check(outcome(status: 502, data: Data("<html>".utf8), error: nil) == .failed("The request server isn't answering properly (HTTP 502). Please try again later."),
              "502 says the server isn't answering properly")
        let offline = URLError(.notConnectedToInternet)
        check(outcome(status: 0, data: nil, error: offline) == .failed("Couldn't reach RubberMAC's request server: \(offline.localizedDescription)"),
              "no connection says it couldn't reach the server")
    }

    // MARK: The window, off screen

    private static func windowChecks(_ check: Check, folder: URL) {
        let form = FeatureRequestWindow(server: URL(string: "http://127.0.0.1:9")!)
        form.window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        guard let content = form.window.contentView else { return check(false, "the window has a content view") }
        content.layoutSubtreeIfNeeded()

        check(form.window.title == "Send a Feature Request", "the window is titled Send a Feature Request")
        let labels = allViews(content).compactMap { ($0 as? NSTextField).map(\.stringValue) }
        let disclosure = "Goes to RubberMAC's developer with your RubberMAC and macOS versions, nothing else"
        check(labels.contains(disclosure), "it says what's sent: \(disclosure)")
        check(labels.contains("Your email, if you'd like a reply") && form.emailField.placeholderString == "Optional",
              "the email box is labelled \"Your email, if you'd like a reply\" and marked optional")
        check(form.sendButton.title == "Send" && form.cancelButton.title == "Cancel", "with Send and Cancel")
        check(form.sendButton.keyEquivalent == "\r" && form.sendButton.keyEquivalentModifierMask == .command && form.cancelButton.keyEquivalent == "\u{1b}",
              "⌘↩ sends and Esc cancels")
        check(!form.window.isVisible && !form.window.styleMask.contains(.resizable), "it's laid out without being shown, at a fixed size")

        let size = content.bounds.size
        let parts: [(String, NSView)] = [("text box", form.textScroll), ("count", form.countLabel), ("email box", form.emailField),
                                         ("status", form.statusLabel), ("Cancel", form.cancelButton), ("Send", form.sendButton)]
        let frames = parts.map { ($0.0, $0.1.convert($0.1.bounds, to: content)) }
        let inside = frames.filter { content.bounds.insetBy(dx: 12, dy: 12).contains($0.1) }.map(\.0)
        check(inside.count == parts.count, "every part sits inside the window, clear of its edges (\(Int(size.width)) × \(Int(size.height))): \(inside)")
        let overlaps = frames.indices.flatMap { a in frames.indices.filter { $0 > a && frames[a].1.intersects(frames[$0].1) }.map { "\(frames[a].0)/\(frames[$0].0)" } }
        check(overlaps.isEmpty, "no two parts overlap\(overlaps.isEmpty ? "" : ": \(overlaps)")")
        check(form.textScroll.frame.height >= 140 && form.textScroll.frame.width >= 400, "the text box is big enough to write in: \(form.textScroll.frame.size)")
        check(size.width <= 520 && size.height <= 480, "the window is small: \(size)")
        check(frames[0].1.minY > frames[2].1.maxY && frames[2].1.minY > frames[5].1.maxY, "text box, then email, then the buttons, top to bottom")

        check(form.countLabel.stringValue == "0 / 2,000" && !form.sendButton.isEnabled, "empty, the count reads 0 / 2,000 and Send waits")
        form.textView.insertText("Hi", replacementRange: NSRange(location: 0, length: 0))
        check(form.countLabel.stringValue == "2 / 2,000" && form.sendButton.isEnabled, "typing updates the count as it goes: \(form.countLabel.stringValue), and Send is ready")
        form.text = String(repeating: "a", count: 2001)
        check(form.countLabel.stringValue == "2,001 / 2,000" && form.countLabel.textColor == .systemRed && !form.sendButton.isEnabled,
              "past 2,000 the count reads 2,001 / 2,000 in red and Send waits")
        form.text = String(repeating: "a", count: 2000)
        check(form.countLabel.textColor != .systemRed && form.sendButton.isEnabled, "at 2,000 it's back to normal")
        form.text = "An idea"
        form.email = "someone"
        form.send()
        check(form.statusLabel.stringValue.hasPrefix("That email doesn't look right.") && form.statusLabel.textColor == .systemRed && !form.isSending,
              "Send with a bad email says why in red and sends nothing")
        content.layoutSubtreeIfNeeded()
        let status = form.statusLabel.convert(form.statusLabel.bounds, to: content)
        check(status.height >= form.statusLabel.intrinsicContentSize.height - 0.5 && content.bounds.contains(status),
              "the reason is shown whole, over two lines: \(status.size)")
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            form.window.appearance = NSAppearance(named: appearance)
            draw(content.superview ?? content, to: folder.appendingPathComponent("feature-request-\(name).png"), check)
        }
        form.window.appearance = nil

        _ = form.textView(form.textView, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        check(form.isClosed, "Esc in the text box closes the form")
        let other = FeatureRequestWindow(server: URL(string: "http://127.0.0.1:9")!)
        _ = other.control(other.emailField, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        check(other.isClosed, "and in the email box")
    }

    private static func allViews(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(allViews)
    }

    private static func draw(_ view: NSView, to png: URL, _ check: Check) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return check(false, "the window draws") }
        view.cacheDisplay(in: view.bounds, to: rep)
        let written = (try? rep.representation(using: .png, properties: [:])?.write(to: png)) != nil
        check(written, "drawn to \(png.path)")
    }

    // MARK: Round trips to a local server

    private static func roundTripChecks(_ check: Check, server folder: URL) {
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("rubbermac-requests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: data) }
        guard let local = FeatureRequestTestServer(arguments: [folder.appendingPathComponent("server.js").path],
                                                   environment: ["DATA_DIR": data.path, "RATE_PER_HOUR": "2", "NOTIFY_EMAIL": ""]) else {
            return check(false, "the request server starts from \(folder.path) (node at \(FeatureRequestTestServer.node?.path ?? "nowhere"))")
        }
        defer { local.stop() }
        check(true, "the request server runs on 127.0.0.1:\(local.port) with a scratch data folder")

        let health = fetch(local.url.appendingPathComponent("api/health"))
        check(health?["status"] as? String == "ok" && health?["version"] != nil, "its /api/health answers: \(health ?? [:])")

        // Through the form, as a click on Send does it.
        let text = "Round trip from the self-test: let ⌘⇧T reopen the last window. 👍"
        let form = FeatureRequestWindow(server: local.url)
        form.text = text
        form.email = "someone@example.com"
        form.sendButton.performClick(nil)
        check(form.isSending && form.statusLabel.stringValue == "Sending…" && !form.sendButton.isEnabled && !form.textView.isEditable,
              "Send says Sending… and holds the form while it goes")
        spin(10) { !form.isSending }
        check(form.statusLabel.stringValue == "Sent. Thank you.", "the form says \"\(form.statusLabel.stringValue)\"")
        let file = data.appendingPathComponent("requests.jsonl")
        let saved = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let record = saved.split(separator: "\n").last.map { json(Data($0.utf8)) } ?? [:]
        check(Set(record.keys) == ["id", "at", "text", "email", "appVersion", "macOS"], "the server saved exactly what was sent, with an id and the time: \(record.keys.sorted())")
        check(record["text"] as? String == text && record["email"] as? String == "someone@example.com"
              && record["appVersion"] as? String == appVersion && record["macOS"] as? String == macOSVersion,
              "the text, email and versions arrived as typed and read: \(record["appVersion"] ?? "?"), macOS \(record["macOS"] ?? "?")")
        check(!saved.contains("127.0.0.1") && !saved.isEmpty, "and not the address it came from")
        spin(4) { form.isClosed }
        check(form.isClosed, "the form closes a moment after Sent")

        var second: Outcome?
        send(text: "A second idea", email: "", to: local.url) { second = $0 }
        spin(10) { second != nil }
        check(second.map { if case .sent = $0 { true } else { false } } == true, "a second request goes too: \(String(describing: second))")

        let third = FeatureRequestWindow(server: local.url)
        third.text = "A third idea in the hour"
        third.send()
        spin(10) { !third.isSending }
        check(third.statusLabel.stringValue == "That's a lot of requests in an hour. Please try again later." && third.statusLabel.textColor == .systemRed,
              "past the server's limit the form shows its reason in red: \(third.statusLabel.stringValue)")
        check(third.text == "A third idea in the hour" && third.textView.isEditable && third.sendButton.isEnabled, "and keeps the text, ready to try again")
        spin(2) { third.isClosed }
        check(!third.isClosed, "and stays open")
        third.close()

        headerChecks(check)
    }

    // Everything that reaches a server: the headers CFNetwork adds included.
    private static func headerChecks(_ check: Check) {
        let script = """
        require("http").createServer((q, r) => { let b = ""; q.on("data", (c) => (b += c)); q.on("end", () => {
          console.log(JSON.stringify({ method: q.method, url: q.url, headers: q.rawHeaders, body: b }));
          r.writeHead(201, { "Content-Type": "application/json", "Set-Cookie": "seen=1; Path=/" }); r.end('{"ok":true,"id":"capture"}'); }); })
          .listen(Number(process.env.PORT), process.env.HOST, function () { console.log("listening on " + this.address().port); });
        """
        guard let capture = FeatureRequestTestServer(arguments: ["-e", script]) else { return check(false, "the capture script starts") }
        var result: Outcome?, again: Outcome?
        send(text: "What do you send?", email: "", to: capture.url) { result = $0 }
        spin(10) { result != nil }
        // The script set a cookie with its first answer; the second request mustn't carry it back.
        send(text: "And now?", email: "", to: capture.url) { again = $0 }
        spin(10) { again != nil }
        capture.stop()
        check(result == .sent(id: "capture"), "the capture script got it: \(String(describing: result))")
        let requests = capture.lines.dropFirst().compactMap { line in line.isEmpty ? nil : json(Data(line.utf8)) }
        let seen = requests.first ?? [:]
        let raw = seen["headers"] as? [String] ?? []
        let headers = Dictionary(stride(from: 0, to: raw.count - 1, by: 2).map { (raw[$0].lowercased(), raw[$0 + 1]) }) { first, _ in first }
        check(seen["method"] as? String == "POST" && seen["url"] as? String == "/requests", "a POST to /requests")
        check(Set(headers.keys).isSubset(of: ["host", "content-type", "accept", "user-agent", "content-length", "accept-encoding", "connection", "accept-language"]),
              "only the plain headers: \(headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" })")
        check(headers["user-agent"] == "RubberMAC", "the User-Agent says only RubberMAC: \(headers["user-agent"] ?? "none")")
        check(headers["accept-language"] == "en", "and the language is a fixed en, not this Mac's list: \(headers["accept-language"] ?? "none")")
        let second = (requests.dropFirst().first?["headers"] as? [String] ?? []).map { $0.lowercased() }
        check(headers["cookie"] == nil && headers["authorization"] == nil && requests.count == 2 && !second.contains("cookie"),
              "no cookie and no credentials, even after the server set a cookie: \(requests.count) requests seen")
        check(Set(json(Data((seen["body"] as? String ?? "").utf8)).keys) == ["text", "appVersion", "macOS"], "and the body as built")

        var unreachable: Outcome?
        send(text: "Anyone there?", email: "", to: capture.url) { unreachable = $0 }
        spin(25) { unreachable != nil }
        if case .failed(let message) = unreachable {
            check(message.hasPrefix("Couldn't reach RubberMAC's request server:"), "with the server gone it says it couldn't reach it: \(message)")
        } else {
            check(false, "with the server gone it says it couldn't reach it: \(String(describing: unreachable))")
        }
    }

    private static func fetch(_ url: URL) -> [String: Any]? {
        var result: [String: Any]?
        var done = false
        URLSession(configuration: .ephemeral).dataTask(with: url) { data, _, _ in
            DispatchQueue.main.async {
                result = data.map(json)
                done = true
            }
        }.resume()
        spin(10) { done }
        return result
    }

    // The main run loop, so the form's callbacks and its closing timer run as they do in the app.
    private static func spin(_ seconds: TimeInterval, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    private static func run(_ tool: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return "" }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
