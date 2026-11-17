import AudioToolbox
import CoreAudio

// One output device's volume and mute, as the menu bar's sound slider sets them: the "virtual main" volume, which
// moves every channel together. A device that doesn't offer it (HDMI or DisplayPort audio to a TV, say) has no
// volume a Mac can set, and its keys are left to macOS. Thread-safe, so the tap's thread can ask.
struct OutputVolume {
    let device: AudioDeviceID

    // The device sound goes to now, as chosen in the menu bar or System Settings.
    static var current: OutputVolume? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return OutputVolume(device: device)
    }

    // Every device with sound going out, the current one included.
    static var all: [OutputVolume] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.map(OutputVolume.init).filter(\.hasOutput)
    }

    var name: String {
        var address = Self.address(kAudioObjectPropertyName, scope: kAudioObjectPropertyScopeGlobal)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr, let name else { return "?" }
        return name.takeRetainedValue() as String
    }

    // How it's connected, as CoreAudio's four letters: "blue" Bluetooth, "hdmi", "dprt" DisplayPort, "bltn" built in.
    var transport: String {
        var address = Self.address(kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return "?" }
        return String(bytes: withUnsafeBytes(of: value.bigEndian, Array.init), encoding: .ascii) ?? "?"
    }

    var canSetVolume: Bool { settable(kAudioHardwareServiceDeviceProperty_VirtualMainVolume) }
    var canMute: Bool { settable(kAudioDevicePropertyMute) }

    // 0 ... 1.
    var volume: Float? {
        var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    @discardableResult
    func setVolume(_ value: Float) -> Bool {
        var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var value = Float32(min(max(value, 0), 1))
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }

    var isMuted: Bool? {
        var address = Self.address(kAudioDevicePropertyMute)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value != 0 : nil
    }

    @discardableResult
    func setMuted(_ muted: Bool) -> Bool {
        var address = Self.address(kAudioDevicePropertyMute)
        var value = UInt32(muted ? 1 : 0)
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    private var hasOutput: Bool {
        var address = Self.address(kAudioDevicePropertyStreams)
        var size = UInt32(0)
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    private func settable(_ selector: AudioObjectPropertySelector) -> Bool {
        var address = Self.address(selector)
        var settable = DarwinBoolean(false)
        return AudioObjectHasProperty(device, &address)
            && AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}
