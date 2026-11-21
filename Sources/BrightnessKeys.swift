import AppKit
import ApplicationServices

/// Intercepts the keyboard brightness keys with a CGEvent tap. Needs Accessibility permission.
final class BrightnessKeyTap {
    enum Direction { case up, down }

    private let shouldIntercept: () -> Bool
    private let onPress: (Direction, _ fine: Bool) -> Void
    private var tap: CFMachPort?

    init(shouldIntercept: @escaping () -> Bool, onPress: @escaping (Direction, _ fine: Bool) -> Void) {
        self.shouldIntercept = shouldIntercept
        self.onPress = onPress
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func promptForAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// Returns false if the tap couldn't be created (usually missing permission).
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let systemDefined: CGEventType.RawValue = 14 // NX_SYSDEFINED: media and brightness keys
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << systemDefined)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                Unmanaged<BrightnessKeyTap>.fromOpaque(refcon!).takeUnretainedValue().handle(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.tap = tap
        RunLoop.main.add(tap, forMode: .common)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return passThrough
        }

        var direction: Direction?
        var isKeyDown = true
        if type == .keyDown {
            // Some keyboards send brightness as plain key codes.
            switch event.getIntegerValueField(.keyboardEventKeycode) {
            case 144: direction = .up
            case 145: direction = .down
            default: break
            }
        } else if let nsEvent = NSEvent(cgEvent: event), nsEvent.type == .systemDefined, nsEvent.subtype.rawValue == 8 {
            let keyCode = (nsEvent.data1 & 0xFFFF_0000) >> 16
            isKeyDown = (nsEvent.data1 & 0xFF00) >> 8 == 0xA
            switch keyCode {
            case 2: direction = .up    // NX_KEYTYPE_BRIGHTNESS_UP
            case 3: direction = .down  // NX_KEYTYPE_BRIGHTNESS_DOWN
            default: break
            }
        }

        guard let direction, shouldIntercept() else { return passThrough }
        if isKeyDown {
            // Option+Shift gives finer steps, matching macOS.
            onPress(direction, event.flags.contains(.maskAlternate) && event.flags.contains(.maskShift))
        }
        return nil
    }
}
