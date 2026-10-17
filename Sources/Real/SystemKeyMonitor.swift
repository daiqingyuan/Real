import AppKit
import ApplicationServices
import Combine
import IOKit.hidsystem

/// Tracks ownership of a complete press, independently of hardware APIs.
struct SystemKeyPressState {
    private var presses: [Int: Bool] = [:]
    mutating func begin(_ key: Int, repeated: Bool) -> Bool {
        if repeated { return presses[key] == true }
        presses[key] = false
        return true
    }
    mutating func record(_ key: Int, handled: Bool) { presses[key] = handled }
    mutating func release(_ key: Int) -> Bool { presses.removeValue(forKey: key) == true }
    mutating func reset() { presses.removeAll() }
}

/// Routes supported hardware keys to the independent system service. Unsupported
/// hardware and failed writes retain the native system key event and native HUD.
@MainActor
final class SystemKeyMonitor: ObservableObject {
    @Published private(set) var status = tr("已停止")
    var onHUD: ((String, Double) -> Void)?

    private let system: SystemStatusService
    private let preferences: Preferences
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    // False records a native press so a later repeat cannot be stolen midway.
    private var pressState = SystemKeyPressState()
    private var generation: UInt64 = 0
    private let step = 1.0 / 16.0
    private static let systemEventType = CGEventType(rawValue: UInt32(NSEvent.EventType.systemDefined.rawValue))!

    init(system: SystemStatusService, preferences: Preferences) {
        self.system = system
        self.preferences = preferences
    }

    func start() {
        guard preferences.enabled("hud"), preferences.enabled("volumeHUD") || preferences.enabled("brightnessHUD") else {
            stop()
            status = tr("已禁用")
            return
        }
        guard tap == nil else { return }
        guard AXIsProcessTrusted() else {
            status = tr("硬件按键提示需要辅助功能权限")
            return
        }
        let callback: CGEventTapCallBack = { _, type, event, pointer in
            guard let pointer else { return Unmanaged.passUnretained(event) }
            return MainActor.assumeIsolated {
                Unmanaged<SystemKeyMonitor>.fromOpaque(pointer).takeUnretainedValue().receive(type, event)
            }
        }
        let mask = CGEventMask(1) << Self.systemEventType.rawValue
        guard let newTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                options: .defaultTap, eventsOfInterest: mask, callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            status = tr("无法监听硬件按键，请检查辅助功能和输入监控权限")
            return
        }
        guard let newSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0) else {
            CFMachPortInvalidate(newTap)
            status = tr("无法创建硬件按键事件源")
            return
        }
        generation &+= 1
        tap = newTap
        source = newSource
        CFRunLoopAddSource(CFRunLoopGetMain(), newSource, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        status = tr("运行中")
    }

    func stop() {
        generation &+= 1
        pressState.reset()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
        status = tr("已停止")
    }

    deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
    }

    private func receive(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            generation &+= 1
            pressState.reset()
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
                status = tr("运行中 · 硬件按键监听已恢复")
            }
            return Unmanaged.passUnretained(event)
        }
        guard type == Self.systemEventType,
              let native = NSEvent(cgEvent: event),
              native.type == .systemDefined,
              native.subtype.rawValue == NX_SUBTYPE_AUX_CONTROL_BUTTONS else {
            return Unmanaged.passUnretained(event)
        }
        let key = (native.data1 >> 16) & 0xffff
        let state = (native.data1 >> 8) & 0xff
        let repeated = (native.data1 & 1) != 0
        guard [NX_KEYTYPE_SOUND_UP, NX_KEYTYPE_SOUND_DOWN, NX_KEYTYPE_MUTE,
               NX_KEYTYPE_BRIGHTNESS_UP, NX_KEYTYPE_BRIGHTNESS_DOWN].contains(Int32(key)) else {
            return Unmanaged.passUnretained(event)
        }
        if state == NX_KEYUP {
            return pressState.release(key) ? nil : Unmanaged.passUnretained(event)
        }
        guard state == NX_KEYDOWN else { return Unmanaged.passUnretained(event) }
        guard pressState.begin(key, repeated: repeated) else { return Unmanaged.passUnretained(event) }
        // Option/Shift combinations have native precision/settings behavior.
        let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        guard event.flags.intersection(modifiers).isEmpty,
              preferences.enabled("hud"), onHUD != nil else {
            pressState.record(key, handled: false)
            return Unmanaged.passUnretained(event)
        }
        guard handle(key, repeated: repeated) else {
            pressState.record(key, handled: false)
            return Unmanaged.passUnretained(event)
        }
        pressState.record(key, handled: true)
        return nil
    }

    private func handle(_ key: Int, repeated: Bool) -> Bool {
        let isBrightness = Int32(key) == NX_KEYTYPE_BRIGHTNESS_UP || Int32(key) == NX_KEYTYPE_BRIGHTNESS_DOWN
        guard preferences.enabled(isBrightness ? "brightnessHUD" : "volumeHUD") else { return false }
        // Read fresh hardware state before calculating a delta. The timer's
        // cached values may have been changed by native keys or another app.
        system.refreshControls()
        switch Int32(key) {
        case NX_KEYTYPE_SOUND_UP, NX_KEYTYPE_SOUND_DOWN:
            guard preferences.enabled("volumeHUD"), system.canSetVolume else { return false }
            // Muted volume buttons retain native semantics; changing a silent
            // scalar alone would otherwise swallow an expected unmute operation.
            guard !system.isMuted else { return false }
            let direction = Int32(key) == NX_KEYTYPE_SOUND_UP ? 1.0 : -1.0
            let target = min(1, max(0, system.volume + direction * step))
            guard system.setVolume(target) else { return false }
            status = tr("运行中")
            publishHUD(system.volume <= 0 ? "speaker.slash.fill" : "speaker.wave.2.fill", system.volume)
            return true
        case NX_KEYTYPE_MUTE:
            guard preferences.enabled("volumeHUD"), system.canToggleMute else { return false }
            // Mute is a toggle, not an operation to repeat while held down.
            if repeated { return true }
            guard system.toggleMute() else { return false }
            status = tr("运行中")
            publishHUD(system.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", system.isMuted ? 0 : system.volume)
            return true
        case NX_KEYTYPE_BRIGHTNESS_UP, NX_KEYTYPE_BRIGHTNESS_DOWN:
            guard preferences.enabled("brightnessHUD"), let brightness = system.brightness else { return false }
            let direction = Int32(key) == NX_KEYTYPE_BRIGHTNESS_UP ? 1.0 : -1.0
            let target = min(1, max(0, brightness + direction * step))
            guard system.setBrightness(target), let actual = system.brightness else { return false }
            status = tr("运行中")
            publishHUD("sun.max.fill", actual)
            return true
        default:
            return false
        }
    }

    private func publishHUD(_ symbol: String, _ value: Double) {
        let expectedGeneration = generation
        // Layout and animations must not extend the event-tap callback duration.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.tap != nil, self.generation == expectedGeneration,
                  self.preferences.enabled("hud") else { return }
            self.onHUD?(symbol, value)
        }
    }

}
