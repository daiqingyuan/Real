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
                let yrc = """
                {"t":0,"c":[{"tx":"Synthetic metadata"}]}
                [2200,1700](2200,600,0)Synthetic (2800,200,0)first(3000,900,0)!
                [5200,1300](5200,500,0)Synthetic (5700,800,0)second
                [8200,1500](8200,1500,0)Synthetic third
                """
                if scenario.hasPrefix("yrc") || scenario.hasSuffix("YRC") {
                    lyrics["yrc"] = ["lyric": yrc]
                    lyrics["ytlrc"] = ["lyric": "[00:05.20]Second YRC translation\n[00:08.35]Third YRC translation"]
                }
                switch scenario {
                case "yrcNoLegacy": lyrics.removeValue(forKey: "lrc")
                case "yrcEmpty": lyrics["yrc"] = ["lyric": ""]
                case "yrcNull": lyrics["yrc"] = NSNull()
                case "yrcWrongType": lyrics["yrc"] = "bad optional shape"
                case "yrcBadLyric": lyrics["yrc"] = ["lyric": 42]
                case "yrcMissingLyric": lyrics["yrc"] = [:]
                case "yrcNullLyric": lyrics["yrc"] = ["lyric": NSNull()]
                case "yrcMalformed": lyrics["yrc"] = ["lyric": "not synchronized YRC"]
                case "yrcBadHeader": lyrics["yrc"] = ["lyric": "[1000,1000](1000,1000,0)One\n[damaged]Two"]
                case "yrcUnclosedWord": lyrics["yrc"] = ["lyric": "[1000,2000](1000,1000,0)One(2000,500,0broken"]
                case "yrcAllInvalid": lyrics["yrc"] = ["lyric": "[1000,1000](1000,0,0)Sung word"]
                case "yrcOutOfDuration": lyrics["yrc"] = ["lyric": "[13000,1000](13000,1000,0)Outside"]
                case "yrcPunctuationOnly": lyrics["yrc"] = ["lyric": "[1000,1000](1000,0,0) !(1000,1000,0)，"]
                case "yrcMixedInvalid": lyrics["yrc"] = ["lyric": "[2200,1700](2200,1700,0)Synthetic first\n[5200,1300](5200,0,0)Synthetic second"]
                case "yrcUnknownLeadIn": lyrics["yrc"] = ["lyric": "[2200,1700](2200,0,0)啊～(2600,500,0)Some(3100,800,0) words\n[5200,1300](5200,0,0)Oh"]
                case "yrcRoundingEnd": lyrics["yrc"] = ["lyric": "[2200,1699](2200,600,0)first(2800,1100,0)last"]
                case "yrcPastRoundingBound": lyrics["yrc"] = ["lyric": "[2200,1697](2200,600,0)first(2800,1100,0)last"]
                case "yrcWrongTranslation": lyrics["ytlrc"] = ["lyric": 42]
                case "yrcWrongTranslationShape": lyrics["ytlrc"] = "bad optional shape"
                case "yrcMissingTranslationLyric": lyrics["ytlrc"] = [:]
                case "yrcNullTranslation": lyrics["ytlrc"] = NSNull()
                case "yrcNoTranslation": lyrics.removeValue(forKey: "ytlrc")
                case "yrcEmptyTranslation": lyrics["ytlrc"] = ["lyric": ""]
                case "yrcTranslationTie": lyrics["ytlrc"] = ["lyric": "[00:05.10]One\n[00:05.30]Two"]
                case "instrumentalYRC": lyrics["nolyric"] = true
                case "instrumentalNoticeYRC": lyrics["lrc"] = ["lyric": "[00:01]纯音乐，请欣赏"]
                case "uncollectedYRC": lyrics["uncollected"] = true
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

    let unicodeText = " 你👩🏽‍💻e\u{301}，  好! "
    let unicode = NeteaseYRCParser.parse("[1000,3000](1000,500,0) 你(1500,500,0)👩🏽‍💻(2000,500,0)e\u{301}(2500,0,0)，(2500,1500,0)  好! ")
    expect(unicode.count == 1 && unicode.first?.text == unicodeText && unicode.first?.words.count == 5,
           "YRC preserves edge/internal whitespace, punctuation, emoji modifiers/ZWJ, and combining characters")
    expect(unicode.first?.timing == .wordAnnotated, "YRC retains word-annotation provenance")
    if let line = unicode.first, line.words.count == 5 {
        let fragments = line.words.map { (line.text as NSString).substring(with: $0.range) }
        expect(fragments == [" 你", "👩🏽‍💻", "e\u{301}", "，", "  好! "], "YRC ranges use exact displayed UTF-16 substrings")
        expect(line.words.map(\.utf16Location) == [0, 2, 9, 11, 12], "YRC UTF-16 locations do not count graphemes as code units")
        expect(line.time == 1 && line.endTime == 4 && line.words[1].startTime == 1.5 && line.words[1].duration == 0.5,
               "YRC prefix word starts are absolute milliseconds, independently of the line start")
        expect(line.words[3].duration == 0 && line.words[4].startTime == 2.5,
               "zero-duration punctuation is an instantaneous provider token")
    }
    let parenthetical = NeteaseYRCParser.parse("[1000,2000](1000,2000,0)hello (world, friend)")
    expect(parenthetical.first?.text == "hello (world, friend)" && parenthetical.first?.words.count == 1,
           "ordinary lyric parentheticals survive YRC annotation removal")
    let metadata = NeteaseYRCParser.parse("{\"t\":0,\"c\":[{\"tx\":\"credit\",\"or\":\"do not open\"}]}\n[3000,1000](3000,1000,0)Later\n[1000,1000](1000,1000,0)Earlier")
    expect(metadata.map(\.text) == ["Earlier", "Later"] && metadata.map(\.id) == [0, 1],
           "JSON metadata is ignored and YRC rows receive stable sorted IDs")
    let punctuation = NeteaseYRCParser.parse("[1000,1000](1000,500,0)Hello(1500,0,0) ，—  (1500,500,0)world")
    expect(punctuation.first?.text == "Hello ，—  world" && punctuation.first?.words.count == 3,
           "zero-duration whitespace and Unicode punctuation preserve the following word")
    for text in ["sung", "123", "©", "🙂", "a\u{301}"] {
        let result = NeteaseYRCParser.parse("[1000,1000](1000,0,0)" + text)
        expect(result.first?.text == text && result.first?.words.isEmpty == true,
               "zero-duration sung letters/numbers/symbols/emoji retain text without word timing: \(text)")
        expect(result.first?.timing == .wordAnnotated, "unknown zero-duration singing cannot become sentence-timed fallback")
    }
    for (input, text, timed) in [
        ("[1000,2000](1000,1000,0)first(1500,500,0)second", "firstsecond", ["first"]),
        ("[1000,2000](2000,500,0)first(1000,500,0)second", "firstsecond", ["first"]),
        ("[1000,2000](999,100,0)early(1100,400,0)later", "earlylater", ["later"]),
        ("[1000,2000](1000,2500,0)outside", "outside", []),
        ("[1000,2000](1000,NaN,0)bad", "bad", []),
        ("[1000,2000](-1000,500,0)bad", "bad", []),
        ("[1000,2000](1000,inf,0)bad", "bad", []),
        ("[1000,2000](1000,1e3,0)bad", "bad", []),
        ("[1000,2000](1000.5,500,0)bad", "bad", []),
        ("[1000,2000](1000,,0)bad", "bad", []),
        ("[1000,2000](1000,500)bad", "bad", []),
        ("[1000,2000](1000,500,0,0)bad", "bad", []),
        ("[1000,2000](1000,500,NaN)bad", "bad", []),
        ("[1000,2000](1000,500,18446744073709551616)bad", "bad", []),
        ("[1000,2000](1000,999999999999999999999999,0)bad", "bad", []),
        ("[1000,2000]prefix(1000,1000,0)body", "prefixbody", ["body"]),
        ("[1000,2000](1000,1000,0)e(2000,1000,0)\u{301}", "e\u{301}", []),
        ("[1000,2000](1000,1000,0)👩(2000,1000,0)\u{200D}💻", "👩\u{200D}💻", []),
        ("[1000,2000]plain untimed row", "plain untimed row", []),
        ("[1000,3000]prefix(1000,0,0)啊(1500,1000,0)hello(2500,NaN,0)bad(3000,1000,0)later", "prefix啊hellobadlater", ["hello", "later"]),
        ("[1000,3000](1000,9999,0)bad(1500,500,0)good(2000,NaN,0)bad(2200,500,0)later", "badgoodbadlater", ["good", "later"]),
        ("[1000,3000](1000,2000,0)e(2000,100,0)\u{301}(2100,1000,0)later", "e\u{301}later", ["later"])
    ] {
        let result = NeteaseYRCParser.parse(input)
        expect(result.count == 1 && result.first?.text == text && result.first?.timing == .wordAnnotated,
               "YRC keeps readable text and annotation provenance around unknown spans: \(input)")
        if let line = result.first {
            expect(line.words.map { (line.text as NSString).substring(with: $0.range) } == timed,
                   "malformed/overlapping/grapheme-split spans leave independently valid words usable: \(input)")
        }
    }
    for extraMS in 0...3 {
        let result = NeteaseYRCParser.parse("[1000,1000](1000,500,0)A(1500,\(500 + extraMS),0)B")
        let accepted = extraMS <= 2
        expect(result.first?.words.count == (accepted ? 2 : 1), "YRC end rounding accepts at most two milliseconds: \(extraMS)")
        expect(abs((result.first?.endTime ?? 0) - (accepted ? Double(2000 + extraMS) / 1000 : 2)) < 0.000_000_1,
               "only accepted rounding expands the YRC line end: \(extraMS)")
        if accepted, let last = result.first?.words.last {
            expect(last.startTime == 1.5 && last.duration == Double(500 + extraMS) / 1000,
                   "YRC rounding retains the exact provider word interval")
        }
    }
    for input in ["", "{\"t\":0,\"c\":[]}", "not YRC", "[1000,0](1000,0,0)zero line", "[bad]row",
                  "[604800000,1](604800000,1,0)too late", "[1000,999999999999999999999999]huge",
                  "[1000,1000](1000,1000,0)good\n[damaged]bad",
                  "[1000,2000](1000,1000,0)good(2000,500,0broken"] {
        expect(NeteaseYRCParser.parse(input).isEmpty, "empty, metadata-only, unbounded or malformed YRC rejects enrichment: \(input)")
    }
    expect(NeteaseYRCParser.parse("[13000,1000](13000,1000,0)too late", duration: 10).isEmpty,
           "YRC line intervals stay within the known track duration plus matching tolerance")
    expect(NeteaseYRCParser.parse(String(repeating: "x", count: 2_000_001)).isEmpty, "YRC parser bounds direct input size")
    do {
        let normal = try await fetch("normal")
        expect(normal?.source == "NetEase LRC" && normal?.lines.count == 3, "exact normalized title, artist set, and duration load timed lyrics")
        expect(normal?.lines.first?.translation == nil && normal?.lines[1].translation == "Second translation"
               && normal?.lines.last?.translation == "Third translation", "sparse translations align by timestamp, including small rounding drift")
        expect(normal?.lines.last?.endTime == 10, "last line ends at the known player duration")
        expect(normal?.lines.allSatisfy({ $0.timing == .sentence }) == true, "legacy LRC retains genuine sentence timing")
        let requests = NeteaseFixtureProtocol.requests()
        expect(requests.map { $0.url?.path } == ["/api/search/get", "/api/song/lyric"], "one search and one lyric request only")
        expect(requests.allSatisfy { $0.url?.host == "music.163.com" && $0.url?.scheme == "https"
            && $0.value(forHTTPHeaderField: "Cookie") == nil && $0.value(forHTTPHeaderField: "Authorization") == nil
            && !$0.httpShouldHandleCookies }, "requests stay anonymous on the official HTTPS host")
        let query = requests.last.flatMap { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        expect(query.count == 5 && query.contains(URLQueryItem(name: "yv", value: "-1"))
               && ["lv", "kv", "tv"].allSatisfy { query.contains(URLQueryItem(name: $0, value: "-1")) },
               "YRC adds only yv=-1 while retaining the same anonymous legacy lyric GET")
        expect(requests.allSatisfy { $0.httpMethod == "GET" && $0.httpBody == nil
            && $0.value(forHTTPHeaderField: "Accept") == "application/json"
            && $0.value(forHTTPHeaderField: "User-Agent") == "Real/1.0.0"
            && $0.value(forHTTPHeaderField: "Referer") == "https://music.163.com/" }, "YRC needs no new headers, body, or transport")
        let yrc = try await fetch("yrc")
        expect(yrc?.source == "NetEase YRC" && yrc?.lines.count == 3 && yrc?.lines.first?.time == 2.2
               && yrc?.lines.first?.text == "Synthetic first!" && yrc?.lines.first?.words.count == 3,
               "usable YRC replaces the LRC timeline using prefix word annotations")
        expect(yrc?.lines[1].time == 5.2 && yrc?.lines[1].endTime == 6.5
               && yrc?.lines[1].words.first?.startTime == 5.2 && yrc?.lines.last?.endTime == 9.7,
               "YRC keeps provider line intervals and absolute word starts, without legacy row attachment")
        expect(yrc?.lines.first?.translation == nil && yrc?.lines[1].translation == "Second YRC translation"
               && yrc?.lines.last?.translation == "Third YRC translation", "sparse YTLRC aligns by YRC timestamps including small drift")
        expect(yrc?.lines.allSatisfy({ $0.timing == .wordAnnotated }) == true, "YTLRC merging preserves original word timing provenance")
        expect(NeteaseFixtureProtocol.requests().map { $0.url?.path } == ["/api/search/get", "/api/song/lyric"],
               "YRC adds no endpoint or request beyond the legacy search/lyric pair")
        let yrcOnly = try await fetch("yrcNoLegacy")
        expect(yrcOnly?.source == "NetEase YRC" && yrcOnly?.lines.first?.words.count == 3,
               "valid YRC can supply original lyrics independently when legacy LRC is absent")
        for scenario in ["yrcEmpty", "yrcNull", "yrcWrongType", "yrcBadLyric", "yrcMissingLyric", "yrcNullLyric",
                         "yrcMalformed", "yrcBadHeader", "yrcUnclosedWord", "yrcAllInvalid", "yrcOutOfDuration", "yrcPunctuationOnly"] {
            let fallback = try await fetch(scenario)
            expect(fallback?.source == "NetEase LRC" && fallback?.lines == normal?.lines,
                   "\(scenario) leaves valid legacy lyrics/translations unchanged")
            expect(NeteaseFixtureProtocol.requests().count == 2, "\(scenario) fallback stays within one lyric request")
        }
        let mixed = try await fetch("yrcMixedInvalid")
        expect(mixed?.source == "NetEase YRC" && mixed?.lines.count == 2 && mixed?.lines.first?.words.count == 1
               && mixed?.lines.last?.text == "Synthetic second" && mixed?.lines.last?.words.isEmpty == true,
               "a bad sung-word duration retains that row as plain text beside valid word-timed YRC rows")
        expect(mixed?.lines.last?.timing == .wordAnnotated && mixed?.lines.last?.translation == "Second YRC translation",
               "translated unknown YRC singing cannot silently acquire sentence timing")
        let leadIn = try await fetch("yrcUnknownLeadIn")
        expect(leadIn?.source == "NetEase YRC" && leadIn?.lines.first?.text == "啊～Some words"
               && leadIn?.lines.first?.words.count == 2 && leadIn?.lines.first?.words.first?.startTime == 2.6
               && leadIn?.lines.first?.words.first?.utf16Location == 2,
               "unknown zero-duration lead-in vowels stay uncolored while later verified YRC words remain usable")
        expect(leadIn?.lines.last?.text == "Oh" && leadIn?.lines.last?.words.isEmpty == true
               && leadIn?.lines.last?.timing == .wordAnnotated, "an all-unknown ad-lib row retains YRC provenance beside timed rows")
        let rounded = try await fetch("yrcRoundingEnd")
        expect(rounded?.source == "NetEase YRC" && rounded?.lines.first?.words.count == 2 && rounded?.lines.first?.endTime == 3.9,
               "a one-millisecond YRC header rounding difference retains the final word and expands its line end")
        let outsideRounding = try await fetch("yrcPastRoundingBound")
        expect(outsideRounding?.source == "NetEase YRC" && outsideRounding?.lines.first?.words.count == 1
               && outsideRounding?.lines.first?.text == "firstlast" && outsideRounding?.lines.first?.endTime == 3.897,
               "beyond-tolerance final words remain white without discarding earlier verified YRC timing")
        for scenario in ["yrcWrongTranslation", "yrcWrongTranslationShape", "yrcMissingTranslationLyric", "yrcNullTranslation", "yrcNoTranslation", "yrcEmptyTranslation"] {
            let untranslated = try await fetch(scenario)
            expect(untranslated?.source == "NetEase YRC" && untranslated?.lines.allSatisfy({ !$0.words.isEmpty && $0.translation == nil }) == true,
                   "\(scenario) preserves valid YRC without attaching unrelated legacy translation rows")
        }
        let tied = try await fetch("yrcTranslationTie")
        expect(tied?.source == "NetEase YRC" && tied?.lines[1].translation == nil,
               "equidistant YTLRC candidates are ambiguous rather than assigned by row position")
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
        for scenario in ["emptyLyrics", "plainLyrics", "uncollected", "uncollectedYRC"] {
            let result = try await fetch(scenario)
            expect(result == nil, "\(scenario) permits a separate verified fallback rather than inventing synchronized lyrics")
        }
        for scenario in ["instrumental", "instrumentalNotice", "instrumentalYRC", "instrumentalNoticeYRC"] {
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
