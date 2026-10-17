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
            data = Data((scenario == "qrc" ? "<cmd><content><![CDATA[[1000,2000]Fixture(1000,2000)]]></content><contentts><![CDATA[[00:01]Translation]]></contentts></cmd>" : "<cmd><content></content></cmd>").utf8)
        } else {
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "data" })?.value ?? ""
            if query.contains("DoSearchForQQMusicDesktop") {
                route = "search"
                data = Data(#"{"code":0,"req_0":{"code":0,"data":{"body":{"song":{"list":[{"mid":"fixture","id":123,"title":"Fixture","singer":[{"name":"Artist"}],"interval":10}]}}}}}"#.utf8)
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
    for scenario in ["qrc", "lrc", "lrclib"] {
        QQFixtureProtocol.reset(scenario)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [QQFixtureProtocol.self]
        let session = URLSession(configuration: config)
        let service = LyricsService(session: session, qqProvider: QQMusicLyricsProvider(session: session))
        service.load(sourceBundleIdentifier: "com.tencent.QQMusicMac", title: "Fixture", artist: "Artist", duration: 10)
        for _ in 0..<100 {
            if !service.lines.isEmpty { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let paths = QQFixtureProtocol.paths()
        if service.lines.isEmpty { failures.append("Fixture \(scenario) pipeline returned no lyrics") }
        let expected = scenario == "qrc" ? ["search", "qrc"] : scenario == "lrc" ? ["search", "qrc", "lrc"] : ["search", "qrc", "lrc", "lrc", "lrclib"]
        if paths != expected { failures.append("Fixture \(scenario) fallback order differs: \(paths)") }
        if scenario != "lrclib", service.currentLyricLine(at: 1.1)?.translation == nil { failures.append("Fixture \(scenario) pipeline lost translation") }
        if scenario == "qrc", service.currentLyricLine(at: 3.1) != nil { failures.append("QRC explicit line ending was not respected") }
        service.load(title: "", artist: "", duration: 0)
        session.invalidateAndCancel()
    }
    return failures
}
