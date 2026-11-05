import Carbon.HIToolbox

// System-wide hotkeys via Carbon: they work without Input Monitoring permission and
// swallow the keystroke, so the focused app never sees it.
final class HotKeys {
    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var handler: EventHandlerRef?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let hotKeys = Unmanaged<HotKeys>.fromOpaque(userData!).takeUnretainedValue()
            hotKeys.actions[id.id]?()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func register(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        let id = UInt32(actions.count + 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers),
                                         EventHotKeyID(signature: OSType(0x5354_4F4C), id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            log("hotkey \(keyCode) with modifiers \(modifiers) not registered: OSStatus \(status)")
            return
        }
        refs.append(ref)
        actions[id] = action
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        actions = [:]
    }
}
