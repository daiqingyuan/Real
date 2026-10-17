import Foundation
import CoreMedia
import AudioToolbox

func runAudioSpectrumTests() -> [String] {
    var failures: [String] = []
    let fft = SpectrumFFT()
    let rate = 48_000.0
    func tone(_ frequency: Double, amplitude: Double = 0.5) -> [Float] {
        (0..<SpectrumFFT.sampleCount).map { Float(amplitude * sin(2 * Double.pi * frequency * Double($0) / rate)) }
    }
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { failures.append(message) }
    }
    for frequency in [375.0, 1500.0, 5625.0] {
        let result = fft.analyze(tone(frequency), sampleRate: rate)
        expect(abs(result.dominantFrequency - frequency) < rate / Double(SpectrumFFT.sampleCount), "FFT peak is not at \(frequency) Hz")
        expect(abs(result.peakAmplitude - 0.5) < 0.02, "Hann-window amplitude normalization is incorrect")
        expect(result.levels.count == 32 && result.levels.allSatisfy { $0.isFinite && (0...1).contains($0) }, "Spectrum bars must contain 32 bounded finite levels")
    }
    let low = tone(375, amplitude: 0.15)
    let high = tone(5625, amplitude: 0.7)
    let mixed = fft.analyze(zip(low, high).map(+), sampleRate: rate)
    expect(abs(mixed.dominantFrequency - 5625) < 24, "Mixed-tone dominant frequency follows amplitude")
    let silent = fft.analyze(.init(repeating: 0, count: SpectrumFFT.sampleCount), sampleRate: rate)
    expect(silent.levels.allSatisfy { $0 == 0 } && silent.dominantFrequency == 0, "Silence must produce no fake spectrum")
    let dc = fft.analyze(.init(repeating: 0.5, count: SpectrumFFT.sampleCount), sampleRate: rate)
    expect(dc.levels.allSatisfy { $0 == 0 }, "DC offset must be removed")
    let invalid = fft.analyze(.init(repeating: .nan, count: SpectrumFFT.sampleCount), sampleRate: rate)
    expect(invalid.levels.allSatisfy { $0 == 0 }, "Nonfinite input must not propagate")
    expect(fft.analyze([], sampleRate: rate).levels.allSatisfy { $0 == 0 }, "Incomplete FFT input is empty")
    let corrupt = fft.analyze((0..<SpectrumFFT.sampleCount).map { $0.isMultiple(of: 2) ? Float.greatestFiniteMagnitude : -Float.greatestFiniteMagnitude }, sampleRate: rate)
    expect(corrupt.peakAmplitude.isFinite && corrupt.levels.allSatisfy { $0.isFinite && (0...1).contains($0) }, "Extreme finite PCM must not overflow signal processing")
    // Verify the same CoreMedia PCM extraction path used by ScreenCaptureKit without capture.
    let mono = tone(1500)
    if let buffer = spectrumTestBuffer(mono, channels: 1) {
        let output = SpectrumAudioOutput(onStop: { _ in })
        output.ingest(buffer)
        let captured = output.snapshot()
        let reference = fft.analyze(mono, sampleRate: rate)
        expect(!captured.formatError && captured.updated > 0, "Float PCM sample buffer was not accepted")
        expect(zip(captured.levels, reference.levels).allSatisfy { abs($0 - $1) < 0.001 }, "CoreMedia mono extraction changed FFT data")
    } else { failures.append("Could not construct synthetic mono PCM sample buffer") }
    let left = tone(1500, amplitude: 0.6)
    let right = tone(5625, amplitude: 0.2)
    let interleaved = zip(left, right).flatMap { [$0, $1] }
    if let buffer = spectrumTestBuffer(interleaved, channels: 2) {
        let output = SpectrumAudioOutput(onStop: { _ in })
        output.ingest(buffer)
        let reference = fft.analyze(zip(left, right).map { ($0 + $1) / 2 }, sampleRate: rate)
        expect(zip(output.snapshot().levels, reference.levels).allSatisfy { abs($0 - $1) < 0.001 }, "CoreMedia stereo downmix differs from arithmetic mean")
    } else { failures.append("Could not construct synthetic stereo PCM sample buffer") }
    return failures
}

private func spectrumTestBuffer(_ values: [Float], channels: UInt32) -> CMSampleBuffer? {
    var format = AudioStreamBasicDescription(mSampleRate: 48_000,
        mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 4 * channels, mFramesPerPacket: 1, mBytesPerFrame: 4 * channels,
        mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
    var description: CMAudioFormatDescription?
    guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &format, layoutSize: 0,
        layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description) == noErr,
        let description else { return nil }
    var block: CMBlockBuffer?
    let length = values.count * MemoryLayout<Float>.size
    guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
        blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: length,
        flags: 0, blockBufferOut: &block) == noErr, let block else { return nil }
    let copied = values.withUnsafeBytes { bytes in
        CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
    }
    guard copied == noErr else { return nil }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    var sampleSize = Int(4 * channels)
    var buffer: CMSampleBuffer?
    guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: description,
        sampleCount: values.count / Int(channels), sampleTimingEntryCount: 1, sampleTimingArray: &timing,
        sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &buffer) == noErr else { return nil }
    return buffer
}
