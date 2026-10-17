import Foundation

private final class LyricsLifecycleProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var titles: [String] = []
    private var pending: DispatchWorkItem?
    static func reset() { lock.lock(); titles = []; lock.unlock() }
    static func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return titles }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { pending?.cancel() }
    override func startLoading() {
        let title = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "track_name" }?.value ?? ""
        Self.lock.lock(); Self.titles.append(title)
        let attempt = Self.titles.filter { $0 == title }.count
        Self.lock.unlock()
        let work = DispatchWorkItem { [weak self] in
            guard let self, pending?.isCancelled != true else { return }
            if title == "Always offline" || title == "Cancel retry" || (["Transient", "Manual failure"].contains(title) && attempt == 1) {
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
                return
            }
            if ["Throttled", "Global throttle", "Manual throttle"].contains(title) && attempt == 1 {
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json", "Retry-After": "1"])!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data("[]".utf8))
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            let records: [[String: Any]] = [
                ["trackName": title, "artistName": "Fixture Artist", "duration": 200,
                 "instrumental": false, "syncedLyrics": "[00:01]Long catalog fixture: " + title],
                ["trackName": title, "artistName": "Fixture Artist", "duration": 100,
                 "instrumental": false, "syncedLyrics": "[00:01]Short catalog fixture: " + title]
            ]
            let data = try! JSONSerialization.data(withJSONObject: title == "Manual empty" && attempt == 1 ? [] : records)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        pending = work
        DispatchQueue.global().asyncAfter(deadline: .now() + (title == "Delayed" ? 0.7 : 0.01), execute: work)
    }
}

/// Fully intercepted URLSession traffic; synthetic text only, no live provider calls.
@MainActor func runLyricsLifecycleTests() async -> [String] {
    var failures: [String] = []
    func check(_ value: Bool, _ message: String) { if !value { failures.append("Lyrics lifecycle: " + message) } }
    func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<200 { if predicate() { return }; try? await Task.sleep(nanoseconds: 10_000_000) }
    }
    LyricsLifecycleProtocol.reset()
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [LyricsLifecycleProtocol.self]
    let session = URLSession(configuration: config)
    let service = LyricsService(session: session)
    func load(_ title: String, duration: Double = 0, source: String = "com.apple.Music") {
        service.load(sourceBundleIdentifier: source, title: title, artist: "Fixture Artist", duration: duration)
    }
    load("Discarded")
    load("A & B / 漢字")
    await waitUntil { !service.lines.isEmpty }
    check(LyricsLifecycleProtocol.snapshot() == ["A & B / 漢字"], "debounce cancels obsolete title and URL encoding preserves all query characters")
    check(service.lines.first?.text.hasPrefix("Long catalog") == true, "unknown duration preserves provider order instead of selecting the shortest recording")
    check(service.lines.last?.endTime == 200 && service.currentLyricLine(at: 200) == nil, "catalog duration ends the last lyric when playback duration is unavailable")
    load("Duration known", duration: 100)
    await waitUntil { service.lines.first?.text.contains("Duration known") == true }
    check(service.lines.first?.text.hasPrefix("Short catalog") == true, "known duration still selects the matching recording")
    load("Delayed")
    await waitUntil { LyricsLifecycleProtocol.snapshot().contains("Delayed") }
    load("Replacement")
    await waitUntil { service.lines.first?.text.contains("Replacement") == true }
    try? await Task.sleep(nanoseconds: 800_000_000)
    check(service.lines.first?.text.contains("Replacement") == true, "canceled old network response cannot replace a newer track")
    let beforeCache = LyricsLifecycleProtocol.snapshot().count
    load("")
    load("Replacement")
    check(!service.lines.isEmpty && LyricsLifecycleProtocol.snapshot().count == beforeCache, "same-source cached result restores without a second request")
    load("Replacement", source: "com.spotify.client")
    await waitUntil { LyricsLifecycleProtocol.snapshot().count > beforeCache && !service.lines.isEmpty }
    check(LyricsLifecycleProtocol.snapshot().count == beforeCache + 1, "switching source does not reuse another source's cache key")
    load("Cancel before debounce")
    load("")
    try? await Task.sleep(nanoseconds: 450_000_000)
    check(service.lines.isEmpty && !LyricsLifecycleProtocol.snapshot().contains("Cancel before debounce"), "clearing a disabled source cancels pending lyrics work")
    let retrying = LyricsService(session: session, retryDelays: [0.2, 0.03])
    func retryLoad(_ title: String) {
        retrying.load(sourceBundleIdentifier: "com.apple.Music", title: title, artist: "Fixture Artist", duration: 0)
    }
    retryLoad("Transient")
    await waitUntil { !retrying.lines.isEmpty }
    check(retrying.lines.first?.text.contains("Transient") == true
          && LyricsLifecycleProtocol.snapshot().filter { $0 == "Transient" }.count == 2,
          "a transient network failure recovers lyrics for the same unchanged song")
    retryLoad("Always offline")
    await waitUntil { LyricsLifecycleProtocol.snapshot().filter { $0 == "Always offline" }.count >= 3 }
    for _ in 0..<5 { retryLoad("Always offline") }
    try? await Task.sleep(nanoseconds: 450_000_000)
    check(LyricsLifecycleProtocol.snapshot().filter { $0 == "Always offline" }.count == 3,
          "offline retries stop at the finite budget and unchanged metadata does not duplicate requests")
    retryLoad("Cancel retry")
    await waitUntil { LyricsLifecycleProtocol.snapshot().contains("Cancel retry") && retrying.status.contains("歌词不可用") }
    retryLoad("Retry replacement")
    await waitUntil { retrying.lines.first?.text.contains("Retry replacement") == true }
    try? await Task.sleep(nanoseconds: 450_000_000)
    check(LyricsLifecycleProtocol.snapshot().filter { $0 == "Cancel retry" }.count == 1,
          "changing track cancels its pending retry instead of bringing back stale lyrics")
    retryLoad("Throttled")
    await waitUntil { LyricsLifecycleProtocol.snapshot().contains("Throttled") }
    try? await Task.sleep(nanoseconds: 500_000_000)
    check(LyricsLifecycleProtocol.snapshot().filter { $0 == "Throttled" }.count == 1,
          "automatic retries do not bypass the server Retry-After deadline")
    await waitUntil { retrying.lines.first?.text.contains("Throttled") == true }
    check(retrying.lines.first?.text.contains("Throttled") == true
          && LyricsLifecycleProtocol.snapshot().filter { $0 == "Throttled" }.count == 2,
          "a throttled song recovers automatically after the provider permits retrying")
    retryLoad("Global throttle")
    await waitUntil { retrying.status == "歌词服务繁忙，请稍后重试。" }
    retryLoad("During throttle")
    try? await Task.sleep(nanoseconds: 500_000_000)
    check(!LyricsLifecycleProtocol.snapshot().contains("During throttle"),
          "switching songs cannot bypass the provider-wide Retry-After deadline")
    await waitUntil { retrying.lines.first?.text.contains("During throttle") == true }
    check(retrying.lines.first?.text.contains("During throttle") == true,
          "the current song resumes after a throttle originally returned for another song")

    let manual = LyricsService(session: session, retryDelays: [])
    func manualLoad(_ title: String) {
        manual.load(sourceBundleIdentifier: "com.apple.Music", title: title, artist: "Fixture Artist", duration: 0)
    }
    manualLoad("Manual failure")
    await waitUntil { manual.availability == .temporaryFailure }
    let failedKey = manual.trackKey
    check(!manual.retryCurrentTrack(expectedTrackKey: "stale-song"), "a stale retry action cannot retry the current song")
    check(manual.retryCurrentTrack(expectedTrackKey: failedKey), "explicit retry can recover after the automatic budget is exhausted")
    check(!manual.retryCurrentTrack(expectedTrackKey: failedKey), "repeated clicks cannot create concurrent requests")
    await waitUntil { manual.availability == .ready }
    check(manual.lines.first?.text.contains("Manual failure") == true
        && LyricsLifecycleProtocol.snapshot().filter { $0 == "Manual failure" }.count == 2,
          "manual retry restores the same track with one additional request")
    manualLoad("Manual empty")
    await waitUntil { manual.availability == .unavailable }
    check(manual.retryCurrentTrack(expectedTrackKey: manual.trackKey), "manual retry can invalidate a cached missing-lyrics result")
    await waitUntil { manual.availability == .ready }
    check(manual.lines.first?.text.contains("Manual empty") == true, "missing-lyrics cache does not trap a later successful response")
    manualLoad("Manual throttle")
    await waitUntil { manual.availability == .coolingDown }
    let throttledKey = manual.trackKey
    check(!manual.retryCurrentTrack(expectedTrackKey: throttledKey), "manual retry respects the service's Retry-After deadline")
    check(LyricsLifecycleProtocol.snapshot().filter { $0 == "Manual throttle" }.count == 1,
          "a click during cooldown issues no network request")
    manualLoad("Manual replacement")
    await waitUntil { manual.availability == .coolingDown }
    check(!manual.retryCurrentTrack(expectedTrackKey: throttledKey), "a retry captured before a track change is rejected")
    check(!LyricsLifecycleProtocol.snapshot().contains("Manual replacement"), "changing tracks does not bypass the shared service cooldown")
    try? await Task.sleep(nanoseconds: 1_050_000_000)
    check(manual.retryCurrentTrack(expectedTrackKey: manual.trackKey), "current-track retry becomes available after cooldown")
    await waitUntil { manual.availability == .ready }
    check(manual.lines.first?.text.contains("Manual replacement") == true, "recovery cannot revive the old throttled song")
    check(manual.displayMessage(hasReliableTiming: false).contains("播放进度"), "missing playback timing has a separate user-facing explanation")
    manual.load(title: "", artist: "", duration: 0)
    check(manual.availability == .waiting && !manual.retryCurrentTrack(expectedTrackKey: throttledKey),
          "disabling lyrics clears the active retry identity")
    session.invalidateAndCancel()
    return failures
}

#if LYRICS_LIFECYCLE_STANDALONE
@MainActor func tr(_ key: String) -> String { key }
@main struct LyricsLifecycleTestsRunner {
    @MainActor static func main() async {
        let failures = runLyricDisplayTests() + runLyricsTests() + (await runLyricsLifecycleTests())
        if failures.isEmpty { print("PASS: lyric display, LRC parsing, language rules, bounded retries, manual recovery and track cancellation") }
        else { failures.forEach { print("FAIL: " + $0) }; exit(1) }
    }
}
#endif
