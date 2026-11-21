import CoreGraphics
import Foundation

/// Reads and writes the built-in display's brightness through the private DisplayServices framework.
enum BuiltInBrightness {
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)

    private static let getBrightness: GetBrightness? = {
        guard let symbol = dlsym(handle, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(symbol, to: GetBrightness.self)
    }()

    private static let setBrightness: SetBrightness? = {
        guard let symbol = dlsym(handle, "DisplayServicesSetBrightness") else { return nil }
        return unsafeBitCast(symbol, to: SetBrightness.self)
    }()

    /// 0...1, or nil when the built-in display is off (e.g. lid closed).
    static func current() -> Float? {
        guard let getBrightness, let id = builtInDisplay() else { return nil }
        var value: Float = 0
        guard getBrightness(id, &value) == 0 else { return nil }
        return value
    }

    /// Sets brightness (0...1). Returns false when the built-in display is off.
    @discardableResult
    static func set(_ value: Float) -> Bool {
        guard let setBrightness, let id = builtInDisplay() else { return false }
        return setBrightness(id, min(max(value, 0), 1)) == 0
    }

    private static func builtInDisplay() -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count)
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }
}
