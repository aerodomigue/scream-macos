import AppKit
import ApplicationServices

struct VolumeKeyEvent: Equatable {
    private static let AUXILIARY_BUTTON_SUBTYPE = 8
    private static let KEY_CODE_SHIFT = 16
    private static let KEY_STATE_SHIFT = 8
    private static let BYTE_MASK = 0xff
    private static let KEY_DOWN = 0x0a
    private static let KEY_UP = 0x0b
    private static let VOLUME_UP = 0
    private static let VOLUME_DOWN = 1
    private static let MUTE = 7
    private static let REPEAT_MASK = 1

    enum Key: Hashable { case volumeUp, volumeDown, mute }

    let key: Key
    let isDown: Bool
    let isRepeat: Bool

    var steps: Int? {
        switch key {
        case .volumeUp: return 1
        case .volumeDown: return -1
        case .mute: return nil
        }
    }

    init?(subtype: Int, data1: Int) {
        guard subtype == Self.AUXILIARY_BUTTON_SUBTYPE else { return nil }
        let code = data1 >> Self.KEY_CODE_SHIFT
        let state = (data1 >> Self.KEY_STATE_SHIFT) & Self.BYTE_MASK
        guard state == Self.KEY_DOWN || state == Self.KEY_UP else { return nil }
        switch code {
        case Self.VOLUME_UP: key = .volumeUp
        case Self.VOLUME_DOWN: key = .volumeDown
        case Self.MUTE: key = .mute
        default: return nil
        }
        isDown = state == Self.KEY_DOWN
        isRepeat = data1 & Self.REPEAT_MASK != 0
    }
}

@MainActor
protocol VolumeKeyMonitoring: AnyObject {
    var onStep: ((Int) -> Bool)? { get set }
    var onMute: (() -> Bool)? { get set }
    var canHandleMute: (() -> Bool)? { get set }
    var hasPermission: Bool { get }
    func start() -> Bool
    func stop()
    func requestPermission()
}

/// Intercepts eligible volume and mute keys; USB work is deferred to a separate service.
@MainActor
final class VolumeKeyMonitor: VolumeKeyMonitoring {
    var onStep: ((Int) -> Bool)?
    var onMute: (() -> Bool)?
    var canHandleMute: (() -> Bool)?
    var hasPermission: Bool { AXIsProcessTrusted() }
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var consumedKeys = Set<VolumeKeyEvent.Key>()

    deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
    }

    func start() -> Bool {
        guard hasPermission else { stop(); return false }
        if let tap {
            if !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
            return true
        }
        let mask = CGEventMask(1) << NSEvent.EventType.systemDefined.rawValue
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                return MainActor.assumeIsolated {
                    let monitor = Unmanaged<VolumeKeyMonitor>.fromOpaque(context).takeUnretainedValue()
                    return monitor.handle(type: type, event: event)
                }
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
        consumedKeys.removeAll()
    }

    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            consumedKeys.removeAll()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard let nativeEvent = NSEvent(cgEvent: event),
              nativeEvent.type == .systemDefined,
              let key = VolumeKeyEvent(subtype: Int(nativeEvent.subtype.rawValue), data1: nativeEvent.data1) else {
            return Unmanaged.passUnretained(event)
        }
        if !key.isDown {
            return consumedKeys.remove(key.key) != nil ? nil : Unmanaged.passUnretained(event)
        }
        // Preserve Option-volume shortcuts and unrelated modified keys.
        guard nativeEvent.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            return Unmanaged.passUnretained(event)
        }
        if key.key == .mute {
            guard canHandleMute?() == true else { return Unmanaged.passUnretained(event) }
            // A held mute key toggles once, including keyboards that omit the repeat flag.
            // Suppress orphan repeats after a tap restart without changing the mute state.
            if !key.isRepeat && !consumedKeys.contains(.mute) {
                guard onMute?() == true else { return Unmanaged.passUnretained(event) }
            }
        } else {
            guard let steps = key.steps, onStep?(steps) == true else { return Unmanaged.passUnretained(event) }
        }
        consumedKeys.insert(key.key)
        return nil
    }
}
