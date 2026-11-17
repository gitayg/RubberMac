import AppKit

// What changing a screen's mode takes, so the countdown can be tried on made-up screens.
protocol ScreenResolutionSwitcher: AnyObject {
    // Connected screens, whether or not they're showing anything.
    func displays() -> [CGDirectDisplayID]
    func key(of display: CGDirectDisplayID) -> String
    func modes(of display: CGDirectDisplayID) -> [ScreenResolution.Mode]
    func current(of display: CGDirectDisplayID) -> ScreenResolution.Mode?
    // For this login session only, or saved so it's used again after a restart.
    func apply(_ mode: ScreenResolution.Mode, to display: CGDirectDisplayID, permanently: Bool) -> Bool
}

// The real screens, through Quartz.
final class ScreenResolutionQuartz: ScreenResolutionSwitcher {
    // Each mode read as the one in use, so it can be put back even if the list stops offering it.
    private var seen: [CGDirectDisplayID: [CGDisplayMode]] = [:]

    func displays() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    func key(of display: CGDirectDisplayID) -> String { CameraArea.key(of: display) }

    func modes(of display: CGDirectDisplayID) -> [ScreenResolution.Mode] {
        ScreenResolution.displayModes(of: display).map(ScreenResolution.Mode.init)
    }

    func current(of display: CGDirectDisplayID) -> ScreenResolution.Mode? {
        guard let mode = CGDisplayCopyDisplayMode(display) else { return nil }
        let read = ScreenResolution.Mode(mode)
        if !(seen[display] ?? []).contains(where: { ScreenResolution.Mode($0) == read }) { seen[display, default: []].append(mode) }
        return read
    }

    func apply(_ mode: ScreenResolution.Mode, to display: CGDirectDisplayID, permanently: Bool) -> Bool {
        let all = ScreenResolution.displayModes(of: display) + (seen[display] ?? [])
        guard let chosen = all.first(where: { ScreenResolution.Mode($0) == mode }) else { return false }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        guard CGConfigureDisplayWithDisplayMode(config, display, chosen, nil) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        return CGCompleteDisplayConfiguration(config, permanently ? .permanently : .forSession) == .success
    }
}
