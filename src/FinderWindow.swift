import AppKit

// Moves Finder's front window with Apple Events, as AppleScript's "set target of Finder window 1" does. Each call
// waits for Finder's answer, so call it off the main thread. Needs the user's one-time OK to control Finder.
enum FinderWindow {
    struct Failure: Error { let status: OSStatus }

    static let notPermitted = OSStatus(errAEEventNotPermitted)

    private static let finder = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")

    // noErr when allowed. With `ask`, the first time shows the system's "control Finder" prompt and waits for it.
    static func permission(ask: Bool) -> OSStatus {
        AEDeterminePermissionToAutomateTarget(finder.aeDesc, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
    }

    static func show(_ folder: URL) throws {
        let event = event(AEEventClass(kAECoreSuite), AEEventID(kAESetData), frontTarget())
        event.setParam(NSAppleEventDescriptor(fileURL: folder), forKeyword: AEKeyword(keyAEData))
        try send(event)
    }

    // The folder the front window shows; nil, or Finder's error, for a window with no folder on disk behind it.
    static func currentFolder() throws -> URL? {
        let event = event(AEEventClass(kAECoreSuite), AEEventID(kAEGetData), frontTarget())
        event.setParam(NSAppleEventDescriptor(typeCode: code("furl")), forKeyword: AEKeyword(keyAERequestedType))
        return try send(event).paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.fileURLValue
    }

    // Selects an item in the front window; show(_:) its folder first.
    static func select(_ item: URL) throws {
        try send(event(code("misc"), code("slct"), NSAppleEventDescriptor(fileURL: item)))
    }

    // What's selected in the front window.
    static func selection() throws -> [URL] {
        let selection = specifier(OSType(typeProperty), form: OSType(formPropertyID),
                                  data: NSAppleEventDescriptor(typeCode: code("sele")), in: .null())
        let event = event(AEEventClass(kAECoreSuite), AEEventID(kAEGetData), selection)
        event.setParam(NSAppleEventDescriptor(typeCode: code("alst")), forKeyword: AEKeyword(keyAERequestedType))
        guard let list = try send(event).paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) else { return [] }
        if let single = list.fileURLValue { return [single] }
        return (0..<list.numberOfItems).compactMap { list.atIndex($0 + 1)?.fileURLValue }
    }

    // The target of Finder window 1: the folder the front window shows.
    private static func frontTarget() -> NSAppleEventDescriptor {
        let window = specifier(code("brow"), form: OSType(formAbsolutePosition), data: NSAppleEventDescriptor(int32: 1),
                               in: .null())
        return specifier(OSType(typeProperty), form: OSType(formPropertyID),
                         data: NSAppleEventDescriptor(typeCode: code("fvtg")), in: window)
    }

    private static func event(_ eventClass: AEEventClass, _ id: AEEventID, _ direct: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: eventClass, eventID: id, targetDescriptor: finder,
                                           returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(direct, forKeyword: AEKeyword(keyDirectObject))
        return event
    }

    @discardableResult
    private static func send(_ event: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        let reply: NSAppleEventDescriptor
        do {
            reply = try event.sendEvent(options: [.waitForReply], timeout: 5)
        } catch {
            throw Failure(status: OSStatus((error as NSError).code))
        }
        if let status = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value, status != noErr {
            throw Failure(status: status)
        }
        return reply
    }

    private static func specifier(_ wanted: OSType, form: OSType, data: NSAppleEventDescriptor,
                                  in container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: wanted), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: form), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(data, forKeyword: AEKeyword(keyAEKeyData))
        record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        return record.coerce(toDescriptorType: DescType(typeObjectSpecifier))!
    }

    private static func code(_ text: String) -> OSType {
        text.utf8.reduce(0) { $0 << 8 | OSType($1) }
    }
}
