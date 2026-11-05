// DDC/CI wire format (VESA DDC/CI 1.1). No IOKit here so it can be tested on its own.
enum DDCProtocol {
    static let brightness: UInt8 = 0x10
    static let replyLength = 11

    struct VCPValue: Equatable {
        let current: UInt16
        let max: UInt16
    }

    private static let displayAddress: UInt8 = 0x6E  // 7-bit 0x37, write direction
    private static let hostAddress: UInt8 = 0x51     // sent as IOAVServiceWriteI2C's data address
    private static let hostReplyAddress: UInt8 = 0x50

    static func checksum(_ seed: UInt8, _ bytes: [UInt8]) -> UInt8 {
        bytes.reduce(seed, ^)
    }

    // Get VCP Feature: length, opcode 0x01, code, checksum.
    static func getVCPRequest(_ code: UInt8) -> [UInt8] {
        framed([0x01, code])
    }

    // Set VCP Feature: length, opcode 0x03, code, value high, value low, checksum.
    static func setVCPRequest(_ code: UInt8, _ value: UInt16) -> [UInt8] {
        framed([0x03, code, UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    // The source byte 0x51 travels as the I2C data address, not in the buffer, but the checksum still covers it.
    private static func framed(_ body: [UInt8]) -> [UInt8] {
        let packet = [0x80 | UInt8(body.count)] + body
        return packet + [checksum(displayAddress ^ hostAddress, packet)]
    }

    // Reply: 6E 88 02 result code type maxH maxL curH curL checksum (checksum seeded with 0x50).
    static func parseVCPReply(_ reply: [UInt8], code: UInt8) -> VCPValue? {
        guard reply.count == replyLength, reply[2] == 0x02, reply[3] == 0x00, reply[4] == code,
              checksum(hostReplyAddress, Array(reply[0..<10])) == reply[10] else { return nil }
        let max = UInt16(reply[6]) << 8 | UInt16(reply[7])
        let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
        return max > 0 ? VCPValue(current: current, max: max) : nil
    }

    static func percent(current: UInt16, max: UInt16) -> Int {
        guard max > 0 else { return 0 }
        return min(100, Int((Double(current) * 100 / Double(max)).rounded()))
    }

    static func raw(percent: Int, max: UInt16) -> UInt16 {
        let clamped = Double(min(100, Swift.max(0, percent)))
        return UInt16((clamped * Double(max) / 100).rounded())
    }
}
