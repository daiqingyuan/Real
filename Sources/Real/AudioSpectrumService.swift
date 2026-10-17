import Accelerate
import AudioToolbox
import Combine
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Pure signal processing. No device access, permissions, timers or network operations.
final class SpectrumFFT {
    static let sampleCount = 2048
    static let bandCount = 32
    struct Result {
        let levels: [Float]
        let dominantFrequency: Double
        let peakAmplitude: Float
    }
    private let setup: FFTSetup?
    private var window: [Float]
    private let windowSum: Float

    init() {
        let size = Self.sampleCount
        setup = vDSP_create_fftsetup(vDSP_Length(log2(Double(size))), FFTRadix(kFFTRadix2))
        var values = [Float](repeating: 0, count: size)
        vDSP_hann_window(&values, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        window = values
        windowSum = values.reduce(0, +)
    }

    deinit { if let setup { vDSP_destroy_fftsetup(setup) } }

    static func normalizedSample(_ value: Float) -> Float {
        // Permit normal floating-point headroom but prevent corrupt finite PCM
        // values from overflowing the mean, downmix sum, or FFT butterflies.
        value.isFinite ? min(16, max(-16, value)) : 0
    }

    func analyze(_ samples: [Float], sampleRate: Double) -> Result {
        let empty = Result(levels: .init(repeating: 0, count: Self.bandCount), dominantFrequency: 0, peakAmplitude: 0)
        guard let setup, samples.count >= Self.sampleCount, sampleRate.isFinite, sampleRate > 0 else { return empty }
        let count = Self.sampleCount
        var real = Array(samples.suffix(count)).map(Self.normalizedSample)
        var mean: Float = 0
        vDSP_meanv(real, 1, &mean, vDSP_Length(count))
        var negativeMean = -mean
        vDSP_vsadd(real, 1, &negativeMean, &real, 1, vDSP_Length(count))
        vDSP_vmul(real, 1, window, 1, &real, 1, vDSP_Length(count))
        var imaginary = [Float](repeating: 0, count: count)
        var magnitudes = [Float](repeating: 0, count: count / 2)
        real.withUnsafeMutableBufferPointer { realBuffer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                var split = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imaginaryBuffer.baseAddress!)
                vDSP_fft_zip(setup, &split, 1, vDSP_Length(log2(Double(count))), FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(count / 2))
            }
        }
        let scale: Float = 2 / windowSum
        magnitudes = magnitudes.map { $0 * scale }
        magnitudes[0] = 0 // DC is not an audible frequency band.
        let peak = magnitudes.enumerated().max(by: { $0.element < $1.element })!
        let top = min(16_000.0, sampleRate / 2)
        guard top > 40 else { return empty }
        let levels = (0..<Self.bandCount).map { band -> Float in
            let lowFrequency = 40 * pow(top / 40, Double(band) / Double(Self.bandCount))
            let highFrequency = 40 * pow(top / 40, Double(band + 1) / Double(Self.bandCount))
            let lower = max(1, min(count / 2 - 1, Int(lowFrequency / sampleRate * Double(count))))
            let upper = max(lower + 1, min(count / 2, Int(ceil(highFrequency / sampleRate * Double(count)))))
            let amplitude = magnitudes[lower..<upper].max() ?? 0
            let decibels = 20 * log10(max(amplitude, 0.000_000_1))
            return min(1, max(0, (decibels + 80) / 80))
        }
        return Result(levels: levels,
                      dominantFrequency: peak.element < 0.000_01 ? 0 : Double(peak.offset) * sampleRate / Double(count),
                      peakAmplitude: peak.element)
    }
}

/// PCM delivery stays on one capture queue. Only the small meter snapshot crosses a lock.
final class SpectrumAudioOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Snapshot { let levels: [Float]; let updated: TimeInterval; let formatError: Bool }
    private let fft = SpectrumFFT()
    private var samples: [Float] = []
    private var lastAnalysis = 0.0
    private var activeSampleRate = 0.0
    private let lock = NSLock()
    private var latest = Snapshot(levels: .init(repeating: 0, count: SpectrumFFT.bandCount), updated: 0, formatError: false)
    let onStop: @Sendable (Error) -> Void

    init(onStop: @escaping @Sendable (Error) -> Void) { self.onStop = onStop }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { onStop(error) }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        ingest(sampleBuffer)
    }

    /// Accepts an in-memory PCM buffer; used by deterministic tests without starting capture.
    func ingest(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let formatPointer = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { return }
        let format = formatPointer.pointee
        guard format.mFormatID == kAudioFormatLinearPCM, format.mBitsPerChannel == 32,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              format.mFormatFlags & kAudioFormatFlagIsPacked != 0,
              format.mSampleRate.isFinite, format.mSampleRate > 0,
              format.mChannelsPerFrame > 0, format.mChannelsPerFrame <= 8,
              format.mBytesPerFrame == 4 * (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? 1 : format.mChannelsPerFrame) else {
            lock.lock()
            latest = Snapshot(levels: .init(repeating: 0, count: SpectrumFFT.bandCount), updated: 0, formatError: true)
            lock.unlock()
            return
        }
        var requiredSize = 0
        var retainedBlock: CMBlockBuffer?
        _ = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: &requiredSize,
            bufferListOut: nil, bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment), blockBufferOut: nil)
        guard requiredSize >= MemoryLayout<AudioBufferList>.size, requiredSize < 16_384 else { return }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: requiredSize, alignment: 16)
        defer { storage.deallocate() }
        let list = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
        let result = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: nil,
            bufferListOut: list, bufferListSize: requiredSize, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment), blockBufferOut: &retainedBlock)
        guard result == noErr else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0, frameCount <= 192_000 else { return }
        var mono = [Float](repeating: 0, count: frameCount)
        var channelsRead = 0
        for buffer in buffers {
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0, channels <= 8, let data = buffer.mData,
                  Int(buffer.mDataByteSize) >= frameCount * channels * MemoryLayout<Float>.size else { continue }
            let values = data.assumingMemoryBound(to: Float.self)
            for frame in 0..<frameCount {
                for channel in 0..<channels { mono[frame] += SpectrumFFT.normalizedSample(values[frame * channels + channel]) }
            }
            channelsRead += channels
        }
        withExtendedLifetime(retainedBlock) {}
        guard channelsRead > 0 else { return }
        if channelsRead > 1 { mono = mono.map { $0 / Float(channelsRead) } }
        if activeSampleRate != format.mSampleRate {
            activeSampleRate = format.mSampleRate
            samples.removeAll(keepingCapacity: true)
        }
        samples.append(contentsOf: mono)
        if samples.count > SpectrumFFT.sampleCount { samples.removeFirst(samples.count - SpectrumFFT.sampleCount) }
        let now = ProcessInfo.processInfo.systemUptime
        guard samples.count == SpectrumFFT.sampleCount, now - lastAnalysis >= 1.0 / 15 else { return }
        lastAnalysis = now
        let analysis = fft.analyze(samples, sampleRate: activeSampleRate)
        lock.lock()
        latest = Snapshot(levels: analysis.levels, updated: now, formatError: false)
        lock.unlock()
    }
}

@MainActor
final class AudioSpectrumService: ObservableObject {
    @Published private(set) var levels = [Float](repeating: 0, count: SpectrumFFT.bandCount)
    @Published private(set) var status = "频谱未启用"
    @Published private(set) var isRunning = false
    @Published private(set) var isStarting = false

    private var stream: SCStream?
    private var output: SpectrumAudioOutput?
    private var timer: Timer?
    private var startTask: Task<Void, Never>?
    private var epoch = UUID()
    private let captureQueue = DispatchQueue(label: "real.system-audio.spectrum", qos: .utility)

    init() {} // No capture enumeration, permission request, microphone or network access.

    /// The caller must invoke this only after an explicit user Enable action, never from preview.
    func start() {
        guard !isRunning, !isStarting else { return }
        isStarting = true
        status = "正在请求系统音频权限…"
        let currentEpoch = UUID()
        epoch = currentEpoch
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard epoch == currentEpoch, !Task.isCancelled else { return }
                guard let display = content.displays.first else {
                    throw NSError(domain: "real.AudioSpectrum", code: 1, userInfo: [NSLocalizedDescriptionKey: "没有可用的显示器捕获来源"])
                }
                let config = SCStreamConfiguration()
                config.width = 2
                config.height = 2
                config.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 60)
                config.queueDepth = 3
                config.showsCursor = false
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.sampleRate = 48_000
                config.channelCount = 1
                // Only an audio output is registered. No screen frames or files are received.
                let sink = SpectrumAudioOutput { [weak self] error in
                    Task { @MainActor [weak self] in
                        guard let self, epoch == currentEpoch else { return }
                        stop()
                        status = Self.message(for: error)
                    }
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let candidate = SCStream(filter: filter, configuration: config, delegate: sink)
                try candidate.addStreamOutput(sink, type: .audio, sampleHandlerQueue: captureQueue)
                stream = candidate
                output = sink
                try await candidate.startCapture()
                guard epoch == currentEpoch, !Task.isCancelled else {
                    try? candidate.removeStreamOutput(sink, type: .audio)
                    try? await candidate.stopCapture()
                    return
                }
                isStarting = false
                isRunning = true
                status = "实时系统音频频谱"
                let timer = Timer(timeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.publishLevels() }
                }
                timer.tolerance = 0.01
                RunLoop.main.add(timer, forMode: .common)
                self.timer = timer
                startTask = nil
            } catch {
                guard epoch == currentEpoch else { return }
                stop()
                status = Self.message(for: error)
            }
        }
    }

    func stop() {
        epoch = UUID()
        startTask?.cancel()
        startTask = nil
        timer?.invalidate()
        timer = nil
        let activeStream = stream
        let activeOutput = output
        stream = nil
        output = nil
        isStarting = false
        isRunning = false
        levels = .init(repeating: 0, count: SpectrumFFT.bandCount)
        status = "频谱未启用"
        if let activeStream {
            if let activeOutput { try? activeStream.removeStreamOutput(activeOutput, type: .audio) }
            activeStream.stopCapture { _ in }
        }
    }

    deinit {
        timer?.invalidate()
        startTask?.cancel()
        if let stream {
            if let output { try? stream.removeStreamOutput(output, type: .audio) }
            stream.stopCapture { _ in }
        }
    }

    private func publishLevels() {
        guard isRunning, let output else { return }
        let snapshot = output.snapshot()
        if snapshot.formatError {
            stop()
            status = "系统音频格式不受支持"
            return
        }
        let stale = ProcessInfo.processInfo.systemUptime - snapshot.updated > 0.25
        let target = stale ? [Float](repeating: 0, count: SpectrumFFT.bandCount) : snapshot.levels
        levels = zip(levels, target).map { previous, current in
            let smoothing: Float = current > previous ? 0.65 : 0.25
            let value = previous + (current - previous) * smoothing
            return value < 0.002 ? 0 : value
        }
    }

    private static func message(for error: Error) -> String {
        let error = error as NSError
        if error.domain == SCStreamErrorDomain, error.code == -3801 {
            return "请在系统设置的屏幕与系统音频录制中允许 Real，然后重新启用频谱。"
        }
        if error.domain == SCStreamErrorDomain, error.code == -3817 { return "系统音频捕获已由用户停止" }
        return "系统音频捕获失败：" + error.localizedDescription
    }
}
