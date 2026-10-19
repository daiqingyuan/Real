import Combine
import Foundation

/// Every request is intercepted, including unexpected hosts/routes. The
/// synthetic catalogs never contact a player, real account, or lyric service.
private final class LyricsResilienceProtocol: URLProtocol, @unchecked Sendable {
    enum Mode {
        case transient, fallbackReady, missing, blankFallback, throttle, alwaysFail, cancelRetry
        case primarySooner, backupSooner, negativeCacheCycle
    }
    struct Hit {
        let provider: String
        let route: String
        let title: String
        let date: Date
    }
    private struct Plan {
        let status: Int
        let headers: [String: String]
        let data: Data
        var error: URLError? = nil
    }
    private static let lock = NSLock()
    private static var mode = Mode.transient
    private static var hits: [Hit] = []
    private static var titles: [String] = []
    private static var primaryReady = false
    private static var hasThrottled = false
    private var pending: DispatchWorkItem?

    static func reset(_ value: Mode, titles valueTitles: [String]) {
        lock.lock(); defer { lock.unlock() }
        mode = value; hits = []; titles = valueTitles; primaryReady = false; hasThrottled = false
    }
    static func snapshot() -> [Hit] { lock.lock(); defer { lock.unlock() }; return hits }
    static func allowPrimary() { lock.lock(); primaryReady = true; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { pending?.cancel() }

    override func startLoading() {
        let plan = Self.plan(for: request)
        let work = DispatchWorkItem { [weak self] in
            guard let self, pending?.isCancelled != true else { return }
            guard let plan, let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: plan.status,
                    httpVersion: "HTTP/1.1", headerFields: plan.headers) else {
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
                return
            }
            if let error = plan.error {
                client?.urlProtocol(self, didFailWithError: error)
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: plan.data)
            client?.urlProtocolDidFinishLoading(self)
        }
        pending = work
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.003, execute: work)
    }

    private static func plan(for request: URLRequest) -> Plan? {
        lock.lock(); defer { lock.unlock() }
        guard let url = request.url else { return nil }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ key: String) -> String? { query.first { $0.name == key }?.value }
        func title(in search: String?) -> String {
            let text = search ?? ""
            return titles.sorted { $0.count > $1.count }.first { text == $0 || text.hasSuffix(" " + $0) } ?? ""
        }
        func id(for title: String) -> Int { 1_000 + (titles.firstIndex(of: title) ?? 0) }
        func title(for id: Int?) -> String {
            guard let id, titles.indices.contains(id - 1_000) else { return "" }
            return titles[id - 1_000]
        }
        func json(_ object: Any, status: Int = 200, headers: [String: String] = [:]) -> Plan {
            Plan(status: status, headers: ["Content-Type": "application/json"].merging(headers) { _, new in new },
                 data: try! JSONSerialization.data(withJSONObject: object))
        }
        let host = url.host ?? ""
        let path = url.path
        if host == "lrclib.net", path == "/api/search" {
            let song = value("track_name") ?? ""
            hits.append(Hit(provider: "lrclib", route: "search", title: song, date: Date()))
            let attempt = hits.filter { $0.provider == "lrclib" && $0.title == song }.count
            if mode == .transient || mode == .cancelRetry { primaryReady = true }
            if mode == .primarySooner && attempt == 1 {
                return json([], status: 429, headers: ["Retry-After": "3"])
            }
            if mode == .backupSooner && attempt == 1 { return json([], status: 500) }
            if mode == .alwaysFail { return json([], status: 500) }
            if mode == .negativeCacheCycle && [1, 2, 4].contains(attempt) {
                return Plan(status: 200, headers: [:], data: Data(), error: URLError(.networkConnectionLost))
            }
            guard mode == .fallbackReady || mode == .blankFallback || mode == .backupSooner
                    || mode == .negativeCacheCycle && attempt >= 5 else { return json([]) }
            let line = mode == .blankFallback ? "[00:01]   \n[00:02]\n" : "[00:01]Fallback " + song
            return json([["trackName": song, "artistName": "Fixture Artist", "duration": 10,
                          "instrumental": false, "syncedLyrics": line, "plainLyrics": NSNull()]])
        }
        var provider = ""
        var route = ""
        var song = ""
        var modern = false
        if host == "music.163.com" {
            provider = "netease"
            if path == "/api/search/get" { route = "search"; song = title(in: value("s")) }
            if path == "/api/song/lyric" { route = "lyrics"; song = title(for: value("id").flatMap(Int.init)) }
        } else if host == "u.y.qq.com" || host == "c.y.qq.com" {
            provider = "qq"
            let payload = value("data").flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            if let requestNode = payload?["req_0"] as? [String: Any],
               let params = requestNode["param"] as? [String: Any] {
                route = "search"; modern = true; song = title(in: params["query"] as? String)
            } else if path.contains("client_search") { route = "search"; song = title(in: value("w")) }
            else if path.contains("lyric_download") {
                route = "qrc"
                // Foundation can deliver URLProtocol POST bodies as a stream,
                // even when the original caller set httpBody directly.
                var data = request.httpBody
                if data == nil, let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var bytes = [UInt8](repeating: 0, count: 4_096)
                    let count = stream.read(&bytes, maxLength: bytes.count)
                    if count > 0 { data = Data(bytes.prefix(count)) }
                }
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let form = URLComponents(string: "https://fixture.invalid/?" + body)?.queryItems ?? []
                song = title(for: form.first { $0.name == "musicid" }?.value.flatMap(Int.init))
            } else if let lyric = payload?["lyric"] as? [String: Any], let params = lyric["param"] as? [String: Any] {
                route = "lyrics"; modern = true
                song = title(for: (params["songID"] as? NSNumber)?.intValue)
            } else if path.contains("fcg_query_lyric_new") {
                route = "lyrics"
                song = title(for: (value("songmid")?.replacingOccurrences(of: "fixture-", with: "")).flatMap(Int.init))
            }
        }
        guard !provider.isEmpty, !route.isEmpty, !song.isEmpty else {
            hits.append(Hit(provider: "unexpected", route: path, title: song, date: Date()))
            return nil
        }
        hits.append(Hit(provider: provider, route: route, title: song, date: Date()))
        if [.throttle, .primarySooner, .backupSooner].contains(mode), !hasThrottled {
            hasThrottled = true
            return json(["error": "synthetic throttle"], status: 429,
                        headers: ["Retry-After": mode == .backupSooner ? "3" : "1"])
        }
        let healthy = primaryReady || [.throttle, .primarySooner, .backupSooner].contains(mode) && hasThrottled
        if !healthy && mode != .missing && mode != .blankFallback {
            if provider == "netease" { return json(["code": 500]) }
            return modern ? json(["code": 0, "req_0": ["code": 2001]]) : json(["code": 2001])
        }
        if route == "search" {
            if provider == "netease" {
                let songs: [[String: Any]] = healthy ? [["id": id(for: song), "name": song,
                    "artists": [["name": "Fixture Artist"]], "duration": 10_000, "album": ["name": "Fixture Album"]]] : []
                return json(["code": 200, "result": ["songs": songs]])
            }
            let songs: [[String: Any]] = healthy ? [["id": id(for: song), "mid": "fixture-\(id(for: song))", "title": song,
                "singer": [["name": "Fixture Artist"]], "interval": 10]] : []
            return modern ? json(["code": 0, "req_0": ["code": 0, "data": ["body": ["song": ["list": songs]]]]])
                : json(["code": 0, "data": ["song": ["list": songs]]])
        }
        if provider == "netease" {
            return json(["code": 200, "lrc": ["lyric": "[00:01]Primary NetEase " + song]])
        }
        if route == "qrc" {
            return Plan(status: 200, headers: ["Content-Type": "text/xml"],
                data: Data(("<cmd><content><![CDATA[[1000,2000]Primary QQ " + song + "(1000,2000)]]></content></cmd>").utf8))
        }
        let encoded = Data(("[00:01]Primary QQ " + song).utf8).base64EncodedString()
        return modern ? json(["code": 0, "lyric": ["code": 0, "data": ["lyric": encoded]]])
            : json(["code": 0, "lyric": encoded])
    }
}

@MainActor
func runLyricsResilienceTests() async -> [String] {
    var failures: [String] = []
    func check(_ condition: Bool, _ message: String) {
        if !condition { failures.append("Lyrics resilience: " + message) }
    }
    func waitUntil(timeout: TimeInterval = 3, _ predicate: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return predicate()
    }
    func pause(_ seconds: TimeInterval) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    func make(_ mode: LyricsResilienceProtocol.Mode, titles: [String], delays: [TimeInterval] = [0.01, 0.01],
              now: @escaping () -> Date = Date.init) -> (LyricsService, URLSession) {
        LyricsResilienceProtocol.reset(mode, titles: titles)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LyricsResilienceProtocol.self]
        config.httpShouldSetCookies = false
        config.urlCache = nil
        let session = URLSession(configuration: config)
        let service = LyricsService(session: session, qqProvider: QQMusicLyricsProvider(session: session),
            neteaseProvider: NeteaseLyricsProvider(session: session), retryDelays: delays,
            missingCacheLifetime: 2, now: now)
        return (service, session)
    }
    func load(_ service: LyricsService, _ title: String, source: String) {
        service.load(sourceBundleIdentifier: source, title: title, artist: "Fixture Artist", duration: 10)
    }
    func stop(_ service: LyricsService, _ session: URLSession) {
        service.load(title: "", artist: "", duration: 0)
        session.invalidateAndCancel()
    }
    func hits(_ provider: String? = nil, title: String? = nil, route: String? = nil) -> [LyricsResilienceProtocol.Hit] {
        LyricsResilienceProtocol.snapshot().filter { hit in
            (provider == nil || provider == hit.provider) && (title == nil || title == hit.title) && (route == nil || route == hit.route)
        }
    }
    let sources = [("qq", "com.tencent.QQMusicMac"), ("netease", "com.netease.163music")]

    // A backup catalog miss cannot turn a primary outage into a cached absence.
    for (provider, source) in sources {
        let title = provider + " temporary recovery"
        let (service, session) = make(.transient, titles: [title])
        defer { stop(service, session) }
        var states: [LyricsAvailability] = []
        let observation = service.$availability.sink { states.append($0) }
        defer { observation.cancel() }
        load(service, title, source: source)
        let recovered = await waitUntil { service.availability == .ready }
        check(recovered && service.lines.first?.text.contains("Primary") == true, "\(provider) primary service error automatically recovers the same unchanged song")
        check(states.contains(.temporaryFailure) && !states.contains(.unavailable), "\(provider) service failure plus empty fallback stays temporary and never becomes a true no-lyrics result")
        check(hits("lrclib", title: title).count == 1, "\(provider) recovery retries primary instead of reusing a negative fallback cache")
        check(hits(provider, title: title, route: "search").count >= 2, "\(provider) recovery actually re-queries the primary provider")
        check(hits("unexpected").isEmpty, "\(provider) recovery uses only intercepted fixture routes: \(hits("unexpected").map(\.route))")
    }

    for (provider, source) in sources {
        let title = provider + " backup success"
        let (service, session) = make(.fallbackReady, titles: [title])
        defer { stop(service, session) }
        load(service, title, source: source)
        let ready = await waitUntil { service.availability == .ready }
        check(ready && service.lines.first?.text == "Fallback " + title, "\(provider) primary failure can use a valid synchronized backup immediately")
        let count = hits().count
        await pause(0.45)
        check(hits().count == count, "\(provider) valid fallback success does not launch unnecessary automatic retries")
    }

    for (provider, source) in sources {
        let title = provider + " catalog publication"
        var clockOffset: TimeInterval = 0
        let (service, session) = make(.missing, titles: [title], delays: [], now: { Date().addingTimeInterval(clockOffset) })
        defer { stop(service, session) }
        load(service, title, source: source)
        let missing = await waitUntil { service.availability == .unavailable }
        check(missing && service.lines.isEmpty, "\(provider) confirmed empty primary and backup catalogs are a legitimate missing result")
        let before = hits().count
        LyricsResilienceProtocol.allowPrimary()
        for _ in 0..<3 { load(service, title, source: source) }
        service.load(title: "", artist: "", duration: 0)
        load(service, title, source: source)
        await pause(0.42)
        check(service.availability == .unavailable && hits().count == before, "\(provider) a recent confirmed miss is reused without duplicate requests")
        clockOffset += 3
        load(service, title, source: source)
        let refreshed = await waitUntil { service.availability == .ready }
        check(refreshed && service.lines.first?.text.contains("Primary") == true && hits().count > before,
              "\(provider) expiring the negative-cache TTL reloads the same active key and can discover newly available lyrics")
    }

    do {
        let title = "blank timing tags"
        let (service, session) = make(.blankFallback, titles: [title], delays: [])
        defer { stop(service, session) }
        load(service, title, source: "com.apple.Music")
        _ = await waitUntil { service.availability == .unavailable || service.availability == .ready }
        check(service.availability == .unavailable && service.lines.isEmpty, "timing tags containing only whitespace are never treated as ready lyrics")
        check(hits("lrclib", title: title).count == 1 && hits("unexpected").isEmpty, "blank-timestamp fixture remains fully offline")
    }

    // Cooldown belongs to a provider, not to the song that originally hit 429.
    for (provider, source) in sources {
        let old = provider + " throttled old", current = provider + " throttled current"
        let (service, session) = make(.throttle, titles: [old, current])
        defer { stop(service, session) }
        load(service, old, source: source)
        let cooling = await waitUntil { service.availability == .coolingDown }
        check(cooling && hits(provider, route: "search").count == 1, "\(provider) HTTP 429 creates a provider cooldown immediately")
        let oldKey = service.trackKey
        check(hits("lrclib", title: old).count == 1, "\(provider) cooldown still permits the separate generic catalog")
        // A manual retry may legally try an available backup while primary is
        // cooling. Assert network timing rather than requiring a false return.
        if service.retryCurrentTrack(expectedTrackKey: oldKey) {
            _ = await waitUntil(timeout: 0.7) { service.availability != .loading }
        }
        check(hits(provider, route: "search").count == 1, "\(provider) a completed manual backup retry cannot send an early primary request")
        load(service, current, source: source)
        _ = await waitUntil { service.availability != .loading && (!hits("lrclib", title: current).isEmpty || service.availability == .ready) }
        if service.availability == .coolingDown {
            check(hits(provider, route: "search").count == 1, "\(provider) switching songs cannot bypass its existing deadline")
            _ = service.retryCurrentTrack(expectedTrackKey: service.trackKey)
        }
        check(!service.retryCurrentTrack(expectedTrackKey: oldKey), "\(provider) stale retry cannot revive the previously throttled song")
        let ready = await waitUntil { service.availability == .ready }
        let searches = hits(provider, route: "search")
        check(ready && service.lines.first?.text.contains(current) == true, "\(provider) cooldown expiry recovers only the current song")
        check(searches.count == 2 && searches.last?.title == current, "\(provider) expiry performs one primary search for the new song, never the old song")
        if searches.count == 2 {
            check(searches[1].date.timeIntervalSince(searches[0].date) >= 0.99, "\(provider) automatic recovery honors the full Retry-After interval")
        }
        await pause(0.08)
        check(service.lines.first?.text.contains(current) == true && hits(provider, title: old, route: "search").count == 1,
              "\(provider) no late old-track retry changes the restored lyrics")
    }

    // Independent endpoints must not inherit the slower endpoint's deadline.
    for (provider, source) in sources {
        let title = provider + " faster primary recovery"
        let (service, session) = make(.primarySooner, titles: [title])
        defer { stop(service, session) }
        load(service, title, source: source)
        let bothCooling = await waitUntil { service.availability == .coolingDown && hits("lrclib", title: title).count == 1 }
        check(bothCooling, "\(provider) fixture establishes separate one-second primary and three-second backup cooldowns")
        check(!service.retryCurrentTrack(expectedTrackKey: service.trackKey), "\(provider) manual retry returns false when every usable provider is cooling")
        let ready = await waitUntil(timeout: 2.5) { service.availability == .ready }
        let searches = hits(provider, title: title, route: "search")
        check(ready && service.lines.first?.text.contains("Primary") == true, "\(provider) primary recovers without waiting for the backup's longer deadline")
        check(searches.count == 2 && hits("lrclib", title: title).count == 1,
              "\(provider) faster-source recovery does not retry the still-throttled backup")
        if searches.count == 2 {
            let interval = searches[1].date.timeIntervalSince(searches[0].date)
            check(interval >= 0.99 && interval < 2.9, "\(provider) primary recovery respects its own deadline rather than the maximum of both")
        }
    }

    for (provider, source) in sources {
        let title = provider + " faster backup recovery"
        let (service, session) = make(.backupSooner, titles: [title])
        defer { stop(service, session) }
        load(service, title, source: source)
        let ready = await waitUntil(timeout: 2.5) { service.availability == .ready }
        let primary = hits(provider, title: title, route: "search")
        let fallback = hits("lrclib", title: title)
        check(ready && service.lines.first?.text == "Fallback " + title,
              "\(provider) backup recovers after its temporary failure while primary remains in a three-second cooldown")
        check(primary.count == 1 && fallback.count == 2, "\(provider) backup retry budget proceeds independently without re-querying cooling primary")
        if let start = primary.first?.date, let end = fallback.last?.date {
            check(end.timeIntervalSince(start) < 2.9, "\(provider) backup success is not delayed until primary's deadline")
        }
    }

    do {
        let title = "negative cache fresh retry budget"
        var clockOffset: TimeInterval = 0
        let (service, session) = make(.negativeCacheCycle, titles: [title], now: { Date().addingTimeInterval(clockOffset) })
        defer { stop(service, session) }
        load(service, title, source: "com.apple.Music")
        let missing = await waitUntil { service.availability == .unavailable }
        check(missing && hits("lrclib", title: title).count == 3,
              "the first lookup exhausts two transient retries before receiving a confirmed empty catalog")
        clockOffset += 3
        load(service, title, source: "com.apple.Music")
        let ready = await waitUntil { service.availability == .ready }
        check(ready && service.lines.first?.text == "Fallback " + title && hits("lrclib", title: title).count == 5,
              "a new lookup after negative-cache expiry gets a fresh retry budget and recovers after another temporary failure")
    }

    for (provider, source) in sources {
        let old = provider + " cancelled retry", current = provider + " replacement"
        let (service, session) = make(.cancelRetry, titles: [old, current], delays: [0.2, 0.2])
        defer { stop(service, session) }
        load(service, old, source: source)
        _ = await waitUntil { service.availability == .temporaryFailure }
        let before = hits(provider, title: old, route: "search").count
        load(service, current, source: source)
        let ready = await waitUntil { service.availability == .ready }
        await pause(0.25)
        check(ready && service.lines.first?.text.contains(current) == true, "\(provider) changing songs cancels a pending recovery without publishing old lyrics")
        check(hits(provider, title: old, route: "search").count == before, "\(provider) changing songs prevents the old retry request")
    }

    for (provider, source) in sources {
        let title = provider + " disabled retry"
        let (service, session) = make(.cancelRetry, titles: [title], delays: [0.2, 0.2])
        defer { stop(service, session) }
        load(service, title, source: source)
        _ = await waitUntil { service.availability == .temporaryFailure }
        let count = hits().count
        service.load(title: "", artist: "", duration: 0)
        await pause(0.65)
        check(service.availability == .waiting && service.lines.isEmpty && service.trackKey.isEmpty,
              "\(provider) disabling lyrics clears the active display identity")
        check(hits().count == count, "\(provider) disabling lyrics cancels the scheduled request instead of fetching in the background")
    }

    for (provider, source) in sources {
        let title = provider + " sustained outage"
        let (service, session) = make(.alwaysFail, titles: [title])
        defer { stop(service, session) }
        load(service, title, source: source)
        _ = await waitUntil { service.availability == .temporaryFailure && hits("lrclib", title: title).count >= 3 }
        let count = hits().count
        for _ in 0..<5 { load(service, title, source: source) }
        await pause(0.5)
        check(hits("lrclib", title: title).count == 3 && hits().count == count,
              "\(provider) persistent failure stops after the initial attempt plus two scheduled retries")
        check(service.availability == .temporaryFailure && service.lines.isEmpty,
              "\(provider) exhausted retries remain a temporary failure, not a cached absence")
        check(hits("unexpected").isEmpty, "\(provider) bounded outage test never falls through to real network traffic")
    }
    return failures
}
