import AppKit
import ApplicationServices

// The window server's view of every Space, and Accessibility elements for windows on Spaces other than the current
// one, which kAXWindowsAttribute leaves out. All of it is private API (as AltTab uses it), looked up at run time so a
// missing symbol leaves the switcher with the current Space's windows instead of crashing.
enum SpaceWindows {
    struct Window {
        let id: CGWindowID
        let pid: pid_t
        let spaces: [UInt64]
        let isOnScreen: Bool
    }

    struct Spaces {
        // The Space each display shows.
        let current: Set<UInt64>
        // Desktops and full-screen Spaces, on every display.
        let user: Set<UInt64>
        let fullScreen: Set<UInt64>
    }

    // Space types in SLSCopyManagedDisplaySpaces.
    private static let desktopType = 0
    private static let fullScreenType = 4
    // Also the windows that aren't ordered in (minimized, hidden or closed), as AltTab asks.
    private static let includingOrderedOut: UInt32 = 0x7
    // kCPSUserGenerated: switch as a click in the Dock would, which also switches Space.
    private static let userGenerated: UInt32 = 0x200
    // Capture options: the window alone, at one pixel per point.
    private static let ignoreGlobalClipShape: UInt32 = 1 << 11
    private static let nominalResolution: UInt32 = 1 << 9

    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopyWindowsInSpaces = @convention(c) (Int32, UInt32, CFArray, UInt32, UnsafeMutablePointer<UInt64>,
                                                            UnsafeMutablePointer<UInt64>) -> Unmanaged<CFArray>?
    private typealias IsOrderedIn = @convention(c) (Int32, CGWindowID, UnsafeMutablePointer<Bool>) -> CGError
    private typealias MoveToSpace = @convention(c) (Int32, CFArray, UInt64) -> Void
    private typealias CreateWithRemoteToken = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
    private typealias ProcessForPID = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    private typealias SetFrontProcess = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
    private typealias PostEventRecord = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError
    private typealias CaptureWindowList = @convention(c) (Int32, UnsafeMutablePointer<CGWindowID>, UInt32, UInt32) -> Unmanaged<CFArray>?

    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let hiServices = dlopen(
        "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices", RTLD_LAZY)

    private static let connection: Int32? = symbol(skyLight, "SLSMainConnectionID", as: MainConnection.self).map { $0() }
    private static let copyManagedDisplaySpaces = symbol(skyLight, "SLSCopyManagedDisplaySpaces", as: CopyManagedDisplaySpaces.self)
    private static let copyWindowsInSpaces = symbol(skyLight, "SLSCopyWindowsWithOptionsAndTags", as: CopyWindowsInSpaces.self)
    private static let isOrderedInFunction = symbol(skyLight, "SLSWindowIsOrderedIn", as: IsOrderedIn.self)
    private static let moveToSpace = symbol(skyLight, "SLSMoveWindowsToManagedSpace", as: MoveToSpace.self)
    private static let createWithRemoteToken = symbol(hiServices, "_AXUIElementCreateWithRemoteToken", as: CreateWithRemoteToken.self)
    private static let processForPID = symbol(hiServices, "GetProcessForPID", as: ProcessForPID.self)
    private static let setFrontProcess = symbol(skyLight, "_SLPSSetFrontProcessWithOptions", as: SetFrontProcess.self)
    private static let postEventRecord = symbol(skyLight, "SLPSPostEventRecordTo", as: PostEventRecord.self)
    private static let captureWindowList = symbol(skyLight, "SLSHWCaptureWindowList", as: CaptureWindowList.self)

    private static func symbol<T>(_ library: UnsafeMutableRawPointer?, _ name: String, as type: T.Type) -> T? {
        guard let library, let address = dlsym(library, name) else { return nil }
        return unsafeBitCast(address, to: type)
    }

    static var canList: Bool { connection != nil && copyManagedDisplaySpaces != nil && copyWindowsInSpaces != nil }
    static var canFindElements: Bool { createWithRemoteToken != nil }
    static var canFocus: Bool { processForPID != nil && setFrontProcess != nil && postEventRecord != nil }

    static func spaces() -> Spaces? {
        guard let connection, let copyManagedDisplaySpaces,
              let displays = copyManagedDisplaySpaces(connection)?.takeRetainedValue() as? [[String: Any]] else { return nil }
        var current = Set<UInt64>(), user = Set<UInt64>(), fullScreen = Set<UInt64>()
        for display in displays {
            if let id = (display["Current Space"] as? [String: Any]).flatMap(spaceID) { current.insert(id) }
            for space in display["Spaces"] as? [[String: Any]] ?? [] {
                guard let id = spaceID(space), let type = (space["type"] as? NSNumber)?.intValue else { continue }
                if type == desktopType || type == fullScreenType { user.insert(id) }
                if type == fullScreenType { fullScreen.insert(id) }
            }
        }
        return Spaces(current: current, user: user, fullScreen: fullScreen)
    }

    private static func spaceID(_ space: [String: Any]) -> UInt64? {
        ((space["ManagedSpaceID"] ?? space["id64"]) as? NSNumber)?.uint64Value
    }

    // Normal-layer windows of these apps on the given Spaces, including minimized, hidden and closed ones (a closed
    // window an app keeps stays on its Space). One window-server call per Space, then one for the windows' details.
    static func windows(of pids: Set<pid_t>, on spaces: Set<UInt64>) -> [Window]? {
        guard let connection, let copyWindowsInSpaces else { return nil }
        var spacesOf: [CGWindowID: [UInt64]] = [:]
        for space in spaces.sorted() {
            var setTags: UInt64 = 0, clearTags: UInt64 = 0
            let ids = copyWindowsInSpaces(connection, 0, [NSNumber(value: space)] as CFArray, includingOrderedOut,
                                          &setTags, &clearTags)?.takeRetainedValue() as? [NSNumber] ?? []
            for id in ids { spacesOf[id.uint32Value, default: []].append(space) }
        }
        guard !spacesOf.isEmpty else { return [] }
        // CGWindowListCreateDescriptionFromArray wants the window numbers themselves as the array's values.
        var values = spacesOf.keys.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        guard let array = CFArrayCreate(nil, &values, values.count, nil),
              let info = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]] else { return nil }
        return info.compactMap { window in
            guard (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pids.contains(pid),
                  let id = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value, let on = spacesOf[id] else { return nil }
            return Window(id: id, pid: pid, spaces: on, isOnScreen: (window[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false)
        }
    }

    // False for a window that's closed, minimized or hidden; true for one shown on its Space, even a Space not on screen.
    static func isOrderedIn(_ id: CGWindowID) -> Bool? {
        guard let connection, let isOrderedInFunction else { return nil }
        var orderedIn = false
        return isOrderedInFunction(connection, id, &orderedIn) == .success ? orderedIn : nil
    }

    // Any thread. A picture of the window as the window server holds it, which it does even for a full-screen
    // window whose Space isn't showing, where ScreenCaptureKit fails (error -3811). Needs Screen Recording. Nil for a
    // window whose app asked not to be captured.
    static func picture(of id: CGWindowID) -> CGImage? {
        guard let connection, let captureWindowList, allowsCapture(id) else { return nil }
        var window = id
        let images = captureWindowList(connection, &window, 1, ignoreGlobalClipShape | nominalResolution)?
            .takeRetainedValue() as? [CGImage]
        return images?.first
    }

    // False for a window with NSWindow.sharingType .none, and whenever that can't be told.
    static func allowsCapture(_ id: CGWindowID) -> Bool {
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let state = (info.first?[kCGWindowSharingState as String] as? NSNumber)?.uint32Value else { return false }
        return state != CGWindowSharingType.none.rawValue
    }

    // Only for the self-test, on its own window.
    static func move(_ id: CGWindowID, to space: UInt64) {
        guard let connection, let moveToSpace else { return }
        moveToSpace(connection, [NSNumber(value: id)] as CFArray, space)
    }

    // The app's own Accessibility element with this element number. The token is pid, 0, "coco", then the number.
    static func element(pid: pid_t, number: UInt64) -> AXUIElement? {
        guard let createWithRemoteToken else { return nil }
        var token = Data(count: 20)
        token.withUnsafeMutableBytes { bytes in
            bytes.storeBytes(of: pid, toByteOffset: 0, as: Int32.self)
            bytes.storeBytes(of: 0, toByteOffset: 4, as: Int32.self)
            bytes.storeBytes(of: 0x636f636f, toByteOffset: 8, as: Int32.self)
            bytes.storeBytes(of: number, toByteOffset: 12, as: UInt64.self)
        }
        return createWithRemoteToken(token as CFData)?.takeRetainedValue()
    }

    // Makes the app frontmost with this window as its key window; the window server switches to the window's Space.
    // The event record is the one the window server sends when a window is clicked (from Hammerspoon and AltTab).
    static func bringForward(_ id: CGWindowID, pid: pid_t) -> Bool {
        guard let processForPID, let setFrontProcess, let postEventRecord else { return false }
        var psn = ProcessSerialNumber()
        guard processForPID(pid, &psn) == noErr, setFrontProcess(&psn, id, userGenerated) == .success else { return false }
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        withUnsafeBytes(of: id) { bytes.replaceSubrange(0x3c..<0x40, with: $0) }
        bytes.replaceSubrange(0x20..<0x30, with: repeatElement(0xff, count: 0x10))
        for phase: UInt8 in [0x01, 0x02] {
            bytes[0x08] = phase
            _ = postEventRecord(&psn, &bytes)
        }
        return true
    }
}
