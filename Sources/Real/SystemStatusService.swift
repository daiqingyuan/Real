import AppKit
import Combine
import CoreAudio
import Foundation
import IOKit
import IOKit.graphics

@MainActor
final class SystemStatusService: ObservableObject {
    @Published private(set) var volume = 0.0
    @Published private(set) var isMuted = false
    @Published private(set) var brightness: Double?
    @Published private(set) var canSetVolume = false
    @Published private(set) var canToggleMute = false
    @Published private(set) var status = ""

    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = 0.4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit { timer?.invalidate() }

    @discardableResult
    func setVolume(_ value: Double) -> Bool {
        guard value.isFinite, let device = outputDevice() else { return false }
        let elements = writableElements(device: device, selector: kAudioDevicePropertyVolumeScalar)
        guard !elements.isEmpty else {
            status = tr("此音频输出不支持软件音量控制。"); return false
        }
        let scalar = Float32(min(1, max(0, value)))
        let confirmed = AudioControlTransaction.apply(elements: elements, target: scalar,
            read: { self.readVolume(device: device, element: $0) },
            write: { self.writeAudio(device: device, selector: kAudioDevicePropertyVolumeScalar, element: $0, value: $1) },
            matches: { abs($0 - $1) <= 0.015 })
        refreshAudio()
        let success = confirmed && outputDevice() == device
        status = success ? "" : tr("音频输出未确认音量更改。")
        return success
    }

    @discardableResult
    func toggleMute() -> Bool {
        guard let device = outputDevice() else { return false }
        let elements = writableElements(device: device, selector: kAudioDevicePropertyMute)
        let current = elements.compactMap { readMute(device: device, element: $0) }
        guard !elements.isEmpty, current.count == elements.count else {
            status = tr("此音频输出不支持软件静音。"); return false
        }
        let target: UInt32 = current.allSatisfy { $0 != 0 } ? 0 : 1
        let confirmed = AudioControlTransaction.apply(elements: elements, target: target,
            read: { self.readMute(device: device, element: $0) },
            write: { self.writeAudio(device: device, selector: kAudioDevicePropertyMute, element: $0, value: $1) },
            matches: { ($0 != 0) == ($1 != 0) })
        refreshAudio()
        let success = confirmed && outputDevice() == device
        status = success ? "" : tr("音频输出未确认静音更改。")
        return success
    }

    @discardableResult
    func setBrightness(_ value: Double) -> Bool {
        guard value.isFinite else { return false }
        let display = controlDisplayID
        if DisplayBrightnessAdapter.read(displayID: display) != nil {
            let success = DisplayBrightnessAdapter.write(displayID: display, value: min(1, max(0, value)))
            refreshBrightness()
            status = success ? "" : tr("显示器未确认亮度更改。")
            return success
        }
        let outcome = withBrightnessDisplay(displayID: display) { service, _ in
            IODisplaySetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, Float(min(1, max(0, value))))
        }
        if outcome == nil {
            brightness = nil
            status = tr("公共显示接口不支持此亮度控制。")
        } else if outcome != kIOReturnSuccess {
            status = tr("显示器拒绝了亮度更改。")
        } else { status = "" }
        refreshBrightness()
        let success = outcome == kIOReturnSuccess && brightness.map { abs($0 - min(1, max(0, value))) <= 0.02 } == true
        if !success && status.isEmpty { status = tr("显示器未确认亮度更改。") }
        return success
    }

    func refreshControls() {
        refreshAudio()
        refreshBrightness()
    }

    private func refresh() {
        refreshAudio()
        refreshBrightness()
    }

    private func refreshAudio() {
        guard let device = outputDevice() else {
            volume = 0; isMuted = false; canSetVolume = false; canToggleMute = false
            return
        }
        let writableVolume = writableElements(device: device, selector: kAudioDevicePropertyVolumeScalar)
        let volumeElements = writableVolume.isEmpty ? readableElements(device: device, selector: kAudioDevicePropertyVolumeScalar) : writableVolume
        let readings = volumeElements.compactMap { readVolume(device: device, element: $0) }
        volume = readings.isEmpty ? 0 : Double(readings.reduce(0, +)) / Double(readings.count)
        let writableMute = writableElements(device: device, selector: kAudioDevicePropertyMute)
        let muteElements = writableMute.isEmpty ? readableElements(device: device, selector: kAudioDevicePropertyMute) : writableMute
        let muteValues = muteElements.compactMap { readMute(device: device, element: $0) }
        isMuted = !muteValues.isEmpty && muteValues.allSatisfy { $0 != 0 }
        canSetVolume = !writableVolume.isEmpty && readings.count == writableVolume.count
        canToggleMute = !writableMute.isEmpty && muteValues.count == writableMute.count
    }

    private func readVolume(device: AudioDeviceID, element: AudioObjectPropertyElement) -> Float32? {
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = audioAddress(kAudioDevicePropertyVolumeScalar, element: element)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
              size == MemoryLayout<Float32>.size, value.isFinite, (0...1).contains(value) else { return nil }
        return value
    }

    private func readMute(device: AudioDeviceID, element: AudioObjectPropertyElement) -> UInt32? {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = audioAddress(kAudioDevicePropertyMute, element: element)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
              size == MemoryLayout<UInt32>.size else { return nil }
        return value
    }

    private func writeAudio<T>(device: AudioDeviceID, selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement, value: T) -> Bool {
        var value = value
        var address = audioAddress(selector, element: element)
        return withUnsafePointer(to: &value) {
            AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<T>.size), $0) == noErr
        }
    }

    private func outputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return device
    }

    private func audioAddress(_ selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
    }

    private func readableElements(device: AudioDeviceID, selector: AudioObjectPropertySelector) -> [AudioObjectPropertyElement] {
        var main = audioAddress(selector, element: kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(device, &main) { return [kAudioObjectPropertyElementMain] }
        return channelElements(device: device).filter {
            var address = audioAddress(selector, element: $0)
            return AudioObjectHasProperty(device, &address)
        }
    }

    private func writableElements(device: AudioDeviceID, selector: AudioObjectPropertySelector) -> [AudioObjectPropertyElement] {
        func writable(_ element: AudioObjectPropertyElement) -> Bool {
            var address = audioAddress(selector, element: element)
            var settable = DarwinBoolean(false)
            return AudioObjectHasProperty(device, &address)
                && AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
        }
        if writable(kAudioObjectPropertyElementMain) { return [kAudioObjectPropertyElementMain] }
        return channelElements(device: device).filter(writable)
    }

    private func channelElements(device: AudioDeviceID) -> [AudioObjectPropertyElement] {
        var address = audioAddress(kAudioDevicePropertyStreamConfiguration, element: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioBufferList>.size, size <= 1_048_576 else { return [] }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, memory) == noErr else { return [] }
        let pointer = memory.assumingMemoryBound(to: AudioBufferList.self)
        let maximumBuffers = (Int(size) - MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)!) / MemoryLayout<AudioBuffer>.stride
        guard pointer.pointee.mNumberBuffers <= maximumBuffers else { return [] }
        let list = UnsafeMutableAudioBufferListPointer(pointer)
        let count = list.reduce(0) { $0 + Int($1.mNumberChannels) }
        return count > 0 && count <= 256 ? (1...count).map { AudioObjectPropertyElement($0) } : []
    }

    private var controlDisplayID: CGDirectDisplayID {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        return (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }
    private func refreshBrightness() {
        let display = controlDisplayID
        brightness = DisplayBrightnessAdapter.read(displayID: display) ?? withBrightnessDisplay(displayID: display) { _, value in Double(value) }
    }

    /// Match the selected display before using legacy IOKit. A first-available
    /// fallback could alter the internal panel when an external panel is selected.
    private func withBrightnessDisplay<T>(displayID: CGDirectDisplayID, _ action: (io_service_t, Float) -> T) -> T? {
        func identity(_ id: CGDirectDisplayID) -> LegacyBrightnessIdentity {
            LegacyBrightnessIdentity(vendor: CGDisplayVendorNumber(id), product: CGDisplayModelNumber(id), serial: CGDisplaySerialNumber(id))
        }
        let target = identity(displayID)
        let online = NSScreen.screens.compactMap { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value }
        guard target.vendor != 0, target.product != 0, online.filter({ identity($0) == target }).count == 1 else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iterator) == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iterator) }
        var matches: [(io_service_t, Float)] = []
        defer { matches.forEach { IOObjectRelease($0.0) } }
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            guard let info = IODisplayCreateInfoDictionary(service, IOOptionBits(kIODisplayMatchingInfo))?.takeRetainedValue() as? [String: Any],
                  let vendor = info[kDisplayVendorID] as? NSNumber,
                  let product = info[kDisplayProductID] as? NSNumber,
                  LegacyBrightnessIdentity(vendor: vendor.uint32Value, product: product.uint32Value,
                    serial: (info[kDisplaySerialNumber] as? NSNumber)?.uint32Value ?? 0) == target else {
                IOObjectRelease(service); continue
            }
            var value: Float = 0
            if IODisplayGetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, &value) == kIOReturnSuccess,
               value.isFinite, (0...1).contains(value) { matches.append((service, value)) }
            else { IOObjectRelease(service) }
        }
        guard matches.count == 1 else { return nil }
        return action(matches[0].0, matches[0].1)
    }
}

struct LegacyBrightnessIdentity: Equatable {
    let vendor: UInt32
    let product: UInt32
    let serial: UInt32
}


/// Verify each addressed channel, not its aggregate average. If any write/readback
/// fails, attempt to restore all attempted channels before native key fallback.
/// Hardware rollback may itself be rejected; failure is never reported as success.
enum AudioControlTransaction {
    static func apply<Element, Value>(elements: [Element], target: Value,
        read: (Element) -> Value?, write: (Element, Value) -> Bool,
        matches: (Value, Value) -> Bool) -> Bool {
        guard !elements.isEmpty else { return false }
        let originals = elements.compactMap(read)
        guard originals.count == elements.count else { return false }
        var attempted = 0
        for element in elements {
            attempted += 1
            guard write(element, target), let actual = read(element), matches(actual, target) else {
                for index in (0..<attempted).reversed() { _ = write(elements[index], originals[index]) }
                return false
            }
        }
        return true
    }
}
