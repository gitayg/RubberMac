import Foundation
import IOKit

// I2C over Apple Silicon's private IOAVService, with the pauses DDC/CI needs.
// Timing after MonitorControl (Arm64DDC.swift), m1ddc and Lunar: 10 ms before each write, 50 ms
// between a request and reading its reply, 40 ms before a retry (VESA DDC/CI 4.4.1).
enum DDCTransport {
    private static let chipAddress: UInt32 = 0x37
    private static let dataAddress: UInt32 = 0x51
    private static let writeDelay: useconds_t = 10_000
    private static let replyDelay: useconds_t = 50_000
    private static let retryDelay: useconds_t = 40_000
    private static let readAttempts = 5
    private static let writeAttempts = 3

    // Last I2C return codes, for the self-test report.
    nonisolated(unsafe) private(set) static var lastStatus = "no I2C traffic yet"

    static func open(_ proxy: io_service_t) -> CFTypeRef? {
        IOAVServiceCreateWithService(kCFAllocatorDefault, proxy)?.takeRetainedValue()
    }

    static func read(_ service: CFTypeRef, _ code: UInt8) -> DDCProtocol.VCPValue? {
        var request = DDCProtocol.getVCPRequest(code)
        for attempt in 1...readAttempts {
            if attempt > 1 { usleep(retryDelay) }
            // Both reference tools send the request twice; some monitors miss the first one.
            var wrote: IOReturn = kIOReturnSuccess
            for _ in 0..<2 {
                usleep(writeDelay)
                wrote = IOAVServiceWriteI2C(service, chipAddress, dataAddress, &request, UInt32(request.count))
            }
            guard wrote == kIOReturnSuccess else {
                lastStatus = "read 0x\(hex(code)) attempt \(attempt): write \(hex(wrote))"
                continue
            }
            usleep(replyDelay)
            var reply = [UInt8](repeating: 0, count: DDCProtocol.replyLength)
            let got = IOAVServiceReadI2C(service, chipAddress, 0, &reply, UInt32(reply.count))
            if got == kIOReturnSuccess, let value = DDCProtocol.parseVCPReply(reply, code: code) {
                lastStatus = "read 0x\(hex(code)) attempt \(attempt): ok"
                return value
            }
            lastStatus = "read 0x\(hex(code)) attempt \(attempt): read \(hex(got)), reply \(reply.map(hex).joined(separator: " "))"
        }
        return nil
    }

    // Sent once and retried only when the bus refuses it: every accepted set may hit the monitor's EEPROM.
    static func write(_ service: CFTypeRef, _ code: UInt8, _ value: UInt16) -> Bool {
        var packet = DDCProtocol.setVCPRequest(code, value)
        for attempt in 1...writeAttempts {
            if attempt > 1 { usleep(retryDelay) }
            usleep(writeDelay)
            let wrote = IOAVServiceWriteI2C(service, chipAddress, dataAddress, &packet, UInt32(packet.count))
            lastStatus = "write 0x\(hex(code))=\(value) attempt \(attempt): \(hex(wrote))"
            if wrote == kIOReturnSuccess {
                usleep(replyDelay)  // DDC/CI wants 50 ms after a set before the next message
                return true
            }
        }
        return false
    }

    private static func hex(_ byte: UInt8) -> String { String(format: "%02x", byte) }
    private static func hex(_ code: IOReturn) -> String { String(format: "0x%08x", UInt32(bitPattern: code)) }
}

@_silgen_name("IOAVServiceCreateWithService")
private func IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<CFTypeRef>?

@_silgen_name("IOAVServiceReadI2C")
private func IOAVServiceReadI2C(_ service: CFTypeRef, _ chipAddress: UInt32, _ offset: UInt32,
                                _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> IOReturn

@_silgen_name("IOAVServiceWriteI2C")
private func IOAVServiceWriteI2C(_ service: CFTypeRef, _ chipAddress: UInt32, _ dataAddress: UInt32,
                                 _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> IOReturn
