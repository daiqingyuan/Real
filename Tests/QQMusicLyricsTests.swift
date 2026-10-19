import Foundation
import CryptoKit

func runQQMusicLyricsTests() -> [String] {
    var failures: [String] = []
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) { if !condition() { failures.append(message) } }
    let qrc = "[3000,1200]Beta(3000,1200)\n[1000,1500]Alpha(1000,500) world(1500,1000)"
    let parsed = QQMusicQRCParser.parse(qrcContent: qrc, translationContent: "[00:03.0]Second translation")
    let translated = QQMusicQRCParser.applyTranslations(parsed.lines, translations: parsed.translations)
    expect(translated.map(\.time) == [1, 3], "QRC headers are sorted by real start time")
    expect(translated.map(\.endTime) == [2.5, 4.2], "QRC duration produces exact line endings")
    expect(translated.first?.text == "Alpha world", "QRC word timestamps are removed without losing text")
    expect(translated.first?.translation == nil && translated.last?.translation == "Second translation", "Unequal translation counts must align by timestamp")
    let collapsed = QQMusicQRCParser.parse(qrcContent: "[1000,500]First(1000,500) [2000,500]Second(2000,500)")
    expect(collapsed.lines.count == 2, "QRC headers survive normalized XML attribute whitespace")
    let xml = "<QrcInfos><QrcInfo><Lyric_1 LyricContent=\"[1000,1500]First(1000,1500)\n[3000,1000]Second(3000,1000)\" LyricTranslation=\"[00:01.0]Uno&#10;[00:03.0]Dos\"/></QrcInfo></QrcInfos>"
    let fields = QQMusicQRCParser.extractFromXML(xml)
    expect(fields.orig?.contains("\n") == true, "Literal lyric attribute newlines must not be normalized away")
    let xmlLines = QQMusicQRCParser.parseResponse(original: xml, translation: nil)
    expect(xmlLines.count == 2 && xmlLines.last?.translation == "Dos", "XML attributes retain timed translations")
    let commented = "<!-- vendor prefix\n<cmd><content><![CDATA[[1000,2000]Fixture(1000,2000)]]></content><contentts><![CDATA[[00:01]Translation]]></contentts></cmd> -->"
    let commentFields = QQMusicQRCParser.extractFromXML(commented)
    expect(commentFields.orig?.hasPrefix("[1000,2000]") == true && commentFields.trans != nil, "Comment-wrapped legacy XML fields are recovered")
    expect(QQMusicQRCParser.decodeEntities("A &#x26; B &#10; C") == "A & B \n C", "Numeric and hexadecimal XML entities")
    expect(!QQMusicQRCParser.hasUsableLyrics([LyricLine(id: 0, time: 0, text: "此歌曲暂无歌词，请您欣赏")]), "Provider no-lyrics notices are not displayed as song lyrics")
    expect(QQMusicQRCDecoder.decode("0") == nil && QQMusicQRCDecoder.decode("00ff") == nil && QQMusicQRCDecoder.decode(String(repeating: "z", count: 16)) == nil, "Malformed or incomplete encrypted blocks are rejected")

    let legacy = Data(#"callback({"code":0,"data":{"song":{"list":[{"songmid":"fixture-mid","songid":12345,"songname":"Fixture","singer":[{"name":"Artist"}],"interval":10}]}}});"#.utf8)
    let candidates = QQMusicLyricsProvider.searchCandidates(legacy)
    expect(candidates.first?.songID == 12345, "Legacy search must preserve the numeric QRC music ID")
    let descriptor = QQTrackDescriptor(sourceBundleIdentifier: "com.tencent.QQMusicMac", title: "Fixture", artist: "Artist", duration: 10)
    expect(QQMusicLyricsProvider.bestMatch(candidates, for: descriptor)?.songmid == "fixture-mid", "Exact title, artist and duration match")
    let incorrect = QQMusicLyricsProvider.SongMatch(songmid: "wrong", songID: 1, title: "Other", artists: ["Artist"], duration: 10)
    expect(QQMusicLyricsProvider.bestMatch([incorrect], for: descriptor) == nil, "Artist-only search matches must be rejected")
    let alternate = QQMusicLyricsProvider.SongMatch(songmid: "live", songID: 2, title: "Fixture (Live)", artists: ["Artist"], duration: 10)
    expect(QQMusicLyricsProvider.bestMatch([alternate], for: descriptor) == nil, "Live/remix suffixes cannot silently match a studio title")
    let shorter = QQMusicLyricsProvider.SongMatch(songmid: "shorter", songID: 3, title: "Fixture", artists: ["Artist"], duration: 9)
    let unknown = QQTrackDescriptor(sourceBundleIdentifier: nil, title: "Fixture", artist: "Artist", duration: 0)
    expect(QQMusicLyricsProvider.bestMatch(candidates + [shorter], for: unknown)?.songmid == "fixture-mid", "Unknown duration preserves provider ranking rather than preferring shortest songs")
    func match(_ durations: [Double], playerDuration: Double, sameIdentity: Bool = false) -> QQMusicLyricsProvider.SongMatch? {
        let songs = durations.enumerated().map { index, duration in
            QQMusicLyricsProvider.SongMatch(songmid: sameIdentity ? "one" : "version-\(index)", songID: sameIdentity ? 1 : index + 1,
                title: "Fixture", artists: ["Artist"], duration: duration)
        }
        return QQMusicLyricsProvider.bestMatch(songs, for: QQTrackDescriptor(sourceBundleIdentifier: "com.tencent.QQMusicMac",
            title: "Fixture", artist: "Artist", duration: playerDuration))
    }
    expect(match([209], playerDuration: 213) != nil, "One exact identity tolerates four seconds of player/catalog padding")
    expect(match([209, 212], playerDuration: 213)?.duration == 212, "Original three-second matches retain priority")
    expect(match([195], playerDuration: 200) != nil && match([194.99], playerDuration: 200) == nil, "Padding allowance includes the 2.5 percent boundary only")
    expect(match([394], playerDuration: 400) != nil && match([393.99], playerDuration: 400) == nil, "Padding allowance never exceeds six seconds")
    expect(match([96], playerDuration: 100) == nil, "Short songs do not gain a large relative allowance")
    expect(match([209, 208], playerDuration: 213) == nil, "Multiple catalog identities remain ambiguous within padding allowance")
    expect(match([209, 170], playerDuration: 213) == nil, "A distant alternative cannot be filtered away to manufacture uniqueness")
    expect(match([209, 209], playerDuration: 213, sameIdentity: true) != nil, "Repeated identical search records do not create ambiguity")
    expect(match([209, 208], playerDuration: 213, sameIdentity: true) == nil, "Conflicting durations for the same identity refuse relaxed matching")
    let paddedDescriptor = QQTrackDescriptor(sourceBundleIdentifier: "com.tencent.QQMusicMac", title: "Fixture", artist: "Artist", duration: 213)
    let padded = QQMusicLyricsProvider.SongMatch(songmid: "one", songID: 1, title: "Fixture", artists: ["Artist"], duration: 209)
    let conflictingID = QQMusicLyricsProvider.SongMatch(songmid: "one", songID: 2, title: "Fixture", artists: ["Artist"], duration: 209)
    let duet = QQMusicLyricsProvider.SongMatch(songmid: "duet", songID: 3, title: "Fixture", artists: ["Artist", "Guest"], duration: 209)
    let livePadded = QQMusicLyricsProvider.SongMatch(songmid: "live", songID: 4, title: "Fixture (Live)", artists: ["Artist"], duration: 209)
    expect(QQMusicLyricsProvider.bestMatch([padded, conflictingID], for: paddedDescriptor) == nil, "Conflicting numeric IDs refuse relaxed matching")
    expect(QQMusicLyricsProvider.bestMatch([duet], for: paddedDescriptor) == nil, "Padding cannot match solo metadata to a duet")
    expect(QQMusicLyricsProvider.bestMatch([padded, duet], for: paddedDescriptor) == nil, "An extra-artist alternative still makes the relaxed identity ambiguous")
    expect(QQMusicLyricsProvider.bestMatch([livePadded], for: paddedDescriptor) == nil, "Padding cannot remove version suffixes")
    expect(match([.nan], playerDuration: 213) == nil && match([209], playerDuration: .infinity) == nil, "Nonfinite durations cannot match")
    func aliasDescriptor(_ title: String, duration: Double = 10) -> QQTrackDescriptor {
        QQTrackDescriptor(sourceBundleIdentifier: "com.tencent.QQMusicMac", title: title, artist: "Artist", duration: duration)
    }
    let subtitleSong = QQMusicLyricsProvider.SongMatch(songmid: "alias", songID: 31, title: "Fixture", artists: ["Artist"], duration: 10, subtitle: "Another name")
    expect(QQMusicLyricsProvider.bestMatch([subtitleSong], for: aliasDescriptor("Fixture (Another name)"))?.songmid == "alias", "Explicit catalog subtitle matches the player's full parenthetical display name")
    expect(QQMusicLyricsProvider.bestMatch([subtitleSong], for: aliasDescriptor("Fixture（Another name）"))?.songmid == "alias", "Catalog alias matches width and whitespace variations")
    expect(QQMusicLyricsProvider.bestMatch([subtitleSong], for: aliasDescriptor("Fixture (Different)")) == nil, "Unknown parenthetical text is never deleted to manufacture a match")
    expect(QQMusicLyricsProvider.bestMatch([subtitleSong], for: aliasDescriptor("Fixture (Another name)", duration: 0))?.songmid == "alias", "Unknown duration still requires a unique explicit alias identity")
    let otherAlias = QQMusicLyricsProvider.SongMatch(songmid: "other", songID: 32, title: "Fixture", artists: ["Artist"], duration: 30, subtitle: "Another name")
    expect(QQMusicLyricsProvider.bestMatch([subtitleSong, otherAlias], for: aliasDescriptor("Fixture (Another name)")) == nil, "Alias ambiguity is checked before duration can discard another catalog identity")
    let punctuationAlias = QQMusicLyricsProvider.SongMatch(songmid: "punctuation", songID: 33, title: "Fixture", artists: ["Artist"], duration: 10, subtitle: "AB")
    expect(QQMusicLyricsProvider.bestMatch([punctuationAlias], for: aliasDescriptor("Fixture (A+B)")) == nil, "Explicit alias comparison retains meaningful punctuation")
    for version in ["Live", "Remix", "Cover", "Acoustic", "Instrumental", "现场版", "翻唱版"] {
        let edition = QQMusicLyricsProvider.SongMatch(songmid: "edition", songID: 34, title: "Fixture", artists: ["Artist"], duration: 10, subtitle: version)
        expect(QQMusicLyricsProvider.bestMatch([edition], for: aliasDescriptor("Fixture")) == nil, "Catalog version subtitle \(version) cannot disappear on the standard path")
        expect(QQMusicLyricsProvider.bestMatch([edition], for: aliasDescriptor("Fixture (\(version))")) != nil, "Explicitly matching catalog version \(version) remains supported")
    }
    let named = QQMusicLyricsProvider.SongMatch(songmid: "named", songID: 35, title: "Fixture", artists: ["Artist"], duration: 10, alternateTitles: ["Fixture (Explicit other name)"])
    expect(QQMusicLyricsProvider.bestMatch([named], for: aliasDescriptor("Fixture (Explicit other name)"))?.songmid == "named", "Explicit catalog names may add a display alias without erasing the canonical title")
    let liveName = QQMusicLyricsProvider.SongMatch(songmid: "live-name", songID: 36, title: "Fixture (Live)", artists: ["Artist"], duration: 10, alternateTitles: ["Fixture"])
    expect(QQMusicLyricsProvider.bestMatch([liveName], for: aliasDescriptor("Fixture")) == nil, "A plain catalog name cannot erase the preferred title's explicit edition")
    for suffix in ["(DJ版)", "(Special Cut)", "- Unknown Edition"] {
        let decorated = QQMusicLyricsProvider.SongMatch(songmid: "decorated", songID: 39, title: "Fixture " + suffix, artists: ["Artist"], duration: 10, alternateTitles: ["Fixture"])
        expect(QQMusicLyricsProvider.bestMatch([decorated], for: aliasDescriptor("Fixture")) == nil, "A secondary name cannot erase the canonical title's arbitrary suffix \(suffix)")
    }
    let partialArtist = QQMusicLyricsProvider.SongMatch(songmid: "standard-duet", songID: 37, title: "Fixture", artists: ["Artist", "Guest"], duration: 10)
    expect(QQMusicLyricsProvider.bestMatch([partialArtist], for: descriptor)?.songmid == "standard-duet", "Existing exact title and duration allow player metadata containing the main artist only")
    let aliasJSON = Data(#"{"code":0,"req_0":{"code":0,"data":{"body":{"song":{"list":[{"mid":"alias-json","id":38,"title":"Fixture","name":"Explicit other name","subtitle":"Another name","singer":[{"name":"Artist"}],"interval":10}]}}}}}"#.utf8)
    expect(QQMusicLyricsProvider.searchCandidates(aliasJSON).first?.subtitle == "Another name"
        && QQMusicLyricsProvider.searchCandidates(aliasJSON).first?.alternateTitles == ["Explicit other name"], "Search parsing retains catalog subtitle and explicit names")
    for raw in [#"{"code":0,"req_0":{"code":2001}}"#, #"{"code":2001}"#, #"{"code":0,"req_0":{"code":0,"data":{}}}"#, #"{"code":0,"data":{"song":{"list":[{"mid":"missing-title"}]}}}"#] {
        do { _ = try QQMusicLyricsProvider.validatedSearchCandidates(Data(raw.utf8)); expect(false, "Rejected services and missing search structure must throw") }
        catch { /* A failed probe must remain distinguishable from a valid empty list. */ }
    }
    do {
        let empty = try QQMusicLyricsProvider.validatedSearchCandidates(Data(#"{"code":0,"data":{"song":{"list":[]}}}"#.utf8))
        expect(empty.isEmpty, "A verified code-zero empty list remains a true empty result")
    } catch { failures.append("A valid empty search unexpectedly failed") }
    let base64 = Data("[00:01.2]First\n[00:03.0]Second".utf8).base64EncodedString()
    let trans = Data("[00:03.0]Translated second".utf8).base64EncodedString()
    let lrcData = try! JSONSerialization.data(withJSONObject: ["code": 0, "lyric": ["code": 0, "data": ["lyric": base64, "trans": trans]]])
    let lrc = QQMusicLyricsProvider.parseLyricsResponse(lrcData, duration: 5)
    expect(lrc.first?.time == 1.2 && lrc.last?.endTime == 5, "QQ LRC fractional timestamps and ending are retained")
    expect(lrc.last?.translation == "Translated second" && lrc.first?.translation == nil, "QQ LRC trans data is retained and aligned")
    // This is synthetic repeated text, not a saved song. It compresses by more than 10:1.
    let highRatioHex = "c00e49eb27c02ba28a3f15c04b8835ce28c5a3c31b27a96fc9c90541b4e5ac7a38a74e1bd287d1b8d1bc20dda12e60c9d1bc20dda12e60c9d1bc20dda12e60c9d1bc20dda12e60c9d1bc20dda12e60c9d1bc20dda12e60c9d1bc20dda12e60c9d1bc20dda12e60c9d1bc20dda12e60c9d1bc20dda12e60c9fd00a9d50bb61e3bfb52fc605598aa45"
    expect(QQMusicQRCDecoder.decode(highRatioHex) == "[1000,2000]" + String(repeating: "A(1000,2000)", count: 4000), "QRC decompression grows beyond the former fixed 10x buffer")
    return failures
}

func runQQMusicLiveFixtureTests(at url: URL) -> [String] {
    do {
        let xml = try String(contentsOf: url, encoding: .utf8)
        let fields = QQMusicQRCParser.extractFromXML(xml)
        guard let original = fields.orig else { return ["Live QQ fixture lacks original content"] }
        let decoded = QQMusicQRCDecoder.decode(original.filter { !$0.isWhitespace })
        guard let decoded else { return ["Captured QQ cipher fixture failed to decrypt"] }
        let lines = QQMusicQRCParser.parseResponse(original: original, translation: fields.trans, duration: 269)
        guard decoded.count == 8661, lines.count == 63, QQMusicQRCParser.hasUsableLyrics(lines),
              lines.allSatisfy({ $0.time.isFinite && ($0.endTime ?? 0) >= $0.time }) else {
            return ["Captured QQ fixture line count or timing validation failed"]
        }
        return []
    } catch { return ["Cannot read explicitly supplied QQ fixture: \(error.localizedDescription)"] }
}

private final class QQFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var scenario = "qrc"
    private static var requests: [String] = []
    static func reset(_ value: String) { lock.lock(); scenario = value; requests = []; lock.unlock() }
    static func paths() -> [String] { lock.lock(); defer { lock.unlock() }; return requests }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.lock.lock()
        let scenario = Self.scenario
        Self.lock.unlock()
        let host = request.url?.host ?? ""
        let path = request.url?.path ?? ""
        var route = ""
        var data = Data()
        if host == "lrclib.net" {
            route = "lrclib"
            data = Data(#"[{"trackName":"Fixture","artistName":"Artist","duration":10,"instrumental":false,"syncedLyrics":"[00:01]Fallback fixture","plainLyrics":null}]"#.utf8)
        } else if path.contains("lyric_download") {
            route = "qrc"
            data = Data((["qrc", "duration-padding"].contains(scenario) ? "<cmd><content><![CDATA[[1000,2000]Fixture(1000,2000)]]></content><contentts><![CDATA[[00:01]Translation]]></contentts></cmd>" : "<cmd><content></content></cmd>").utf8)
        } else {
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "data" })?.value ?? ""
            if query.contains("DoSearchForQQMusicDesktop") {
                route = "search"
                let interval = scenario == "duration-padding" ? 209 : 10
                data = try! JSONSerialization.data(withJSONObject: ["code": 0, "req_0": ["code": 0, "data": ["body": ["song": ["list": [
                    ["mid": "fixture", "id": 123, "title": "Fixture", "singer": [["name": "Artist"]], "interval": interval]
                ]]]]]])
            } else if path.contains("client_search") {
                route = "legacy-search"
                data = Data(#"{"code":0,"data":{"song":{"list":[]}}}"#.utf8)
            } else {
                route = "lrc"
                let node: [String: Any] = scenario == "lrclib" ? ["lyric": ""] : ["lyric": Data("[00:01]LRC fixture".utf8).base64EncodedString(), "trans": Data("[00:01]Translated fixture".utf8).base64EncodedString()]
                data = try! JSONSerialization.data(withJSONObject: ["code": 0, "lyric": ["code": 0, "data": node]])
            }
        }
        Self.lock.lock(); Self.requests.append(route); Self.lock.unlock()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
func runQQMusicPipelineTests() async -> [String] {
    var failures: [String] = []
    for scenario in ["qrc", "duration-padding", "lrc", "lrclib"] {
        QQFixtureProtocol.reset(scenario)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [QQFixtureProtocol.self]
        let session = URLSession(configuration: config)
        let service = LyricsService(session: session, qqProvider: QQMusicLyricsProvider(session: session))
        service.load(sourceBundleIdentifier: "com.tencent.QQMusicMac", title: "Fixture", artist: "Artist", duration: scenario == "duration-padding" ? 213 : 10)
        for _ in 0..<100 {
            if !service.lines.isEmpty { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let paths = QQFixtureProtocol.paths()
        if service.lines.isEmpty { failures.append("Fixture \(scenario) pipeline returned no lyrics") }
        let expected = ["qrc", "duration-padding"].contains(scenario) ? ["search", "qrc"] : scenario == "lrc" ? ["search", "qrc", "lrc"] : ["search", "qrc", "lrc", "lrc", "lrclib"]
        if paths != expected { failures.append("Fixture \(scenario) fallback order differs: \(paths)") }
        if scenario != "lrclib", service.currentLyricLine(at: 1.1)?.translation == nil { failures.append("Fixture \(scenario) pipeline lost translation") }
        if scenario == "qrc", service.currentLyricLine(at: 3.1) != nil { failures.append("QRC explicit line ending was not respected") }
        service.load(title: "", artist: "", duration: 0)
        session.invalidateAndCancel()
    }
    failures += await runQQProviderResilienceTests()
    return failures
}

/// Synthetic responses only. Every request is intercepted; no player is read
/// or controlled and no provider endpoint is contacted.
private final class QQResilienceFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var scenario = "normal"
    private static var routes: [String] = []
    private var pending: DispatchWorkItem?
    static func reset(_ value: String) { lock.lock(); scenario = value; routes = []; lock.unlock() }
    static func paths() -> [String] { lock.lock(); defer { lock.unlock() }; return routes }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { pending?.cancel() }
    override func startLoading() {
        let path = request.url?.path ?? ""
        let params = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let payload = params.first { $0.name == "data" }?.value ?? ""
        let isSearch = payload.contains("DoSearchForQQMusicDesktop")
        let legacySearch = path.contains("client_search")
        let route = isSearch ? "search" : legacySearch ? "legacy-search" : path.contains("lyric_download") ? "qrc" : "lrc"
        Self.lock.lock(); let scenario = Self.scenario; Self.routes.append(route); Self.lock.unlock()
        let work = DispatchWorkItem { [weak self] in
            guard let self, pending?.isCancelled != true else { return }
            var status = 200
            var headers = ["Content-Type": "application/json"]
            var response: Data
            if isSearch || legacySearch {
                let titleOnly = (try? JSONSerialization.jsonObject(with: Data(payload.utf8)))
                    .flatMap { $0 as? [String: Any] }
                    .flatMap { $0["req_0"] as? [String: Any] }
                    .flatMap { $0["param"] as? [String: Any] }?["query"] as? String == "Fixture"
                var song: [String: Any] = ["mid": "synthetic", "id": 123, "title": "Fixture", "singer": [["name": "Artist"]], "interval": 10]
                if scenario == "title-only" { song["singer"] = [["name": "Artist"], ["name": "Guest"]] }
                if scenario == "subtitle" { song["subtitle"] = "Another name" }
                if scenario == "mismatch" { song["singer"] = [["name": "Different artist"]] }
                let songs = scenario == "empty" ? [] : [song]
                let node: [String: Any] = legacySearch
                    ? ["code": 0, "data": ["song": ["list": songs]]]
                    : ["code": 0, "req_0": ["code": 0, "data": ["body": ["song": ["list": songs]]]]]
                response = try! JSONSerialization.data(withJSONObject: node)
                if scenario == "service-error" || (scenario == "title-only" && isSearch && !titleOnly) || (scenario == "legacy-recovery" && isSearch) {
                    response = Data((legacySearch ? #"{"code":2001}"# : #"{"code":0,"req_0":{"code":2001}}"#).utf8)
                }
                if scenario == "malformed" { response = Data(#"{"code":0,"req_0":{"code":0,"data":{}}}"#.utf8) }
            } else if route == "qrc" {
                response = Data((scenario == "qrc-empty-lrc-fail" || scenario == "lrc-throttle"
                    ? "<cmd><content></content></cmd>"
                    : "<cmd><content><![CDATA[[1000,2000]Synthetic(1000,2000)]]></content></cmd>").utf8)
                if scenario == "qrc-fail-lrc-ok" || scenario == "all-lyrics-fail" { status = 500 }
                if scenario == "qrc-throttle" { status = 429; headers["Retry-After"] = "2" }
            } else {
                response = try! JSONSerialization.data(withJSONObject: ["code": 0, "lyric": ["code": 0, "data": ["lyric": Data("[00:01]Synthetic fallback".utf8).base64EncodedString()]]])
                if scenario == "all-lyrics-fail" || scenario == "qrc-empty-lrc-fail" { status = 500 }
                if scenario == "lrc-throttle" { status = 503; headers["Retry-After"] = "2" }
            }
            if scenario == "http-error" { status = 500 }
            if scenario == "throttle" { status = 429; headers["Retry-After"] = "2" }
            if scenario == "date-throttle" {
                status = 503
                let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
                headers["Retry-After"] = formatter.string(from: Date().addingTimeInterval(5))
            }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response)
            client?.urlProtocolDidFinishLoading(self)
        }
        pending = work
        DispatchQueue.global().asyncAfter(deadline: .now() + (scenario == "cancel" ? 1 : 0.005), execute: work)
    }
}

@MainActor
private func runQQProviderResilienceTests() async -> [String] {
    var failures: [String] = []
    func check(_ value: Bool, _ message: String) { if !value { failures.append("QQ resilience: " + message) } }
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [QQResilienceFixtureProtocol.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    let provider = QQMusicLyricsProvider(session: session)
    let descriptor = QQTrackDescriptor(sourceBundleIdentifier: "com.tencent.QQMusicMac", title: "Fixture", artist: "Artist", duration: 10)
    for scenario in ["service-error", "malformed", "http-error"] {
        QQResilienceFixtureProtocol.reset(scenario)
        do { _ = try await provider.searchSong(descriptor); check(false, "\(scenario) must throw after all search probes fail") }
        catch { check(QQResilienceFixtureProtocol.paths().count == 4, "\(scenario) keeps a finite two-query/two-endpoint fallback") }
    }
    for scenario in ["empty", "mismatch"] {
        QQResilienceFixtureProtocol.reset(scenario)
        do { let result = try await provider.searchSong(descriptor); check(result == nil, "Verified \(scenario) is a legitimate no-match") }
        catch { check(false, "Verified \(scenario) must not be represented as a service outage") }
    }
    for scenario in ["normal", "title-only", "legacy-recovery", "subtitle", "qrc-fail-lrc-ok"] {
        QQResilienceFixtureProtocol.reset(scenario)
        let target = scenario == "subtitle" ? QQTrackDescriptor(sourceBundleIdentifier: descriptor.sourceBundleIdentifier,
            title: "Fixture (Another name)", artist: "Artist", duration: 10) : descriptor
        do {
            let result = try await provider.fetchWithQRCFallback(for: target)
            check(result?.lines.first?.text.contains("Synthetic") == true, "\(scenario) loads verified synthetic lyrics")
            let paths = QQResilienceFixtureProtocol.paths()
            if scenario == "title-only" { check(paths == ["search", "search", "qrc"], "Rejected combined query can recover through the full title-only query with main-artist metadata") }
            if scenario == "legacy-recovery" { check(paths == ["search", "search", "legacy-search", "qrc"], "A valid legacy search may recover after modern service errors") }
            if scenario == "qrc-fail-lrc-ok" { check(paths == ["search", "qrc", "lrc"] && result?.source == "QQ LRC", "A failed QRC transport does not block a working LRC fallback") }
        } catch { check(false, "\(scenario) unexpectedly failed: \(error)") }
    }
    QQResilienceFixtureProtocol.reset("all-lyrics-fail")
    do { _ = try await provider.fetchWithQRCFallback(for: descriptor); check(false, "All lyric transports failing must throw instead of returning no lyrics") }
    catch { check(QQResilienceFixtureProtocol.paths() == ["search", "qrc", "lrc", "lrc"], "All lyric transports remain bounded") }
    QQResilienceFixtureProtocol.reset("qrc-empty-lrc-fail")
    do {
        let result = try await provider.fetchWithQRCFallback(for: descriptor)
        check(result == nil, "A verified empty QRC is distinguishable from every lyric transport failing")
    } catch { check(false, "An explicit empty QRC should remain a verified no-lyrics result") }
    for scenario in ["throttle", "date-throttle", "qrc-throttle", "lrc-throttle"] {
        QQResilienceFixtureProtocol.reset(scenario)
        do { _ = try await provider.fetchWithQRCFallback(for: descriptor); check(false, "\(scenario) must expose cooldown") }
        catch let error as QQMusicLyricsProvider.RequestError {
            check(error.retryAfter.map { $0.timeIntervalSinceNow > 0 && $0.timeIntervalSinceNow <= 6 } == true, "\(scenario) preserves Retry-After")
            let expected = scenario == "qrc-throttle" ? 2 : scenario == "lrc-throttle" ? 3 : 1
            check(QQResilienceFixtureProtocol.paths().count == expected, "\(scenario) stops further source probes immediately")
        } catch { check(false, "\(scenario) must remain a typed provider throttle") }
    }
    QQResilienceFixtureProtocol.reset("cancel")
    let canceled = Task { try await provider.fetchWithQRCFallback(for: descriptor) }
    for _ in 0..<100 {
        if !QQResilienceFixtureProtocol.paths().isEmpty { break }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    canceled.cancel()
    do { _ = try await canceled.value; check(false, "Cancellation must not become a verified empty result") }
    catch { check(error is CancellationError && QQResilienceFixtureProtocol.paths().count == 1, "Cancellation propagates and sends no additional probes") }
    return failures
}
