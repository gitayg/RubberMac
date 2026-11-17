import AppKit

// Moving an app to the Trash, as Finder does it: Finder is asked to delete it, so Put Back works and, for an app the
// user can't change (App Store apps belong to the system), Finder asks for an administrator's password itself. RubberMAC
// never sees the password. If RubberMAC isn't allowed to control Finder, NSWorkspace moves it, where it can.
enum StartMenuTrash {
    enum Outcome: Equatable {
        case trashed
        case cancelled
        case failed(String)
    }

    // done is called on the main thread.
    static func moveToTrash(_ url: URL, done: @escaping (Outcome) -> Void) {
        // Off the main thread: Finder doesn't answer until its password question has been answered.
        DispatchQueue.global(qos: .userInitiated).async {
            let status = finderDelete(url)
            DispatchQueue.main.async {
                switch status {
                case noErr:
                    done(.trashed)
                case OSStatus(userCanceledErr):
                    done(.cancelled)
                case OSStatus(errAEEventNotPermitted):
                    log("start: not allowed to control Finder, moving \(url.lastPathComponent) to the Trash without it")
                    recycle(url, done: done)
                default:
                    done(.failed("Finder couldn't move it (error \(status))."))
                }
            }
        }
    }

    // Finder's own delete, which is what Move to Trash in Finder does.
    static func finderDelete(_ url: URL) -> OSStatus {
        let finder = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAEDelete),
                                           targetDescriptor: finder, returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(fileURL: url), forKeyword: keyDirectObject)
        do {
            let reply = try event.sendEvent(options: [.waitForReply, .canInteract], timeout: 600)
            return OSStatus(reply.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value ?? 0)
        } catch {
            return OSStatus((error as NSError).code)
        }
    }

    static func recycle(_ url: URL, done: @escaping (Outcome) -> Void) {
        NSWorkspace.shared.recycle([url]) { _, error in
            DispatchQueue.main.async {
                guard let error = error as NSError? else { return done(.trashed) }
                done(error.code == NSUserCancelledError ? .cancelled : .failed(error.localizedDescription))
            }
        }
    }

    // Asked before anything moves, naming the app.
    static func confirmation(for app: StartMenuApp) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Move “\(app.name)” to the Trash?"
        alert.informativeText = "It goes to the Trash, so you can still take it back out. Its settings and documents stay on this Mac."
        alert.addButton(withTitle: "Move to Trash").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.icon = StartMenuIcons.icon(app.path)
        return alert
    }

    static func failure(for app: StartMenuApp, _ message: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "“\(app.name)” couldn't be moved to the Trash."
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        return alert
    }
}
