import CoreGraphics

// Modifier masks for rewriting key events. Each swap also moves the device-specific
// left/right bits (IOLLEvent.h) so apps that check which side was pressed stay consistent.
enum Modifiers {
    static let control = CGEventFlags.maskControl.rawValue
    static let option = CGEventFlags.maskAlternate.rawValue
    static let command = CGEventFlags.maskCommand.rawValue
    static let shift = CGEventFlags.maskShift.rawValue
    static let arrowKey = CGEventFlags.maskNumericPad.rawValue | CGEventFlags.maskSecondaryFn.rawValue

    private static let deviceBits: [UInt64: (all: UInt64, left: UInt64)] = [
        control: (0x01 | 0x2000, 0x01),
        shift: (0x02 | 0x04, 0x02),
        command: (0x08 | 0x10, 0x08),
        option: (0x20 | 0x40, 0x20),
    ]

    static func replace(_ old: UInt64, with new: UInt64, in flags: UInt64) -> UInt64 {
        (flags & ~(old | (deviceBits[old]?.all ?? 0))) | new | (deviceBits[new]?.left ?? 0)
    }

    // Just the Shift state (generic and device bits) of `flags`.
    static func shiftOnly(_ flags: UInt64) -> UInt64 {
        flags & (shift | deviceBits[shift]!.all)
    }
}
