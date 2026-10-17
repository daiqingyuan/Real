import Foundation

private final class MediaLifecycleProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var routes: [String] = []
    static func reset() { lock.lock(); routes = []; lock.unlock() }
    static func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return routes }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let host = request.url!.host!
        Self.lock.lock(); Self.routes.append(host + request.url!.path); Self.lock.unlock()
        let code = host == "throttled.test" ? 429 : 200
        var body = "{\"player\":{\"trackState\":\(host == "paused.test" ? 2 : 1),\"videoProgress\":500},\"video\":{\"title\":\"Fixture\",\"author\":\"Artist\",\"durationSeconds\":100,\"id\":\"fixture\",\"thumbnails\":[]}}"
        if request.url!.path.hasSuffix("/auth/requestcode") { body = "{\"code\":\"fixture-code\"}" }
        else if request.url!.path.hasSuffix("/auth/request") { body = "{\"token\":\"paired-fixture-token\"}" }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json", "Retry-After": "300"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Mocked companion requests only; no player controls, credentials or external requests.
@MainActor func runMediaLifecycleTests() async -> [String] {
    var failures: [String] = []
    func check(_ value: Bool, _ message: String) { if !value { failures.append(message) } }
    func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<100 { if predicate() { return }; try? await Task.sleep(nanoseconds: 10_000_000) }
    }
    MediaLifecycleProtocol.reset()
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MediaLifecycleProtocol.self]
    let session = URLSession(configuration: config)
    let service = YouTubeMusicService(session: session)
    service.configure(baseURL: "https://playing.test", token: "fixture-token")
    check(MediaLifecycleProtocol.snapshot().isEmpty, "YTM init/configure must remain network-inert")
    service.start()
    await waitUntil { !service.title.isEmpty }
    check(service.isPlaying && service.title == "Fixture", "YTM playing state is applied")
    check(service.position == service.duration && service.duration == 100, "YTM progress is clamped to track duration")
    service.playPause() // Queued but deliberately stopped before the task can execute.
    service.stop()
    try? await Task.sleep(nanoseconds: 30_000_000)
    check(!MediaLifecycleProtocol.snapshot().contains { $0.hasSuffix("/command") }, "YTM queued command must not run after stop")
    check(service.title.isEmpty && !service.isPlaying, "YTM stop clears stale playback state")
    service.configure(baseURL: "https://throttled.test", token: "fixture-token")
    service.start()
    await waitUntil { service.errorMessage != nil }
    check(service.errorMessage != nil, "YTM throttling fixture reached")
    service.configure(baseURL: "https://paused.test", token: "fixture-token")
    service.start()
    await waitUntil { !service.title.isEmpty }
    check(service.title == "Fixture" && !service.isPlaying, "New companion configuration ignores previous server throttle and retains paused metadata")
    service.next()
    service.configure(baseURL: "https://replacement.test", token: "new-fixture-token")
    service.start()
    await waitUntil { !service.title.isEmpty }
    check(!MediaLifecycleProtocol.snapshot().contains { $0.hasSuffix("/command") }, "Queued transport cannot cross to a new companion configuration")
    service.stop()
    var temporary: YouTubeMusicService? = YouTubeMusicService(session: session)
    weak let released = temporary
    temporary?.configure(baseURL: "https://playing.test", token: "fixture-token")
    temporary?.start()
    await waitUntil { temporary?.title == "Fixture" }
    temporary = nil
    await waitUntil { released == nil }
    check(released == nil, "YTM idle polling must not retain the service forever")
    service.configure(baseURL: "https://pairing.test", token: "")
    service.start()
    let canceledPairing = Task { await service.requestAuthorization() }
    canceledPairing.cancel()
    let canceledResult = await canceledPairing.value
    check(canceledResult == nil && !MediaLifecycleProtocol.snapshot().contains { $0.contains("pairing.test") },
          "canceled pairing task cannot start a new authorization exchange")
    let paired = await service.requestAuthorization()
    await waitUntil { service.title == "Fixture" }
    check(paired == "paired-fixture-token" && service.title == "Fixture",
          "explicit two-step pairing resumes state polling with its returned token")
    check(MediaLifecycleProtocol.snapshot().filter { $0.contains("pairing.test/api/v1/auth/") }.count == 2,
          "pairing performs only the code request and authorization request")
    service.stop()
    session.invalidateAndCancel()
    return failures
}

/// Executes small task-local Perl fixtures, never the installed media adapter.
@MainActor func runQQAdapterLifecycleTests() async -> [String] {
    var failures: [String] = []
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("real-adapter-tests-" + UUID().uuidString)
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("fixture.pl")
        try Data("print '{\"fixture\":true}';".utf8).write(to: script)
        var values: [Data] = []; var done = false; var status: Int32?
        let reader = try QQAdapterProcess(script: script, framework: directory, streaming: false,
            onValue: { values.append($0) }, onEnd: { status = $0; done = true })
        for _ in 0..<100 { if done { break }; try? await Task.sleep(nanoseconds: 10_000_000) }
        if values != [Data("{\"fixture\":true}".utf8)] || status != 0 { failures.append("QQ one-shot reader lost final output before process termination") }
        reader.stop()
        try Data("$|=1; print \"one\\ntwo\\n\"; sleep 10;".utf8).write(to: script)
        values = []; done = false
        let streaming = try QQAdapterProcess(script: script, framework: directory, streaming: true,
            onValue: { values.append($0) }, onEnd: { _ in done = true })
        for _ in 0..<100 { if values.count == 2 { break }; try? await Task.sleep(nanoseconds: 10_000_000) }
        if values != [Data("one".utf8), Data("two".utf8)] { failures.append("QQ streaming reader failed record framing") }
        streaming.stop()
        try? await Task.sleep(nanoseconds: 100_000_000)
        if done { failures.append("QQ explicit stop must suppress late process callbacks") }
        // Runs a synthetic Perl fixture, not the media adapter or a playback command.
        try Data("die 'unexpected arguments' unless $ARGV[1] eq 'seek' && $ARGV[2] eq '30000000'; print STDERR \"Failed to seek to 30000000\\n\"; exit 1;".utf8).write(to: script)
        done = false; status = nil
        let legacy = try QQAdapterProcess(script: script, framework: directory, streaming: false, seekSeconds: 30,
            onValue: { _ in }, onEnd: { status = $0; done = true })
        for _ in 0..<100 { if done { break }; try? await Task.sleep(nanoseconds: 10_000_000) }
        if status != 1 || !legacy.seekMayHaveBeenDispatched { failures.append("QQ seek fixture lost its exact stderr before completion or encoded the wrong units") }
        // Exercise the service recovery path with an isolated adapter script.
        // Its first stream fails, then the retry publishes synthetic metadata;
        // a failed heartbeat must not permanently disable the replacement stream.
        let marker = directory.appendingPathComponent("stream-started")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let snapshot: [String: Any] = ["bundleIdentifier": "com.tencent.QQMusicMac", "processIdentifier": 2_000_000_001,
            "title": "Recovery Fixture", "artist": "Fixture Artist", "contentItemIdentifier": "recovery-fixture",
            "duration": 600, "elapsedTime": 1, "playbackRate": 1, "playing": true, "timestamp": stamp]
        let envelope = String(data: try JSONSerialization.data(withJSONObject: ["type": "data", "diff": false, "payload": snapshot]), encoding: .utf8)!
        let retryScript = """
        $| = 1;
        if ($ARGV[1] ne 'stream') { exit 1; }
        if (!-e '\(marker.path)') { open(my $f, '>', '\(marker.path)'); close($f); exit 1; }
        print '\(envelope)' . "\\n";
        sleep 10;
        """
        try Data(retryScript.utf8).write(to: script)
        let recovery = QQPlaybackService(scriptURL: script, frameworkURL: directory, runningPlayerPID: { 2_000_000_001 })
        recovery.start()
        for _ in 0..<450 {
            if recovery.title == "Recovery Fixture", recovery.hasTiming { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        if recovery.title != "Recovery Fixture" || !recovery.hasTiming {
            failures.append("QQ transient helper exit must recover timing automatically without restarting the player")
        }
        recovery.stop()
        let neteaseMarker = directory.appendingPathComponent("netease-reader-started")
        var neteaseSnapshot = snapshot
        neteaseSnapshot["bundleIdentifier"] = DesktopPlayerKind.netease.bundleID
        neteaseSnapshot["title"] = "NetEase Fixture"
        neteaseSnapshot["timestamp"] = ISO8601DateFormatter().string(from: Date())
        let neteaseJSON = String(data: try JSONSerialization.data(withJSONObject: neteaseSnapshot), encoding: .utf8)!
        let neteaseEnvelope = String(data: try JSONSerialization.data(withJSONObject: ["type": "data", "diff": false, "payload": neteaseSnapshot]), encoding: .utf8)!
        let neteaseScript = """
        $| = 1;
        open(my $f, '>>', '\(neteaseMarker.path)'); print $f $ARGV[1] . "\\n"; close($f);
        if ($ARGV[1] eq 'stream') {
            print '\(neteaseEnvelope)' . "\\n";
            select(undef, undef, undef, 0.6);
            print '\(envelope)' . "\\n";
            sleep 10;
        }
        elsif ($ARGV[1] eq 'get') { print '\(neteaseJSON)'; }
        else { die 'No playback commands are allowed in a metadata fixture'; }
        """
        try Data(neteaseScript.utf8).write(to: script)
        let absentNetEase = QQPlaybackService(player: .netease, scriptURL: script, frameworkURL: directory, runningPlayerPID: { nil })
        absentNetEase.start()
        try? await Task.sleep(nanoseconds: 250_000_000)
        if FileManager.default.fileExists(atPath: neteaseMarker.path) { failures.append("Absent NetEase must not start media adapter processes") }
        absentNetEase.stop()
        let netease = QQPlaybackService(player: .netease, scriptURL: script, frameworkURL: directory, runningPlayerPID: { 2_000_000_001 })
        netease.start()
        for _ in 0..<100 {
            if netease.hasTiming { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        if netease.title != "NetEase Fixture" || !netease.hasTiming || !netease.canSeek
            || netease.sourceBundleIdentifier != DesktopPlayerKind.netease.bundleID || netease.sourceName != "网易云音乐" {
            failures.append("NetEase service must publish its own validated metadata, clock and seek capability")
        }
        for _ in 0..<150 {
            if !netease.hasTiming { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        if netease.hasTiming || netease.canSeek || netease.title != "NetEase Fixture" || netease.duration != 600 {
            failures.append("NetEase losing the global clock must retain source metadata but disable timed lyrics and seek")
        }
        netease.stop()
        if !netease.title.isEmpty || netease.duration != 0 {
            failures.append("NetEase stop must discard retained metadata")
        }
        let qqReceivingNetEase = QQPlaybackService(scriptURL: script, frameworkURL: directory, runningPlayerPID: { 2_000_000_001 })
        qqReceivingNetEase.start()
        try? await Task.sleep(nanoseconds: 300_000_000)
        if qqReceivingNetEase.hasTiming || qqReceivingNetEase.canSeek || qqReceivingNetEase.title == "NetEase Fixture" {
            failures.append("QQ service must reject NetEase snapshot even when PID and metadata otherwise match")
        }
        qqReceivingNetEase.stop()
        let inactive = QQPlaybackService(scriptURL: nil, frameworkURL: nil)
        inactive.playPause(); inactive.next(); inactive.previous()
        if inactive.errorMessage != nil { failures.append("Inactive QQ transport should be ignored without a false permission error") }
    } catch { failures.append("QQ adapter fixture failed: \(type(of: error))") }
    return failures
}
