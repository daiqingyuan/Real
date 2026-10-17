import Foundation

private final class NeteaseFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var scenario = "normal"
    private static var captured: [URLRequest] = []
    private var pending: DispatchWorkItem?

    static func reset(_ value: String) { lock.lock(); scenario = value; captured = []; lock.unlock() }
    static func requests() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return captured }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { pending?.cancel() }

    override func startLoading() {
        Self.lock.lock(); let scenario = Self.scenario; Self.captured.append(request); Self.lock.unlock()
        let work = DispatchWorkItem { [weak self] in
            guard let self, pending?.isCancelled != true else { return }
            let search = request.url?.path == "/api/search/get"
            var headers = ["Content-Type": "application/json;charset=UTF-8"]
            var code = 200
            var data: Data
            if search {
                func song(_ id: Int, title: String = "Fixture Song", artists: [String] = ["First", "Second"],
                          duration: Double? = 10_000, album: String = "Original") -> [String: Any] {
                    var value: [String: Any] = ["id": id, "name": title, "artists": artists.map { ["name": $0] }, "album": ["name": album]]
                    if let duration { value["duration"] = duration }
                    return value
                }
                var songs = [song(1)]
                switch scenario {
                case "live": songs = [song(1, title: "Fixture Song (Live)")]
                case "punctuation": songs = [song(1, title: "Fixture+Song")]
                case "normalized": songs = [song(1, title: "ｆｉｘｔｕｒｅ ｓｏｎｇ", artists: ["ＦＩＲＳＴ", "Second"])]
                case "artistSubset": songs = [song(1, artists: ["First"])]
                case "artistExtra": songs = [song(1, artists: ["First", "Second", "Third"])]
                case "durationMismatch": songs = [song(1, duration: 12_001)]
                case "durationBoundary": songs = [song(1, duration: 12_000)]
                case "durationMissing": songs = [song(1, duration: nil)]
                case "ambiguous", "album": songs = [song(1), song(2, album: "Compilation")]
                case "duplicate": songs = [song(1), song(1)]
                case "emptySearch": songs = []
                default: break
                }
                data = try! JSONSerialization.data(withJSONObject: ["code": 200, "result": ["songs": songs]])
            } else {
                var lyrics: [String: Any] = ["code": 200, "lrc": ["lyric": "[00:01]Synthetic first\n[00:03]Synthetic second\n[00:05]Synthetic third"],
                                          "tlyric": ["lyric": "[00:03]Second translation\n[00:05.15]Third translation"]]
                switch scenario {
                case "emptyLyrics": lyrics = ["code": 200, "lrc": ["lyric": ""]]
                case "plainLyrics": lyrics = ["code": 200, "lrc": ["lyric": "Synthetic untimed text"]]
                case "instrumental": lyrics = ["code": 200, "nolyric": true]
                case "instrumentalNotice": lyrics = ["code": 200, "lrc": ["lyric": "[00:01]纯音乐，请欣赏"]]
                case "uncollected": lyrics = ["code": 200, "uncollected": true]
                default: break
                }
                data = try! JSONSerialization.data(withJSONObject: lyrics)
            }
            if scenario == "oversizedHeader" { headers["Content-Length"] = "2000001" }
            if scenario == "oversizedStream" { data = Data(repeating: 32, count: 2_000_001) }
            if scenario == "badJSON" { data = Data("not JSON".utf8) }
            if scenario == "httpError" { code = 503 }
            if scenario == "wrongMime" { headers["Content-Type"] = "text/html" }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        pending = work
        DispatchQueue.global().asyncAfter(deadline: .now() + (scenario == "cancel" ? 2 : 0.005), execute: work)
    }
}

/// Fully intercepted anonymous website traffic with synthetic lyrics. This is
/// identity/cancellation coverage; it is not a claim of endpoint licensing.
func runNeteaseLyricsTests() async -> [String] {
    var failures: [String] = []
    func expect(_ value: Bool, _ message: String) { if !value { failures.append("NetEase lyrics: " + message) } }
    func descriptor(source: String = "com.netease.163music", duration: Double = 10) -> QQTrackDescriptor {
        QQTrackDescriptor(sourceBundleIdentifier: source, title: "Fixture Song", artist: "Second / First", duration: duration)
    }
    func fetch(_ scenario: String, descriptor value: QQTrackDescriptor? = nil,
               album: String? = nil) async throws -> NeteaseLyricsProvider.Payload? {
        NeteaseFixtureProtocol.reset(scenario)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NeteaseFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        return try await NeteaseLyricsProvider(session: session).fetch(for: value ?? descriptor(), album: album)
    }
    do {
        let normal = try await fetch("normal")
        expect(normal?.source == "NetEase LRC" && normal?.lines.count == 3, "exact normalized title, artist set, and duration load timed lyrics")
        expect(normal?.lines.first?.translation == nil && normal?.lines[1].translation == "Second translation"
               && normal?.lines.last?.translation == "Third translation", "sparse translations align by timestamp, including small rounding drift")
        expect(normal?.lines.last?.endTime == 10, "last line ends at the known player duration")
        let requests = NeteaseFixtureProtocol.requests()
        expect(requests.map { $0.url?.path } == ["/api/search/get", "/api/song/lyric"], "one search and one lyric request only")
        expect(requests.allSatisfy { $0.url?.host == "music.163.com" && $0.url?.scheme == "https"
            && $0.value(forHTTPHeaderField: "Cookie") == nil && $0.value(forHTTPHeaderField: "Authorization") == nil
            && !$0.httpShouldHandleCookies }, "requests stay anonymous on the official HTTPS host")
        let ignored = try await fetch("normal", descriptor: descriptor(source: "com.tencent.QQMusicMac"))
        expect(ignored == nil && NeteaseFixtureProtocol.requests().isEmpty, "QQ source cannot accidentally query the NetEase provider")
        for scenario in ["live", "punctuation", "artistSubset", "artistExtra", "durationMismatch", "durationMissing", "ambiguous", "emptySearch"] {
            let result = try await fetch(scenario)
            expect(result == nil && NeteaseFixtureProtocol.requests().count == 1, "\(scenario) refuses identity mismatch before requesting any lyrics")
        }
        let boundary = try await fetch("durationBoundary")
        expect(boundary?.lines.count == 3, "duration tolerance includes exactly two seconds")
        let normalized = try await fetch("normalized")
        expect(normalized?.lines.count == 3, "case and Unicode width differences normalize without removing version or title punctuation")
        let unknown = try await fetch("normal", descriptor: descriptor(duration: 0))
        expect(unknown?.lines.last?.endTime == 10, "a unique recording can supply duration when player timing is unavailable")
        let duplicate = try await fetch("duplicate")
        expect(duplicate?.lines.count == 3, "duplicate search rows of one catalog ID do not create false ambiguity")
        let album = try await fetch("album", album: "Original")
        expect(album?.lines.count == 3, "exact album safely disambiguates multiple otherwise identical catalog IDs")
        let wrongAlbum = try await fetch("album", album: "Different album")
        expect(wrongAlbum == nil && NeteaseFixtureProtocol.requests().count == 1, "album mismatch cannot silently select another recording")
        for scenario in ["emptyLyrics", "plainLyrics", "uncollected"] {
            let result = try await fetch(scenario)
            expect(result == nil, "\(scenario) permits a separate verified fallback rather than inventing synchronized lyrics")
        }
        for scenario in ["instrumental", "instrumentalNotice"] {
            let result = try await fetch(scenario)
            expect(result?.source == "NetEase instrumental" && result?.lines.isEmpty == true, "\(scenario) is explicitly represented without showing provider notices")
        }
        for scenario in ["oversizedHeader", "oversizedStream", "badJSON", "httpError", "wrongMime"] {
            do { _ = try await fetch(scenario); expect(false, "\(scenario) must reject the response") }
            catch { expect(NeteaseFixtureProtocol.requests().count == 1, "\(scenario) cannot proceed to lyrics after a rejected search response") }
        }
        NeteaseFixtureProtocol.reset("cancel")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NeteaseFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        let provider = NeteaseLyricsProvider(session: session)
        let value = descriptor()
        let task = Task { try await provider.fetch(for: value) }
        for _ in 0..<100 {
            if !NeteaseFixtureProtocol.requests().isEmpty { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        task.cancel()
        do { _ = try await task.value; expect(false, "canceling a pending request must not produce a payload") }
        catch { expect(NeteaseFixtureProtocol.requests().count == 1, "canceled search cannot issue a lyric request") }
        session.invalidateAndCancel()
    } catch { failures.append("NetEase lyrics fixture unexpectedly failed: \(error)") }
    return failures
}
