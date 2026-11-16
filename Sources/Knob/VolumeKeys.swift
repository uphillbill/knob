import AppKit
import CoreGraphics

/// Watches the keyboard's volume up / down / mute keys with a session event tap.
/// The handler decides per event whether to swallow it (Knob owns the volume) or let macOS have it.
/// Needs Accessibility permission; `start()` returns false until it's granted.
final class VolumeKeys {
    enum Key { case up, down, mute }

    /// (key, fineStep, isKeyDown) -> swallow?
    var handler: ((Key, Bool, Bool) -> Bool)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    private static let systemDefinedType: UInt32 = 14      // NX_SYSDEFINED
    private static let auxControlButtonsSubtype: Int16 = 8 // NX_SUBTYPE_AUX_CONTROL_BUTTONS
    private static let soundUp = 0                          // NX_KEYTYPE_SOUND_UP
    private static let soundDown = 1                        // NX_KEYTYPE_SOUND_DOWN
    private static let mute = 7                             // NX_KEYTYPE_MUTE

    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1) << CGEventMask(Self.systemDefinedType)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let keys = Unmanaged<VolumeKeys>.fromOpaque(refcon).takeUnretainedValue()
            return keys.handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == Self.systemDefinedType,
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.type == .systemDefined,
              nsEvent.subtype.rawValue == Self.auxControlButtonsSubtype else {
            return Unmanaged.passUnretained(event)
        }

        let data1 = nsEvent.data1
        let keyCode = (data1 & 0xFFFF_0000) >> 16
        let keyFlags = data1 & 0x0000_FFFF
        let isDown = ((keyFlags & 0xFF00) >> 8) == 0xA

        let key: Key
        switch keyCode {
        case Self.soundUp: key = .up
        case Self.soundDown: key = .down
        case Self.mute: key = .mute
        default: return Unmanaged.passUnretained(event)
        }

        let flags = nsEvent.modifierFlags
        let fine = flags.contains(.option) && flags.contains(.shift)
        let swallow = handler?(key, fine, isDown) ?? false
        return swallow ? nil : Unmanaged.passUnretained(event)
    }
}
