import Foundation
import Darwin

/// A single owned Perl host. This wrapper is original; the loaded adapter is a
/// separately licensed dependency. A seek is only supplied by the explicit
/// user-action path after a fresh source-identity check.
@MainActor final class QQAdapterProcess {
    private var process: Process?
    private var output: Pipe?
    private var errors: Pipe?
    private var buffer = Data()
    private var errorBuffer = Data()
    private var reachedErrorEOF = false
    private let seekMicroseconds: Int64?

    var seekMayHaveBeenDispatched: Bool {
        QQSeekCompletionPolicy.shouldVerify(status: exitStatus, requestedMicroseconds: seekMicroseconds,
            stderr: String(decoding: errorBuffer, as: UTF8.self))
    }
    private var timeout: Task<Void, Never>?
    private var stopped = false
    private var sawRecord = false
    private var reachedEOF = false
    private var exitStatus: Int32?
    private let onValue: (Data) -> Void
    private let onEnd: (Int32?) -> Void
    private let streaming: Bool

    init(script: URL, framework: URL, streaming: Bool, seekSeconds: Double? = nil,
         onValue: @escaping (Data) -> Void, onEnd: @escaping (Int32?) -> Void) throws {
        self.streaming = streaming; self.onValue = onValue; self.onEnd = onEnd
        if let seconds = seekSeconds {
            precondition(!streaming && seconds.isFinite && seconds >= 0 && seconds <= 604_800)
            seekMicroseconds = Int64((seconds * 1_000_000).rounded())
        } else { seekMicroseconds = nil }
        let process = Process(), output = Pipe(), errors = Pipe()
        self.process = process; self.output = output; self.errors = errors
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        var environment = ProcessInfo.processInfo.environment
        environment["REAL_PARENT_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        process.environment = environment
        if let seekMicroseconds {
            process.arguments = [script.path, framework.path, "seek", String(seekMicroseconds)]
        } else {
            process.arguments = [script.path, framework.path, streaming ? "stream" : "get"]
                + (streaming ? ["--no-diff", "--debounce=100"] : [])
        }
        process.standardOutput = output; process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in self?.receive(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in
                guard let self, !self.stopped else { return }
                if data.isEmpty {
                    self.reachedErrorEOF = true
                    self.errors?.fileHandleForReading.readabilityHandler = nil
                    self.finishIfExited()
                    return
                }
                guard self.errorBuffer.count + data.count <= 65_536 else { self.finish(); return }
                self.errorBuffer.append(data)
            }
        }
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                guard let self, !self.stopped else { return }
                self.exitStatus = process.terminationStatus
                self.finishIfExited()
            }
        }
        do { try process.run() } catch { stop(); throw error }
        timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self else { return }
            if !self.streaming || !self.sawRecord { self.finish() }
        }
    }

    func stop() {
        guard !stopped else { return }; stopped = true
        timeout?.cancel(); timeout = nil
        output?.fileHandleForReading.readabilityHandler = nil
        errors?.fileHandleForReading.readabilityHandler = nil
        try? output?.fileHandleForReading.close(); try? errors?.fileHandleForReading.close()
        if let process, process.isRunning {
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        process?.terminationHandler = nil
        process = nil; output = nil; errors = nil; buffer.removeAll()
    }

    deinit {
        timeout?.cancel()
        output?.fileHandleForReading.readabilityHandler = nil
        errors?.fileHandleForReading.readabilityHandler = nil
        try? output?.fileHandleForReading.close(); try? errors?.fileHandleForReading.close()
        if let process, process.isRunning {
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }

    private func receive(_ data: Data) {
        guard !stopped else { return }
        if data.isEmpty {
            reachedEOF = true
            output?.fileHandleForReading.readabilityHandler = nil
            if !streaming, !buffer.isEmpty { onValue(buffer); buffer.removeAll() }
            finishIfExited()
            return
        }
        buffer.append(data)
        guard buffer.count <= 2_000_000 else { finish(); return }
        if streaming {
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                guard !line.isEmpty else { continue }
                sawRecord = true; onValue(line)
            }
        }
    }

    private func finishIfExited() {
        guard reachedEOF, reachedErrorEOF, let status = exitStatus else { return }
        finish(status: status)
    }

    private func finish(status: Int32? = nil) { guard !stopped else { return }; stop(); onEnd(status) }
}

/// Older bundled adapters incorrectly tested the return of a void MediaRemote
/// seek function as Bool (upstream fix: ungive/mediaremote-adapter#34).
/// This exact legacy error permits a read-back check, never a success claim.
enum QQSeekCompletionPolicy {
    static func shouldVerify(status: Int32?, requestedMicroseconds: Int64?, stderr: String) -> Bool {
        guard let requestedMicroseconds else { return false }
        if status == 0 { return true }
        guard status == 1 else { return false }
        let diagnostic = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return diagnostic == "Failed to seek to \(requestedMicroseconds)"
            || diagnostic == "Failed to seek to \(Int32(truncatingIfNeeded: requestedMicroseconds))"
    }
}
