import Foundation
import IOKit

// Private IOKit symbols used for DDC/CI on Apple Silicon (same approach as m1ddc / MonitorControl).
@_silgen_name("IOAVServiceCreateWithService")
private func IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<CFTypeRef>?

@_silgen_name("IOAVServiceReadI2C")
private func IOAVServiceReadI2C(_ service: CFTypeRef, _ chipAddress: UInt32, _ offset: UInt32,
                                _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> IOReturn

@_silgen_name("IOAVServiceWriteI2C")
private func IOAVServiceWriteI2C(_ service: CFTypeRef, _ chipAddress: UInt32, _ dataAddress: UInt32,
                                 _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> IOReturn

final class DDCDisplay {
    static let brightnessCode: UInt8 = 0x10

    private let service: CFTypeRef
    private let chipAddress: UInt32 = 0x37
    private let dataAddress: UInt32 = 0x51

    private init(service: CFTypeRef) { self.service = service }

    /// All external displays reachable through DCPAVServiceProxy.
    static func externalDisplays() -> [DDCDisplay] {
        var displays: [DDCDisplay] = []
        var iterator = io_iterator_t()
        guard IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane,
                                       IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else {
            return displays
        }
        defer { IOObjectRelease(iterator) }

        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer { IOObjectRelease(entry); entry = IOIteratorNext(iterator) }

            var nameBuf = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(entry, &nameBuf)
            guard String(cString: nameBuf) == "DCPAVServiceProxy" else { continue }

            let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            guard location == "External",
                  let av = IOAVServiceCreateWithService(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
            displays.append(DDCDisplay(service: av))
        }
        return displays
    }

    /// Monitors commonly drop single writes, so by default each value is sent twice like m1ddc does.
    func write(_ code: UInt8, value: UInt16, attempts: Int = 2) -> Bool {
        var packet: [UInt8] = [0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF), 0]
        packet[5] = checksum(packet[0..<5])
        var ok = false
        for _ in 0..<attempts {
            usleep(10_000)
            ok = IOAVServiceWriteI2C(service, chipAddress, dataAddress, &packet, UInt32(packet.count)) == kIOReturnSuccess || ok
        }
        return ok
    }

    /// Returns (current, max) or nil if the monitor didn't answer.
    func read(_ code: UInt8) -> (current: UInt16, max: UInt16)? {
        var request: [UInt8] = [0x82, 0x01, code, 0]
        request[3] = checksum(request[0..<3])

        for _ in 0..<3 {
            usleep(10_000)
            guard IOAVServiceWriteI2C(service, chipAddress, dataAddress, &request, UInt32(request.count)) == kIOReturnSuccess else { continue }
            usleep(50_000)
            var reply = [UInt8](repeating: 0, count: 12)
            guard IOAVServiceReadI2C(service, chipAddress, 0, &reply, UInt32(reply.count)) == kIOReturnSuccess else { continue }
            // Reply: [src, len, 0x02, result, code, type, maxHi, maxLo, curHi, curLo, chk]
            guard reply[2] == 0x02, reply[3] == 0x00, reply[4] == code else { continue }
            let max = UInt16(reply[6]) << 8 | UInt16(reply[7])
            let cur = UInt16(reply[8]) << 8 | UInt16(reply[9])
            return (cur, max)
        }
        return nil
    }

    private func checksum(_ bytes: ArraySlice<UInt8>) -> UInt8 {
        bytes.reduce(UInt8(0x6E ^ 0x51)) { $0 ^ $1 }
    }
}
