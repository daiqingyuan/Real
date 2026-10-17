import AppKit
import ApplicationServices
import Combine
import Foundation

private final class QQPlaybackActionLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    func cancel() { lock.lock(); active = false; lock.unlock() }
    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active }
}

/// Reads the licensed adapter's desktop-player snapshots and uses public Accessibility only
/// for explicit transport actions. No playback command is issued by observation.
@MainActor
final class QQPlaybackService: ObservableObject {
    @Published private(set) var title = ""
    @Published private(set) var artist = ""
    @Published private(set) var album = ""
    @Published private(set) var isPlaying = false
    @Published private(set) var position = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var artwork: NSImage?
    @Published private(set) var hasTiming = false
    @Published private(set) var canSeek = false
    @Published private(set) var canPlayPause = false
    @Published private(set) var canPrevious = false
    @Published private(set) var canNext = false
    @Published private(set) var errorMessage: String?
    let player: DesktopPlayerKind
    var sourceName: String { tr(player.sourceName) }
    var sourceBundleIdentifier: String { player.bundleID }

    private let queue = DispatchQueue(label: "local.dan.real.qq-accessibility", qos: .utility)
    private var timer: Timer?
    private var transportInFlight = false
    private var trackTransition = DesktopTrackTransition()
    private var inFlight = false
    private var started = false
    private var observedPID: pid_t?
    private var actionLifetime = QQPlaybackActionLifetime()
    private var generation = 0
    private var stream: QQAdapterProcess?
    private var heartbeat: QQAdapterProcess?
    private var userAction: QQAdapterProcess?
    private var verificationTask: Task<Void, Never>?
    private var anchor: QQMediaAnchor?
    private var rawAnchor: QQMediaAnchor?
    private var seekFailure = QQSeekFailureState()
    private var lastVerified = Date.distantPast
    private var lastHeartbeat = Date.distantPast
    private var retryAt = Date.distantPast
    private var retryDelay = 2.0
    private var nextAXPoll = Date.distantPast
    private let scriptURL: URL?
    private let frameworkURL: URL?
    private let runningPlayerPID: () -> pid_t?

    init(player: DesktopPlayerKind = .qq, scriptURL: URL? = Bundle.main.resourceURL?.appendingPathComponent("mediaremote-adapter.pl"),
         frameworkURL: URL? = Bundle.main.privateFrameworksURL?.appendingPathComponent("MediaRemoteAdapter.framework"),
         runningPlayerPID: (() -> pid_t?)? = nil) {
        self.player = player
        self.scriptURL = scriptURL; self.frameworkURL = frameworkURL
        self.runningPlayerPID = runningPlayerPID ?? {
            NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleID).first?.processIdentifier
        }
    }

    private func message(_ key: String) -> String {
        let value = tr(key)
        guard player == .netease else { return value }
        return ["QQ 音乐", "QQ Music", "QQ 音楽", "QQ音楽"].reduce(value) {
            $0.replacingOccurrences(of: $1, with: sourceName)
        }
    }

    func start() {
        guard !started else { return }
        started = true
        actionLifetime = QQPlaybackActionLifetime()
        generation += 1
        lastHeartbeat = .distantPast
        tick()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer.tolerance = 0.04
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        started = false
        observedPID = nil
        actionLifetime.cancel()
        timer?.invalidate()
        timer = nil
        generation += 1
        inFlight = false; transportInFlight = false; trackTransition.reset()
        stream?.stop(); stream = nil; heartbeat?.stop(); heartbeat = nil
        userAction?.stop(); userAction = nil; verificationTask?.cancel(); verificationTask = nil
        anchor = nil; rawAnchor = nil; seekFailure.clear(); lastVerified = .distantPast; retryAt = .distantPast
        clear()
        errorMessage = nil
    }

    deinit { actionLifetime.cancel(); timer?.invalidate(); verificationTask?.cancel() }

    func playPause() { perform(.playPause) }
    func previous() { perform(.previous) }
    func next() { perform(.next) }
    func seek(to seconds: Double) {
        guard started, canSeek, !transportInFlight, userAction == nil, verificationTask == nil, seconds.isFinite,
              let current = anchor, seconds >= 0, seconds <= current.duration,
              let scriptURL, let frameworkURL else { return }
        errorMessage = nil
        let token = generation
        let bundleID = sourceBundleIdentifier
        var fresh: QQMediaAnchor?
        do {
            userAction = try QQAdapterProcess(script: scriptURL, framework: frameworkURL, streaming: false,
                onValue: { data in fresh = QQMediaAnchor.decode(data, expectedPID: current.processID, expectedBundleID: bundleID) },
                onEnd: { [weak self] status in
                    guard let self, self.generation == token else { return }
                    self.userAction = nil
                    guard status == 0, let fresh, fresh.contentID == current.contentID,
                          fresh.title == current.title, fresh.artist == current.artist,
                          self.runningPlayerPID() == current.processID,
                          self.anchor?.hasSameTrack(as: current) == true, seconds <= fresh.duration else {
                        self.errorMessage = self.message("QQ 音乐播放来源已改变，未执行定位。"); return
                    }
                    self.performSeek(seconds, identity: fresh, token: token)
                })
        } catch { errorMessage = message("QQ 音乐定位失败，请重试。") }
    }

    private func performSeek(_ seconds: Double, identity: QQMediaAnchor, token: Int) {
        guard generation == token, let scriptURL, let frameworkURL else { return }
        guard runningPlayerPID() == identity.processID, identity.sourceBundleIdentifier == sourceBundleIdentifier,
              anchor?.hasSameTrack(as: identity) == true else {
            errorMessage = message("QQ 音乐播放来源已改变，未执行定位。")
            return
        }
        // The adapter targets the system's current player. The read immediately
        // above narrows, but cannot atomically eliminate, the source-change race.
        do {
            userAction = try QQAdapterProcess(script: scriptURL, framework: frameworkURL, streaming: false, seekSeconds: seconds,
                onValue: { _ in }, onEnd: { [weak self] status in
                    guard let self, self.generation == token else { return }
                    let shouldVerify = self.userAction?.seekMayHaveBeenDispatched == true
                    self.userAction = nil
                    guard shouldVerify else { self.errorMessage = self.message("QQ 音乐定位失败，请重试。"); return }
                    self.verificationTask = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        guard !Task.isCancelled, let self, self.generation == token else { return }
                        self.verificationTask = nil
                        self.verifySeek(seconds, identity: identity, token: token)
                    }
                })
        } catch { errorMessage = message("QQ 音乐定位失败，请重试。") }
    }

    private func verifySeek(_ seconds: Double, identity: QQMediaAnchor, token: Int, attempt: Int = 0) {
        guard let scriptURL, let frameworkURL else { return }
        var verified = false
        do {
            userAction = try QQAdapterProcess(script: scriptURL, framework: frameworkURL, streaming: false,
                onValue: { [weak self] data in
                    guard let self, self.generation == token,
                          self.runningPlayerPID() == identity.processID,
                          self.anchor?.hasSameTrack(as: identity) == true,
                          let value = QQMediaAnchor.decode(data, expectedPID: identity.processID, expectedBundleID: self.sourceBundleIdentifier),
                          value.hasSameTrack(as: identity),
                          let position = value.position(at: Date()), abs(position - seconds) <= 3 else { return }
                    verified = true; self.seekFailure.clear(); self.accept(data, streaming: false); self.errorMessage = nil
                }, onEnd: { [weak self] status in
                    guard let self, self.generation == token else { return }
                    self.userAction = nil
                    if status == 0, !verified, attempt < 3 {
                        self.verificationTask = Task { [weak self] in
                            try? await Task.sleep(nanoseconds: 400_000_000)
                            guard !Task.isCancelled, let self, self.generation == token else { return }
                            self.verificationTask = nil
                            self.verifySeek(seconds, identity: identity, token: token, attempt: attempt + 1)
                        }
                    } else if status != 0 || !verified {
                        guard self.anchor?.hasSameTrack(as: identity) == true else { return }
                        self.seekFailure.record(identity)
                        self.canSeek = false
                        self.errorMessage = self.message("尚未确认 QQ 音乐定位结果，请检查播放器。")
                        // The observed clock is still valid. A failed seek must
                        // not zero the position or discard the current lyrics.
                    } else { self.errorMessage = nil }
                })
        } catch { errorMessage = message("QQ 音乐定位失败，请重试。") }
    }

    private func tick() {
        guard started else { return }
        let now = Date()
        let playerPID = runningPlayerPID()
        if observedPID != playerPID {
            // Cancel old PID work before a quit/relaunch can reuse metadata or AX replies.
            generation += 1; actionLifetime.cancel(); actionLifetime = QQPlaybackActionLifetime()
            observedPID = playerPID; inFlight = false; transportInFlight = false; trackTransition.reset()
            stream?.stop(); stream = nil; heartbeat?.stop(); heartbeat = nil
            userAction?.stop(); userAction = nil; verificationTask?.cancel(); verificationTask = nil
            anchor = nil; rawAnchor = nil; lastVerified = .distantPast; lastHeartbeat = .distantPast
            nextAXPoll = .distantPast; retryAt = .distantPast; retryDelay = 2
            seekFailure.clear(); clear()
        }
        guard let playerPID else {
            anchor = nil; rawAnchor = nil; clear(); stream?.stop(); stream = nil; heartbeat?.stop(); heartbeat = nil
            errorMessage = message("QQ 音乐尚未运行。请手动打开 QQ 音乐。"); return
        }
        if let anchor, anchor.processID == playerPID,
           now.timeIntervalSince(lastVerified) <= 20, let value = anchor.position(at: now) {
            position = value; hasTiming = true
            isPlaying = trackTransition.resolve(observed: anchor.playing, previous: isPlaying, at: now)
        } else { anchor = nil; rawAnchor = nil; hasTiming = false; canSeek = false; position = 0 }
        if stream == nil, now >= retryAt { beginAdapter(streaming: true) }
        if heartbeat == nil, now.timeIntervalSince(lastHeartbeat) >= 10 {
            lastHeartbeat = now; beginAdapter(streaming: false)
        }
        if now >= nextAXPoll { nextAXPoll = now.addingTimeInterval(2); poll() }
    }

    private func beginAdapter(streaming: Bool) {
        guard let scriptURL, let frameworkURL,
              FileManager.default.fileExists(atPath: scriptURL.path),
              FileManager.default.fileExists(atPath: frameworkURL.path) else { retryAt = Date().addingTimeInterval(30); return }
        let token = generation
        let verificationBeforeRead = lastVerified
        do {
            let reader = try QQAdapterProcess(script: scriptURL, framework: frameworkURL, streaming: streaming,
                onValue: { [weak self] data in
                    guard let self, self.generation == token else { return }
                    if !streaming, self.lastVerified > verificationBeforeRead { return }
                    self.accept(data, streaming: streaming)
                }, onEnd: { [weak self] status in
                    guard let self, self.generation == token else { return }
                    // A helper can exit during player/sleep transitions. Release
                    // only this reader and retry with the existing bounded delay;
                    // one failed heartbeat must not kill a healthy stream or make
                    // lyrics unavailable until the user restarts QQ or Real.
                    if streaming {
                        self.stream = nil; self.retryAt = Date().addingTimeInterval(self.retryDelay)
                        self.retryDelay = min(30, self.retryDelay * 2)
                    } else { self.heartbeat = nil }
                })
            if streaming { stream = reader } else { heartbeat = reader }
        } catch { retryAt = Date().addingTimeInterval(retryDelay); retryDelay = min(30, retryDelay * 2) }
    }

    private func accept(_ data: Data, streaming: Bool) {
        let snapshotData: Data
        if streaming {
            guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  envelope["type"] as? String == "data" else { return }
            guard (envelope["diff"] as? Bool) == false,
                  let payload = envelope["payload"] as? [String: Any],
                  let encoded = try? JSONSerialization.data(withJSONObject: payload) else { invalidateTiming(); return }
            snapshotData = encoded
        } else { snapshotData = data }
        guard let pid = runningPlayerPID(),
              let value = QQMediaAnchor.decode(snapshotData, expectedPID: pid, expectedBundleID: sourceBundleIdentifier) else { invalidateTiming(); return }
        let receivedAt = Date()
        guard let resolved = value.resolvingClock(previousRaw: rawAnchor, previousResolved: anchor,
                                                 receivedAt: receivedAt) else { return }
        guard let resolvedPosition = resolved.position(at: receivedAt) else { invalidateTiming(); return }
        seekFailure.observe(value)
        rawAnchor = value; anchor = resolved; lastVerified = receivedAt; retryDelay = 2
        if title != value.title { title = value.title }
        if artist != value.artist { artist = value.artist }
        if album != value.album { album = value.album }
        if duration != value.duration { duration = value.duration }
        isPlaying = trackTransition.resolve(observed: value.playing, previous: isPlaying, at: receivedAt)
        artwork = value.artworkData.flatMap(NSImage.init(data:))
        position = resolvedPosition; hasTiming = true
        canSeek = !value.contentID.isEmpty && !seekFailure.isBlocked(value)
        errorMessage = seekFailure.isBlocked(value) ? self.message("尚未确认 QQ 音乐定位结果，请检查播放器。") : nil
    }

    private func invalidateTiming() {
        anchor = nil; rawAnchor = nil; hasTiming = false; canSeek = false; position = 0
        // The system exposes one active clock. Retain this player's last metadata
        // when another player owns it; a lost clock never selects a lyric.
        if player == .qq { duration = 0; album = ""; artwork = nil }
    }

    private func poll() {
        guard started, !inFlight else { return }
        guard let pid = runningPlayerPID() else {
            clear(); errorMessage = message("QQ 音乐尚未运行。请手动打开 QQ 音乐。"); return
        }
        guard AXIsProcessTrusted() else {
            canPlayPause = false; canPrevious = false; canNext = false
            if anchor == nil { clear(); errorMessage = message("读取和控制 QQ 音乐需要在系统设置中允许 Real 使用辅助功能。") }; return
        }
        inFlight = true
        let currentGeneration = generation
        let player = player
        queue.async { [weak self] in
            let snapshot = QQAccessibilityReader.snapshot(pid: pid, player: player)
            Task { @MainActor in
                guard let self, self.started, self.generation == currentGeneration else { return }
                self.inFlight = false
                guard self.runningPlayerPID() == pid else { return }
                if self.anchor == nil {
                    if self.player == .qq {
                        self.title = snapshot.track?.title ?? ""
                        self.artist = snapshot.track?.artist ?? ""
                    }
                    self.isPlaying = self.trackTransition.resolve(observed: snapshot.isPlaying,
                        previous: self.isPlaying, at: Date())
                }
                self.canPlayPause = snapshot.canPlayPause
                self.canPrevious = snapshot.canPrevious && (self.player == .qq || self.anchor != nil)
                self.canNext = snapshot.canNext && (self.player == .qq || self.anchor != nil)
                if self.anchor != nil { return }
                self.errorMessage = self.title.isEmpty
                    ? self.message("未能读取 QQ 音乐当前歌曲。请打开其主窗口后重试。")
                    : self.message("已读取 QQ 音乐歌曲信息；当前接口不提供播放时间，同步歌词暂不可用。")
            }
        }
    }

    private func perform(_ command: QQTransportCommand) {
        guard started, !transportInFlight, userAction == nil, verificationTask == nil else { return }
        guard !title.isEmpty, AXIsProcessTrusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: sourceBundleIdentifier).first else {
            errorMessage = message("QQ 音乐未运行或辅助功能权限不可用。")
            return
        }
        if player == .netease {
            if command == .playPause, anchor == nil {
                performSourceLocalToggle(pid: app.processIdentifier)
                return
            }
            performVerifiedMenuCommand(command, pid: app.processIdentifier)
            return
        }
        transportInFlight = true
        let currentGeneration = generation
        let pid = app.processIdentifier
        let lifetime = actionLifetime
        let targetBundleID = sourceBundleIdentifier
        let expected = QQTrackLabel(title: title, artist: artist)
        queue.async { [weak self] in
            guard lifetime.isActive, let app = NSRunningApplication(processIdentifier: pid),
                  !app.isTerminated, app.bundleIdentifier == targetBundleID else { return }
            let result = QQAccessibilityReader.perform(command, pid: pid, expected: expected,
                stillActive: { lifetime.isActive })
            Task { @MainActor in
                guard let self, self.generation == currentGeneration else { return }
                self.transportInFlight = false
                switch result {
                case .verified: self.errorMessage = self.anchor.map { self.seekFailure.isBlocked($0) } == true ? self.message("尚未确认 QQ 音乐定位结果，请检查播放器。") : nil; self.poll()
                case .dispatched, .unconfirmed: self.errorMessage = self.message("尚未确认 QQ 音乐播放控制结果，请检查播放器。")
                case .unavailable: self.errorMessage = self.message("QQ 音乐未提供可用的播放控制按钮，操作未执行。")
                }
            }
        }
    }

    private func performSourceLocalToggle(pid: pid_t) {
        transportInFlight = true
        trackTransition.reset()
        let token = generation, player = player, lifetime = actionLifetime
        queue.async { [weak self] in
            let result: QQTransportResult
            if lifetime.isActive, let app = NSRunningApplication(processIdentifier: pid),
               !app.isTerminated, app.bundleIdentifier == player.bundleID {
                result = QQAccessibilityReader.togglePlayback(pid: pid, player: player,
                    stillActive: { lifetime.isActive })
            } else { result = .unavailable }
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.transportInFlight = false
                if case .verified = result { self.errorMessage = nil }
                else { self.errorMessage = self.message("尚未确认 QQ 音乐播放控制结果，请检查播放器。") }
                self.poll()
            }
        }
    }

    /// NetEase does not expose its track in the AX content tree. A fresh
    /// adapter read establishes identity, while the action itself is delivered
    /// to this exact app PID through its native menu, never a global media key.
    private func performVerifiedMenuCommand(_ command: QQTransportCommand, pid: pid_t) {
        guard let current = anchor, current.processID == pid,
              let scriptURL, let frameworkURL else {
            errorMessage = message("QQ 音乐播放来源已改变，未执行定位。")
            return
        }
        transportInFlight = true
        let token = generation
        let player = player
        var fresh: QQMediaAnchor?
        do {
            userAction = try QQAdapterProcess(script: scriptURL, framework: frameworkURL, streaming: false,
                onValue: { data in
                    fresh = QQMediaAnchor.decode(data, expectedPID: pid, expectedBundleID: player.bundleID)
                }, onEnd: { [weak self] status in
                    guard let self, self.generation == token else { return }
                    self.userAction = nil
                    guard status == 0, let fresh, fresh.hasSameTrack(as: current),
                          self.runningPlayerPID() == pid, self.anchor?.hasSameTrack(as: current) == true else {
                        self.transportInFlight = false
                        self.errorMessage = self.message("QQ 音乐未提供可用的播放控制按钮，操作未执行。")
                        return
                    }
                    let lifetime = self.actionLifetime
                    self.trackTransition.begin(command, at: Date())
                    self.queue.async { [weak self] in
                        let result: QQTransportResult
                        if lifetime.isActive, let app = NSRunningApplication(processIdentifier: pid),
                           !app.isTerminated, app.bundleIdentifier == player.bundleID {
                            result = QQAccessibilityReader.perform(command, pid: pid,
                                expected: QQTrackLabel(title: fresh.title, artist: fresh.artist),
                                player: player, verifiedAnchor: fresh, stillActive: { lifetime.isActive })
                        } else { result = .unavailable }
                        Task { @MainActor [weak self] in
                            guard let self, self.generation == token else { return }
                            if case .dispatched = result {
                                self.verifyMenuCommand(command, before: fresh, token: token)
                            } else {
                                self.transportInFlight = false
                                self.errorMessage = self.message("QQ 音乐未提供可用的播放控制按钮，操作未执行。")
                            }
                        }
                    }
                })
        } catch {
            transportInFlight = false
            errorMessage = message("尚未确认 QQ 音乐播放控制结果，请检查播放器。")
        }
    }

    private func verifyMenuCommand(_ command: QQTransportCommand, before: QQMediaAnchor, token: Int, attempt: Int = 0) {
        guard generation == token, let scriptURL, let frameworkURL else { return }
        var verified = false
        do {
            userAction = try QQAdapterProcess(script: scriptURL, framework: frameworkURL, streaming: false,
                onValue: { [weak self] data in
                    guard let self, self.generation == token, self.runningPlayerPID() == before.processID,
                          let after = QQMediaAnchor.decode(data, expectedPID: before.processID,
                              expectedBundleID: self.sourceBundleIdentifier),
                          DesktopTransportVerification.confirms(command, before: before, after: after) else { return }
                    verified = true
                    self.accept(data, streaming: false)
                    self.errorMessage = nil
                }, onEnd: { [weak self] _ in
                    guard let self, self.generation == token else { return }
                    self.userAction = nil
                    if verified {
                        self.transportInFlight = false
                        self.poll()
                    } else if attempt < 3, self.runningPlayerPID() == before.processID {
                        self.verificationTask = Task { [weak self] in
                            try? await Task.sleep(nanoseconds: 350_000_000)
                            guard !Task.isCancelled, let self, self.generation == token else { return }
                            self.verificationTask = nil
                            self.verifyMenuCommand(command, before: before, token: token, attempt: attempt + 1)
                        }
                    } else {
                        self.transportInFlight = false
                        self.errorMessage = self.message("尚未确认 QQ 音乐播放控制结果，请检查播放器。")
                    }
                })
        } catch {
            transportInFlight = false
            errorMessage = message("尚未确认 QQ 音乐播放控制结果，请检查播放器。")
        }
    }

    private func clear() {
        title = ""; artist = ""; album = ""; artwork = nil
        isPlaying = false; position = 0; duration = 0
        hasTiming = false; canSeek = false
        canPlayPause = false; canPrevious = false; canNext = false
    }
}

struct QQTrackLabel: Equatable {
    let title: String
    let artist: String

    /// MediaRemote may expose only the lead singer while QQ's AX label lists
    /// slash-separated collaborators. Require an exact title and full artist component.
    func represents(_ published: QQTrackLabel) -> Bool {
        title == published.title && (artist == published.artist || artist.split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.contains(published.artist))
    }

    /// This exact labelled form was observed in QQ Music's current native AX tree.
    /// Do not split generic "title - artist" text or derive a clock from labels.
    static func parse(_ label: String) -> QQTrackLabel? {
        let text = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "歌曲名："
        let separator = " - 歌手名："
        guard text.hasPrefix(prefix), let range = text.range(of: separator) else { return nil }
        let title = String(text[text.index(text.startIndex, offsetBy: prefix.count)..<range.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        return QQTrackLabel(title: title, artist: artist)
    }
}

enum QQTransportCommand { case playPause, previous, next }
private enum QQTransportResult { case verified, dispatched, unconfirmed, unavailable }

struct QQPlaybackSnapshot {
    var track: QQTrackLabel?
    var isPlaying = false
    var canPlayPause = false
    var canPrevious = false
    var canNext = false

    func confirms(_ command: QQTransportCommand, after before: QQPlaybackSnapshot) -> Bool {
        guard let track, let oldTrack = before.track else { return false }
        switch command {
        case .playPause: return track == oldTrack && isPlaying != before.isPlaying
        case .previous, .next: return track != oldTrack
        }
    }
}

/// All reader calls execute serially on QQPlaybackService's worker queue.
private enum QQAccessibilityReader {
    private struct Node {
        let element: AXUIElement
        let role: String
        let strings: [String]
        let enabled: Bool
    }

    static func snapshot(pid: pid_t, player: DesktopPlayerKind = .qq) -> QQPlaybackSnapshot {
        let nodes = player == .qq ? readNodes(pid: pid) : []
        var result = QQPlaybackSnapshot()
        let tracks = nodes.flatMap(\.strings).compactMap(QQTrackLabel.parse)
        let unique = Set(tracks.map { $0.title + "\u{0}" + $0.artist })
        if unique.count == 1 { result.track = tracks.first }
        let buttons = nodes.filter { $0.role == kAXButtonRole as String && $0.enabled }
        let menu = playbackMenuItems(pid: pid, player: player)
        if menu.contains(where: { $0.enabled && $0.strings.contains(where: pauseLabels.contains) }) { result.isPlaying = true }
        else if menu.contains(where: { $0.enabled && $0.strings.contains(where: playLabels.contains) }) { result.isPlaying = false }
        else { result.isPlaying = buttons.contains { $0.strings.contains("暂停播放") } }
        result.canPlayPause = buttons.contains { $0.strings.contains("暂停播放") || $0.strings.contains("播放") || $0.strings.contains("开始播放") }
        result.canPrevious = buttons.contains { $0.strings.contains("上一首") }
        result.canNext = buttons.contains { $0.strings.contains("下一首") }
        result.canPlayPause = result.canPlayPause || menu.contains { $0.enabled && $0.strings.contains(where: (pauseLabels.union(playLabels)).contains) }
        result.canPrevious = result.canPrevious || menu.contains { $0.enabled && $0.strings.contains(where: previousLabels.contains) }
        result.canNext = result.canNext || menu.contains { $0.enabled && $0.strings.contains(where: nextLabels.contains) }
        return result
    }

    private static let pauseLabels: Set<String> = ["暂停", "暫停", "Pause"]
    private static let playLabels: Set<String> = ["播放", "Play"]
    private static let previousLabels: Set<String> = ["上一首", "上一个", "Previous", "Previous Track"]
    private static let nextLabels: Set<String> = ["下一首", "下一个", "Next", "Next Track"]

    static func perform(_ command: QQTransportCommand, pid: pid_t, expected: QQTrackLabel,
                        player: DesktopPlayerKind = .qq, verifiedAnchor: QQMediaAnchor? = nil,
                        stillActive: () -> Bool) -> QQTransportResult {
        var before = snapshot(pid: pid, player: player)
        if player == .netease {
            guard let verifiedAnchor, verifiedAnchor.processID == pid,
                  verifiedAnchor.sourceBundleIdentifier == player.bundleID,
                  QQTrackLabel(title: verifiedAnchor.title, artist: verifiedAnchor.artist) == expected else { return .unavailable }
            before.track = expected; before.isPlaying = verifiedAnchor.playing
        }
        guard before.track?.represents(expected) == true, stillActive() else { return .unavailable }
        let menuLabels: Set<String>
        let buttonLabels: Set<String>
        switch command {
        case .playPause:
            menuLabels = before.isPlaying ? pauseLabels : playLabels
            buttonLabels = before.isPlaying ? ["暂停播放"] : ["播放", "开始播放"]
        case .previous: menuLabels = previousLabels; buttonLabels = ["上一首"]
        case .next: menuLabels = nextLabels; buttonLabels = ["下一首"]
        }
        // QQ's toolbar can report AXPress success without changing playback.
        // Prefer the real Playback menu observed in the native accessibility tree.
        let menu = playbackMenuItems(pid: pid, player: player).filter { $0.enabled && $0.strings.contains(where: menuLabels.contains) }
        let candidates = menu.isEmpty && player == .qq ? readNodes(pid: pid).filter {
            $0.role == kAXButtonRole as String && $0.enabled && $0.strings.contains(where: buttonLabels.contains)
        } : menu
        guard candidates.count == 1, stillActive(),
              AXUIElementPerformAction(candidates[0].element, kAXPressAction as CFString) == .success else { return .unavailable }
        if player == .netease { return .dispatched } // Verified by fresh adapter read-back on the owner.
        let deadline = ProcessInfo.processInfo.systemUptime + 1.6
        repeat {
            guard stillActive() else { return .unconfirmed }
            Thread.sleep(forTimeInterval: 0.12) // Worker queue only, never the main thread.
            if snapshot(pid: pid).confirms(command, after: before) { return .verified }
        } while ProcessInfo.processInfo.systemUptime < deadline
        // Never repeat a toggle just because confirmation was delayed.
        return .unconfirmed
    }

    /// A source-local toggle needs no global clock or guessed track identity.
    /// Its enabled native menu state supplies both the command and verification.
    static func togglePlayback(pid: pid_t, player: DesktopPlayerKind,
                               stillActive: () -> Bool) -> QQTransportResult {
        let before = snapshot(pid: pid, player: player)
        guard before.canPlayPause, stillActive() else { return .unavailable }
        let labels = before.isPlaying ? pauseLabels : playLabels
        let candidates = playbackMenuItems(pid: pid, player: player).filter {
            $0.enabled && $0.strings.contains(where: labels.contains)
        }
        guard candidates.count == 1, stillActive(),
              AXUIElementPerformAction(candidates[0].element, kAXPressAction as CFString) == .success else { return .unavailable }
        let deadline = ProcessInfo.processInfo.systemUptime + 1.6
        repeat {
            guard stillActive() else { return .unconfirmed }
            Thread.sleep(forTimeInterval: 0.12)
            let after = snapshot(pid: pid, player: player)
            if after.canPlayPause && after.isPlaying != before.isPlaying { return .verified }
        } while ProcessInfo.processInfo.systemUptime < deadline
        return .unconfirmed
    }

    private static func playbackMenuItems(pid: pid_t, player: DesktopPlayerKind) -> [Node] {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.15)
        guard let raw = value(application, kAXMenuBarAttribute as CFString),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return [] }
        let bar = unsafeBitCast(raw, to: AXUIElement.self)
        let menus = value(bar, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
        let labels = player.menuTitles
        var result: [Node] = []
        for menu in menus.prefix(20) where labels.contains(value(menu, kAXTitleAttribute as CFString) as? String ?? "") {
            let containers = value(menu, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
            for container in containers.prefix(4) {
                let items = value(container, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
                for item in items.prefix(40) {
                    let role = value(item, kAXRoleAttribute as CFString) as? String ?? ""
                    guard role == kAXMenuItemRole as String else { continue }
                    let title = value(item, kAXTitleAttribute as CFString) as? String ?? ""
                    let enabled = (value(item, kAXEnabledAttribute as CFString) as? NSNumber)?.boolValue ?? false
                    result.append(Node(element: item, role: role, strings: [title], enabled: enabled))
                }
            }
        }
        return result
    }

    private static func readNodes(pid: pid_t) -> [Node] {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.15)
        guard let windows = value(application, kAXWindowsAttribute as CFString) as? [AXUIElement] else { return [] }
        var pending = windows.map { ($0, 0) }
        var cursor = 0
        var nodes: [Node] = []
        let deadline = ProcessInfo.processInfo.systemUptime + 0.6
        // Breadth-first traversal reaches the player toolbar before spending the
        // bounded scan budget in a large playlist's deeply nested rows.
        while cursor < pending.count, nodes.count < 220,
              ProcessInfo.processInfo.systemUptime < deadline {
            let (element, depth) = pending[cursor]
            cursor += 1
            let role = value(element, kAXRoleAttribute as CFString) as? String ?? ""
            let strings = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].compactMap {
                value(element, $0 as CFString) as? String
            }
            let enabled = (value(element, kAXEnabledAttribute as CFString) as? NSNumber)?.boolValue ?? true
            nodes.append(Node(element: element, role: role, strings: strings, enabled: enabled))
            if depth < 8, let children = value(element, kAXChildrenAttribute as CFString) as? [AXUIElement] {
                pending.append(contentsOf: children.prefix(220).map { ($0, depth + 1) })
            }
        }
        return nodes
    }

    private static func value(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &result) == .success else { return nil }
        return result
    }
}

/// A failed read-back is a track-scoped capability failure. Normal heartbeats
/// preserve it; changing tracks or an explicitly confirmed seek clears it.
struct QQSeekFailureState {
    private var track: QQMediaAnchor?
    mutating func record(_ value: QQMediaAnchor) { track = value }
    mutating func clear() { track = nil }
    mutating func observe(_ value: QQMediaAnchor) {
        if let track, !value.hasSameTrack(as: track) { clear() }
    }
    func isBlocked(_ value: QQMediaAnchor) -> Bool { track.map { $0.hasSameTrack(as: value) } ?? false }
}

/// Verification uses the same process and source as the explicit menu action.
/// An unrelated player taking over MediaRemote can never confirm that action.
enum DesktopTransportVerification {
    static func confirms(_ command: QQTransportCommand, before: QQMediaAnchor, after: QQMediaAnchor,
                         at now: Date = Date()) -> Bool {
        guard before.processID == after.processID,
              before.sourceBundleIdentifier == after.sourceBundleIdentifier else { return false }
        switch command {
        case .playPause: return after.hasSameTrack(as: before) && after.playing != before.playing
        case .next: return !after.hasSameTrack(as: before)
        case .previous:
            if !after.hasSameTrack(as: before) { return true }
            // Native Previous may restart the current song when already several
            // seconds in. Treat that observed transition as valid native behavior.
            guard let oldPosition = before.position(at: now), let newPosition = after.position(at: now) else { return false }
            return oldPosition > 5 && newPosition < 3
        }
    }
}

/// A brief stop while executing Next/Previous is buffering, not a new source.
/// An explicit pause cancels the grace period; a failed skip cannot hold forever.
struct DesktopTrackTransition {
    private var until = Date.distantPast
    mutating func begin(_ command: QQTransportCommand, at now: Date) {
        until = command == .playPause ? .distantPast : now.addingTimeInterval(2)
    }
    mutating func reset() { until = .distantPast }
    func resolve(observed: Bool, previous: Bool, at now: Date) -> Bool {
        observed || (previous && now < until)
    }
}
