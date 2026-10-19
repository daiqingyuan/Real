import Foundation

/// Synthetic requests only. This protocol accepts every request so an unknown
/// route fails locally instead of escaping to a real lyric provider.
private final class NeteaseEnrichmentFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var scenario = "matching"
    private static var captured: [(route: String, title: String)] = []
    private static var stoppedQRC = 0
    private let stateLock = NSLock()
    private var completed = false
    private var pending: DispatchWorkItem?
    private var route = ""

    static func reset(_ value: String) {
        lock.lock(); scenario = value; captured = []; stoppedQRC = 0; lock.unlock()
    }
    static func setScenario(_ value: String) {
        lock.lock(); scenario = value; lock.unlock()
    }
    static func records() -> [(route: String, title: String)] {
        lock.lock(); defer { lock.unlock() }; return captured
    }
    static func cancelledQRCCount() -> Int {
        lock.lock(); defer { lock.unlock() }; return stoppedQRC
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {
        pending?.cancel()
        stateLock.lock(); let wasCompleted = completed; stateLock.unlock()
        if route == "qq-qrc", !wasCompleted {
            Self.lock.lock(); Self.stoppedQRC += 1; Self.lock.unlock()
        }
    }

    override func startLoading() {
        let host = request.url?.host ?? ""
        let path = request.url?.path ?? ""
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let payload = query.first { $0.name == "data" }?.value ?? ""
        let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let replacement = payload.contains("Replacement")
            || query.contains { $0.name == "s" && $0.value?.contains("Replacement") == true }
            || query.contains { $0.name == "id" && $0.value == "2" }
            || body.contains("musicid=322")
        let title = replacement ? "Replacement Song" : "Fixture Song"
        if host == "music.163.com", path == "/api/search/get" { route = "netease-search" }
        else if host == "music.163.com", path == "/api/song/lyric" { route = "netease-lyric" }
        else if host == "u.y.qq.com", payload.contains("DoSearchForQQMusicDesktop") { route = "qq-search" }
        else if host == "c.y.qq.com", path.contains("client_search") { route = "qq-search" }
        else if host == "c.y.qq.com", path.contains("lyric_download") { route = "qq-qrc" }
        else if ["u.y.qq.com", "c.y.qq.com"].contains(host) { route = "qq-lrc" }
        else if host == "lrclib.net" { route = "lrclib" }
        else { route = "unexpected" }
        Self.lock.lock()
        let scenario = Self.scenario
        Self.captured.append((route, title))
        Self.lock.unlock()

        let work = DispatchWorkItem { [weak self] in
            guard let self, pending?.isCancelled != true else { return }
            guard route != "unexpected" else {
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
            }
            var status = 200
            var headers = ["Content-Type": "application/json"]
            var node: [String: Any] = [:]
            var raw: String?
            let texts = replacement
                ? ["Replacement first", "Replacement second", "Replacement third", "Replacement fourth"]
                : ["Synthetic first", "Synthetic second", "Synthetic third", "Synthetic fourth"]
            let starts = [1, 6, 11, 16]
            let lrc = zip(starts, texts).map { "[00:" + String(format: "%02d", $0.0) + "]" + $0.1 }.joined(separator: "\n")
            switch route {
            case "netease-search":
                node = ["code": 200, "result": ["songs": [["id": replacement ? 2 : 1, "name": title,
                    "artists": [["name": "Fixture Artist"]], "duration": 20_000, "album": ["name": "Fixture Album"]]]]]
            case "netease-lyric":
                node = ["code": 200, "lrc": ["lyric": lrc],
                        "tlyric": ["lyric": "[00:01]Original translation"]]
                if scenario == "native-yrc" {
                    node["yrc"] = ["lyric": zip(starts, texts).map { time, text in
                        let parts = text.split(separator: " ", maxSplits: 1)
                        return "[\(time * 1000),1500](\(time * 1000),500,0)\(parts[0]) (\(time * 1000 + 500),1000,0)\(parts[1])"
                    }.joined(separator: "\n")]
                }
                if scenario == "instrumental" { node = ["code": 200, "nolyric": true] }
            case "qq-search":
                let song: [String: Any] = ["mid": replacement ? "replacement-fixture" : "original-fixture",
                    "id": replacement ? 322 : 321,
                    "title": scenario == "version-mismatch" ? title + " (Live)" : title,
                    "singer": [["name": "Fixture Artist"]], "interval": 20]
                if path.contains("client_search") { node = ["code": 0, "data": ["song": ["list": [song]]]] }
                else { node = ["code": 0, "req_0": ["code": 0, "data": ["body": ["song": ["list": [song]]]]]] }
                if scenario == "throttled" { status = 429; headers["Retry-After"] = "60" }
            case "qq-qrc":
                let qrc = zip(starts, texts).map { time, text -> String in
                    // A genuine constant cross-provider offset is permitted;
                    // a different recording drifts only in its latter half.
                    let start = (time + (scenario == "timing-mismatch" && time >= 11 ? 2 : 0)) * 1000
                    let value = scenario == "text-mismatch" ? "Different recording" : text
                    let parts = value.split(separator: " ", maxSplits: 1)
                    return "[\(start),1500]\(parts[0]) (\(start),500)\(parts[1])(\(start + 500),1000)"
                }.joined(separator: "\n")
                raw = "<cmd><content><![CDATA[\(qrc)]]></content></cmd>"
                if scenario == "probe-failure" { status = 500 }
            case "qq-lrc":
                node = ["code": 0, "lyric": ["code": 0, "data": ["lyric": Data(lrc.utf8).base64EncodedString()]]]
                if scenario == "probe-failure" { status = 500 }
            case "lrclib": raw = "[]"
            default: break
            }
            let bytes = raw.map { Data($0.utf8) } ?? (try! JSONSerialization.data(withJSONObject: node))
            stateLock.lock(); completed = true; stateLock.unlock()
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: bytes)
            client?.urlProtocolDidFinishLoading(self)
        }
        pending = work
        // Baseline LRC must be observable before the optional word probe ends.
        let delay: Double = route == "qq-qrc" ? (["cancel-track", "disable"].contains(scenario) ? 0.8 : 0.25) : 0.005
        DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work)
    }
}

/// Integration coverage for sentence lyrics enriched with separately verified
/// real word annotations; never estimates word timing from line duration.
@MainActor
func runNeteaseEnrichmentIntegrationTests() async -> [String] {
    var failures: [String] = []
    func check(_ value: Bool, _ message: String) { if !value { failures.append("NetEase enrichment: " + message) } }
    func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<250 { if predicate() { return }; try? await Task.sleep(nanoseconds: 10_000_000) }
    }
    func load(_ service: LyricsService, title: String = "Fixture Song", source: String = "com.netease.163music") {
        service.load(sourceBundleIdentifier: source, title: title, artist: "Fixture Artist", duration: 20, album: "Fixture Album")
    }
    func wordCount(_ service: LyricsService) -> Int { service.lines.reduce(0) { $0 + $1.words.count } }
    func routes() -> [String] { NeteaseEnrichmentFixtureProtocol.records().map(\.route) }
    func withFixture(_ scenario: String, now: @escaping () -> Date = Date.init,
                     retryDelays: [TimeInterval] = [], body: (LyricsService) async -> Void) async {
        NeteaseEnrichmentFixtureProtocol.reset(scenario)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NeteaseEnrichmentFixtureProtocol.self]
        let session = URLSession(configuration: config)
        let service = LyricsService(session: session, qqProvider: QQMusicLyricsProvider(session: session),
            neteaseProvider: NeteaseLyricsProvider(session: session), retryDelays: retryDelays, now: now)
        await body(service)
        check(!routes().contains("unexpected"), "\(scenario) must not contact an unhandled provider route")
        service.load(title: "", artist: "", duration: 0)
        session.invalidateAndCancel()
        try? await Task.sleep(nanoseconds: 30_000_000)
    }

    await withFixture("matching") { service in
        load(service)
        await waitUntil { service.availability == .ready }
        check(service.lines.count == 4 && wordCount(service) == 0,
              "NetEase sentence lyrics become ready before the delayed optional word probe completes")
        check(service.lines.first?.translation == "Original translation", "baseline keeps NetEase translation")
        await waitUntil { wordCount(service) > 0 }
        check(wordCount(service) == 8 && service.lines.allSatisfy { $0.timing == .wordAnnotated },
              "matching text, recording metadata and actual word starts enrich all four lines")
        check(service.lines.map(\.time) == [1, 6, 11, 16] && service.lines.first?.translation == "Original translation",
              "enrichment preserves NetEase line positions and translations")
        check(service.availability == .ready && !routes().contains("lrclib"),
              "valid NetEase lyrics stay ready and never fall through to LRCLIB")
        let count = routes().count
        service.load(title: "", artist: "", duration: 0)
        load(service)
        check(wordCount(service) == 8 && routes().count == count,
              "revisiting the same track restores the enriched result from its NetEase cache")
    }

    await withFixture("native-yrc") { service in
        load(service)
        await waitUntil { service.availability == .ready }
        try? await Task.sleep(nanoseconds: 100_000_000)
        check(wordCount(service) == 8 && !routes().contains(where: { $0.hasPrefix("qq-") }),
              "native NetEase YRC remains preferred and performs no optional QQ lookup")
        check(!routes().contains("lrclib"), "native word lyrics perform no fallback lookup")
    }

    for scenario in ["probe-failure", "text-mismatch", "timing-mismatch", "version-mismatch"] {
        await withFixture(scenario) { service in
            load(service)
            await waitUntil { routes().contains("qq-search") }
            try? await Task.sleep(nanoseconds: 400_000_000)
            check(service.availability == .ready && service.lines.count == 4 && wordCount(service) == 0,
                  "\(scenario) leaves original sentence lyrics available rather than fabricating word timing")
            check(service.lines.first?.text == "Synthetic first" && service.lines.first?.translation == "Original translation",
                  "\(scenario) cannot replace the original NetEase text or translation")
            check(!routes().contains("lrclib"), "\(scenario) does not run LRCLIB after valid NetEase lyrics")
        }
    }

    await withFixture("cancel-track") { service in
        load(service)
        await waitUntil { routes().contains("qq-qrc") }
        load(service, title: "Replacement Song")
        await waitUntil { service.lines.first?.text == "Replacement first" }
        try? await Task.sleep(nanoseconds: 900_000_000)
        check(service.lines.first?.text == "Replacement first"
            && service.trackKey == LyricDisplayPolicy.trackKey(sourceBundleIdentifier: "com.netease.163music",
                title: "Replacement Song", artist: "Fixture Artist"), "a late optional probe cannot revive the previous song")
        check(NeteaseEnrichmentFixtureProtocol.cancelledQRCCount() > 0,
              "track changes cancel the outstanding optional QRC request")
        check(!routes().contains("lrclib"), "track replacement keeps its valid NetEase lyrics")
        let nativeCount = routes().filter { $0.hasPrefix("netease-") }.count
        let searchCount = routes().filter { $0 == "qq-search" }.count
        NeteaseEnrichmentFixtureProtocol.setScenario("matching")
        load(service)
        check(service.availability == .ready && service.lines.first?.text == "Synthetic first"
            && wordCount(service) == 0, "revisiting a canceled probe immediately restores its cached native lyrics")
        // Repeated metadata snapshots must share one resumed optional probe.
        for _ in 0..<5 { load(service) }
        await waitUntil { wordCount(service) > 0 }
        check(wordCount(service) == 8 && routes().filter { $0 == "qq-search" }.count == searchCount + 1,
              "revisiting canceled enrichment resumes exactly one word lookup")
        check(routes().filter { $0.hasPrefix("netease-") }.count == nativeCount,
              "resuming a canceled word lookup does not refetch cached NetEase lyrics")
    }

    await withFixture("disable") { service in
        load(service)
        await waitUntil { routes().contains("qq-qrc") }
        service.load(title: "", artist: "", duration: 0)
        try? await Task.sleep(nanoseconds: 900_000_000)
        check(service.lines.isEmpty && service.availability == .waiting,
              "disabling lyrics cancels the optional probe and cannot repopulate the display")
        check(NeteaseEnrichmentFixtureProtocol.cancelledQRCCount() > 0,
              "disabling lyrics cancels its outstanding network request")
    }

    await withFixture("throttled") { service in
        load(service)
        await waitUntil { routes().contains("qq-search") }
        try? await Task.sleep(nanoseconds: 80_000_000)
        check(service.availability == .ready && service.lines.count == 4 && wordCount(service) == 0,
              "optional QQ rate limiting keeps usable NetEase lyrics ready")
        let firstCount = routes().filter { $0.hasPrefix("qq-") }.count
        load(service, title: "Replacement Song")
        await waitUntil { service.lines.first?.text == "Replacement first" }
        try? await Task.sleep(nanoseconds: 80_000_000)
        check(routes().filter { $0.hasPrefix("qq-") }.count == firstCount,
              "a different NetEase song cannot bypass the shared QQ Retry-After deadline")
        check(service.availability == .ready && !routes().contains("lrclib"),
              "QQ cooldown does not downgrade the replacement's usable NetEase lyrics")
        load(service, title: "Another Song", source: "com.tencent.QQMusicMac")
        try? await Task.sleep(nanoseconds: 450_000_000)
        check(routes().filter { $0.hasPrefix("qq-") }.count == firstCount,
              "changing to the QQ player also respects the optional probe's provider-wide cooldown")
    }

    var retryNow = Date()
    await withFixture("probe-failure", now: { retryNow }) { service in
        load(service)
        await waitUntil { routes().contains("qq-qrc") }
        try? await Task.sleep(nanoseconds: 350_000_000)
        let nativeCount = routes().filter { $0.hasPrefix("netease-") }.count
        let searchCount = routes().filter { $0 == "qq-search" }.count
        check(service.availability == .ready && wordCount(service) == 0,
              "a transient word lookup failure leaves sentence lyrics ready")
        NeteaseEnrichmentFixtureProtocol.setScenario("matching")
        retryNow = retryNow.addingTimeInterval(59)
        for _ in 0..<5 { load(service) }
        try? await Task.sleep(nanoseconds: 80_000_000)
        check(routes().filter { $0 == "qq-search" }.count == searchCount && service.availability == .ready,
              "cached sentence lyrics do not retry the optional probe before its sixty-second delay")
        retryNow = retryNow.addingTimeInterval(2)
        load(service)
        check(service.availability == .ready && service.lines.count == 4,
              "a delayed word retry never clears the usable native lyric display")
        await waitUntil { wordCount(service) > 0 }
        check(wordCount(service) == 8 && routes().filter { $0 == "qq-search" }.count == searchCount + 1,
              "unchanged metadata automatically recovers word timing after the transient retry deadline")
        check(routes().filter { $0.hasPrefix("netease-") }.count == nativeCount && !routes().contains("lrclib"),
              "word-only recovery reuses native lyrics without manual retry or another provider fallback")
        let enrichedRequestCount = routes().count
        retryNow = retryNow.addingTimeInterval(3_600)
        load(service)
        service.load(title: "", artist: "", duration: 0)
        load(service)
        try? await Task.sleep(nanoseconds: 80_000_000)
        check(wordCount(service) == 8 && routes().count == enrichedRequestCount,
              "successful enrichment removes the optional retry deadline even after a later cache revisit")
    }

    var cooldownNow = Date()
    await withFixture("throttled", now: { cooldownNow }) { service in
        load(service)
        await waitUntil { routes().contains("qq-search") }
        try? await Task.sleep(nanoseconds: 80_000_000)
        let nativeCount = routes().filter { $0.hasPrefix("netease-") }.count
        let searchCount = routes().filter { $0 == "qq-search" }.count
        NeteaseEnrichmentFixtureProtocol.setScenario("matching")
        cooldownNow = cooldownNow.addingTimeInterval(59)
        load(service)
        try? await Task.sleep(nanoseconds: 80_000_000)
        check(routes().filter { $0 == "qq-search" }.count == searchCount && service.availability == .ready,
              "cached word enrichment honors the provider's Retry-After date")
        cooldownNow = cooldownNow.addingTimeInterval(2)
        load(service)
        await waitUntil { wordCount(service) > 0 }
        check(wordCount(service) == 8 && routes().filter { $0 == "qq-search" }.count == searchCount + 1,
              "cached word enrichment resumes when its provider cooldown actually expires")
        check(routes().filter { $0.hasPrefix("netease-") }.count == nativeCount,
              "cooldown recovery does not refetch the still-valid native lyrics")
    }

    await withFixture("instrumental") { service in
        load(service)
        await waitUntil { service.availability == .instrumental }
        try? await Task.sleep(nanoseconds: 80_000_000)
        check(service.availability == .instrumental && service.lines.isEmpty,
              "instrumental tracks retain the explicit NetEase instrumental result")
        check(!routes().contains(where: { $0.hasPrefix("qq-") || $0 == "lrclib" }),
              "instrumental tracks do not look up another provider's lyrics")
    }

    check(!QQTrackDescriptor(sourceBundleIdentifier: "com.netease.163music", title: "Fixture Song",
                            artist: "Fixture Artist", duration: 20).acceptsQQ,
          "optional enrichment does not broaden the ordinary source eligibility rule")
    return failures
}
