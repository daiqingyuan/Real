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
                var response: [String: Any] = ["code": 200, "result": ["songs": songs]]
                if scenario == "searchServiceError" { response = ["code": 500, "result": ["songs": []]] }
                if scenario == "searchLoginRequired" { response = ["code": 301] }
                if scenario == "missingSearchResult" { response = ["code": 200] }
                if scenario == "emptyResultObject" { response = ["code": 200, "result": [:]] }
                if scenario == "songCountZero" { response = ["code": 200, "result": ["songCount": 0]] }
                data = try! JSONSerialization.data(withJSONObject: response)
            } else {
                var lyrics: [String: Any] = ["code": 200, "lrc": ["lyric": "[00:01]Synthetic first\n[00:03]Synthetic second\n[00:05]Synthetic third"],
                                          "tlyric": ["lyric": "[00:03]Second translation\n[00:05.15]Third translation"]]
                switch scenario {
                case "emptyLyrics": lyrics = ["code": 200, "lrc": ["lyric": ""]]
                case "plainLyrics": lyrics = ["code": 200, "lrc": ["lyric": "Synthetic untimed text"]]
                case "instrumental": lyrics = ["code": 200, "nolyric": true]
                case "instrumentalNotice": lyrics = ["code": 200, "lrc": ["lyric": "[00:01]纯音乐，请欣赏"]]
                case "uncollected": lyrics = ["code": 200, "uncollected": true]
                case "lyricsServiceError": lyrics = ["code": 500, "nolyric": true]
                case "lyricsLoginRequired": lyrics = ["code": 301, "uncollected": true]
                case "missingLyrics": lyrics = ["code": 200]
                case "missingLyricText": lyrics = ["code": 200, "lrc": [:]]
                case "nullLyricText": lyrics = ["code": 200, "lrc": ["lyric": NSNull()]]
                default: break
                }
                data = try! JSONSerialization.data(withJSONObject: lyrics)
            }
            if scenario == "oversizedHeader" { headers["Content-Length"] = "2000001" }
            if scenario == "oversizedStream" { data = Data(repeating: 32, count: 2_000_001) }
            if scenario == "badJSON" { data = Data("not JSON".utf8) }
            if scenario == "httpError" { code = 503 }
            if scenario == "searchHTTP500", search { code = 500 }
            if scenario == "lyricsHTTP404", !search { code = 404 }
            if (scenario == "searchHTTP429" && search) || (scenario == "lyricsHTTP429" && !search) {
                code = 429; headers["Retry-After"] = "7"
                // A throttled endpoint may return HTML instead of its normal
                // JSON content. The HTTP deadline must still be recognized.
                headers["Content-Type"] = "text/html"
            }
            if scenario == "http503Date" || scenario == "lyricsHTTP503Date" && !search {
                code = 503
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
                headers["Retry-After"] = formatter.string(from: Date().addingTimeInterval(120))
            }
            if scenario == "http429Zero" { code = 429; headers["Retry-After"] = "0" }
            if scenario == "http429Past" { code = 429; headers["Retry-After"] = "Sun, 06 Nov 1994 08:49:37 GMT" }
            if scenario == "http429Malformed" { code = 429; headers["Retry-After"] = "not a retry date" }
            if scenario == "http429Nonfinite" { code = 429; headers["Retry-After"] = "inf" }
            if scenario == "http429Extreme" { code = 429; headers["Retry-After"] = "1e308" }
            if scenario == "wrongMime" { headers["Content-Type"] = "text/html" }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        pending = work
        let delayed = scenario == "cancel" || scenario == "cancelLyrics" && request.url?.path == "/api/song/lyric"
        DispatchQueue.global().asyncAfter(deadline: .now() + (delayed ? 2 : 0.005), execute: work)
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
        for scenario in ["live", "punctuation", "artistSubset", "artistExtra", "durationMismatch", "durationMissing", "ambiguous", "emptySearch", "emptyResultObject", "songCountZero"] {
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
        for (scenario, count) in [("missingSearchResult", 1), ("missingLyrics", 2), ("missingLyricText", 2), ("nullLyricText", 2)] {
            do { _ = try await fetch(scenario); expect(false, "\(scenario) must not become a cached missing-lyrics result") }
            catch let error as NeteaseLyricsProvider.RequestError {
                if case .response = error { /* Missing structure is a provider response failure. */ }
                else { expect(false, "\(scenario) must report a response-shape failure") }
                expect(NeteaseFixtureProtocol.requests().count == count, "\(scenario) stops at the malformed response")
            } catch { expect(false, "\(scenario) returned an unexpected failure type") }
        }
        for (scenario, code, count) in [("searchServiceError", 500, 1), ("searchLoginRequired", 301, 1),
                                       ("lyricsServiceError", 500, 2), ("lyricsLoginRequired", 301, 2)] {
            do { _ = try await fetch(scenario); expect(false, "\(scenario) must not masquerade as no lyrics or instrumental") }
            catch let error as NeteaseLyricsProvider.RequestError {
                if case let .service(actual) = error { expect(actual == code, "\(scenario) preserves the service error code") }
                else { expect(false, "\(scenario) must be classified as a service error") }
                expect(error.retryAfter == nil, "\(scenario) does not invent a server retry deadline")
                expect(NeteaseFixtureProtocol.requests().count == count, "\(scenario) stops at the failing stage")
            } catch { expect(false, "\(scenario) returned the wrong error type: \(error)") }
        }
        for (scenario, code, count) in [("searchHTTP500", 500, 1), ("lyricsHTTP404", 404, 2)] {
            do { _ = try await fetch(scenario); expect(false, "\(scenario) must throw an HTTP error") }
            catch let error as NeteaseLyricsProvider.RequestError {
                if case let .http(actual) = error { expect(actual == code, "\(scenario) preserves the HTTP status") }
                else { expect(false, "\(scenario) must be classified as an HTTP error") }
                expect(error.retryAfter == nil, "\(scenario) has no Retry-After without a throttle")
                expect(NeteaseFixtureProtocol.requests().count == count, "\(scenario) cannot fall through a rejected stage")
            } catch { expect(false, "\(scenario) returned the wrong error type: \(error)") }
        }
        for (scenario, expected, count) in [("searchHTTP429", 7.0, 1), ("lyricsHTTP429", 7.0, 2),
                                           ("http503Date", 120.0, 1), ("lyricsHTTP503Date", 120.0, 2),
                                           ("httpError", 60.0, 1), ("http429Malformed", 60.0, 1),
                                           ("http429Nonfinite", 60.0, 1), ("http429Zero", 1.0, 1), ("http429Past", 1.0, 1)] {
            let start = Date()
            do { _ = try await fetch(scenario); expect(false, "\(scenario) must expose a throttled result") }
            catch let error as NeteaseLyricsProvider.RequestError {
                if case .throttled = error, let retry = error.retryAfter {
                    let interval = retry.timeIntervalSince(start)
                    expect(interval >= expected - 1.1 && interval <= expected + 2,
                           "\(scenario) respects Retry-After or its bounded missing-header fallback")
                } else { expect(false, "\(scenario) must expose retryAfter through a throttled error") }
                expect(NeteaseFixtureProtocol.requests().count == count, "\(scenario) sends no request past the throttled stage")
            } catch { expect(false, "\(scenario) returned the wrong error type: \(error)") }
        }
        do { _ = try await fetch("http429Extreme"); expect(false, "an extreme deadline must remain a throttle") }
        catch let error as NeteaseLyricsProvider.RequestError {
            expect(error.retryAfter?.timeIntervalSinceReferenceDate.isFinite == true, "an extreme Retry-After never produces a nonfinite Date")
        } catch { expect(false, "an extreme Retry-After returned the wrong error type") }

        for (scenario, count) in [("cancel", 1), ("cancelLyrics", 2)] {
            NeteaseFixtureProtocol.reset(scenario)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [NeteaseFixtureProtocol.self]
            let session = URLSession(configuration: configuration)
            let provider = NeteaseLyricsProvider(session: session)
            let value = descriptor()
            let task = Task { try await provider.fetch(for: value) }
            for _ in 0..<100 {
                if NeteaseFixtureProtocol.requests().count >= count { break }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            expect(NeteaseFixtureProtocol.requests().count == count, "\(scenario) reaches its intended cancellation stage")
            task.cancel()
            do { _ = try await task.value; expect(false, "\(scenario) cancellation must not produce a payload or a no-lyrics result") }
            catch {
                expect(error is CancellationError || (error as? URLError)?.code == .cancelled,
                       "\(scenario) remains a cancellation rather than a response failure")
                expect(NeteaseFixtureProtocol.requests().count == count, "\(scenario) cannot issue a further request")
            }
            session.invalidateAndCancel()
        }
    } catch { failures.append("NetEase lyrics fixture unexpectedly failed: \(error)") }
    return failures
}
