import Foundation

// Adapted from the user's QQMusicLyricsProvider.swift, within the authorized QQ feature scope.
// Endpoint shapes come from that integration; these are QQ web endpoints, not a guaranteed public API.
struct QQTrackDescriptor: Sendable {
    let sourceBundleIdentifier: String?
    let title: String
    let artist: String
    let duration: Double

    var acceptsQQ: Bool {
        let source = sourceBundleIdentifier?.lowercased() ?? ""
        return source.isEmpty || source.contains("qqmusic") || source.contains("tencent")
    }
}

final class QQMusicLyricsProvider: @unchecked Sendable {
    struct SongMatch: Equatable, Sendable {
        let songmid: String
        let songID: Int?
        let title: String
        let artists: [String]
        let duration: Double?
    }
    struct Payload: Sendable {
        let lines: [LyricLine]
        let source: String
    }
    enum RequestError: Error { case response, oversized }

    let session: URLSession
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"

    init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 5
            config.timeoutIntervalForResource = 8
            config.httpShouldSetCookies = false
            self.session = URLSession(configuration: config)
        }
    }

    /// Search once so QRC and LRC fallback use the same verified song identity.
    func searchSong(_ descriptor: QQTrackDescriptor) async throws -> SongMatch? {
        for query in Self.queries(descriptor) {
            try Task.checkCancellation()
            let payload: [String: Any] = [
                "comm": Self.commonPayload,
                "req_0": ["method": "DoSearchForQQMusicDesktop", "module": "music.search.SearchCgiService",
                    "param": ["remoteplace": "txt.mqq.all", "searchid": String(Int64.random(in: 10_000_000_000_000_000...99_999_999_999_999_999)),
                              "search_type": 0, "query": query, "page_num": 1, "num_per_page": 20]]
            ]
            do {
                let data = try await data(for: Self.musicuRequest(payload))
                if let match = Self.bestMatch(Self.searchCandidates(data), for: descriptor) { return match }
            } catch { try Task.checkCancellation() }
        }
        for query in Self.queries(descriptor) {
            try Task.checkCancellation()
            var components = URLComponents(string: "https://c.y.qq.com/soso/fcgi-bin/client_search_cp")!
            components.queryItems = ["w": query, "format": "json", "outCharset": "utf-8", "ct": "24", "qqmusic_ver": "1298",
                                    "remoteplace": "txt.yqq.song", "t": "0", "aggr": "1", "cr": "1", "lossless": "0", "flag_qc": "0", "platform": "yqq.json"]
                .map { URLQueryItem(name: $0.key, value: $0.value) }
            do {
                let response = try await data(for: Self.request(url: components.url!))
                if let match = Self.bestMatch(Self.searchCandidates(response), for: descriptor) { return match }
            } catch { try Task.checkCancellation() }
        }
        return nil
    }

    func fetchLyrics(for descriptor: QQTrackDescriptor, match: SongMatch) async throws -> Payload? {
        try Task.checkCancellation()
        let payload: [String: Any] = [
            "comm": Self.commonPayload,
            "lyric": ["method": "GetPlayLyricInfo", "module": "music.musichallSong.PlayLyricInfo",
                      "param": ["songMID": match.songmid, "songID": match.songID ?? 0]]
        ]
        do {
            let response = try await data(for: Self.musicuRequest(payload))
            let lines = Self.parseLyricsResponse(response, duration: descriptor.duration)
            if QQMusicQRCParser.hasUsableLyrics(lines) { return Payload(lines: lines, source: "QQ LRC") }
        } catch { try Task.checkCancellation() }
        try Task.checkCancellation()
        var components = URLComponents(string: "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg")!
        components.queryItems = [URLQueryItem(name: "songmid", value: match.songmid), URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "outCharset", value: "utf-8"), URLQueryItem(name: "platform", value: "yqq.json")]
        do {
            let response = try await data(for: Self.request(url: components.url!))
            let lines = Self.parseLyricsResponse(response, duration: descriptor.duration)
            return QQMusicQRCParser.hasUsableLyrics(lines) ? Payload(lines: lines, source: "QQ LRC") : nil
        } catch { try Task.checkCancellation(); return nil }
    }

    func fetchWithQRCFallback(for descriptor: QQTrackDescriptor) async throws -> Payload? {
        guard descriptor.acceptsQQ else { return nil }
        // Bound all QQ probes together, then allow the caller to try LRCLIB.
        return try await withThrowingTaskGroup(of: Payload?.self) { group in
            group.addTask { [self] in
                guard let match = try await searchSong(descriptor) else { return nil }
                let qrc = QQMusicQRCLyricsProvider(transport: self)
                if let payload = try await qrc.fetchLyrics(for: descriptor, match: match) { return payload }
                try Task.checkCancellation()
                return try await fetchLyrics(for: descriptor, match: match)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 20_000_000_000)
                return nil
            }
            let result = try await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    func data(for request: URLRequest) async throws -> Data {
        try Task.checkCancellation()
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw RequestError.response }
        guard data.count <= 4_000_000 else { throw RequestError.oversized }
        return data
    }

    static func request(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        request.setValue("https://y.qq.com", forHTTPHeaderField: "Origin")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    private static let commonPayload: [String: Any] = ["g_tk": 5381, "uin": "", "format": "json", "inCharset": "utf-8", "outCharset": "utf-8", "notice": 0, "platform": "h5", "needNewCode": 1, "ct": 23, "cv": 0]

    private static func musicuRequest(_ payload: [String: Any]) throws -> URLRequest {
        let data = try JSONSerialization.data(withJSONObject: payload)
        var components = URLComponents(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")!
        components.queryItems = [URLQueryItem(name: "data", value: String(decoding: data, as: UTF8.self))]
        return request(url: components.url!)
    }

    static func searchCandidates(_ data: Data) -> [SongMatch] {
        guard let root = jsonObject(data), number(root["code"]) == 0 else { return [] }
        var entries: [[String: Any]] = []
        if let req = root["req_0"] as? [String: Any], number(req["code"]) == 0,
           let data = req["data"] as? [String: Any], let body = data["body"] as? [String: Any],
           let song = body["song"] as? [String: Any] { entries = song["list"] as? [[String: Any]] ?? [] }
        else if let data = root["data"] as? [String: Any], let song = data["song"] as? [String: Any] {
            entries = song["list"] as? [[String: Any]] ?? []
        }
        return entries.compactMap { entry in
            guard let mid = (entry["mid"] ?? entry["songmid"]) as? String, !mid.isEmpty,
                  let title = (entry["title"] ?? entry["name"] ?? entry["songname"]) as? String else { return nil }
            let artists = (entry["singer"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            return SongMatch(songmid: mid, songID: number(entry["id"] ?? entry["songid"]).flatMap { $0 > 0 && $0 < Double(Int.max) && $0.rounded() == $0 ? Int($0) : nil }, title: title,
                             artists: artists, duration: number(entry["interval"]))
        }
    }

    static func bestMatch(_ candidates: [SongMatch], for descriptor: QQTrackDescriptor) -> SongMatch? {
        let title = normalize(descriptor.title)
        let artist = normalize(descriptor.artist)
        guard !title.isEmpty, !artist.isEmpty else { return nil }
        let matching = candidates.filter { song in
            guard normalize(song.title) == title else { return false }
            guard song.artists.contains(where: { normalize($0) == artist }) || normalize(song.artists.joined()) == artist else { return false }
            if descriptor.duration > 0, let seconds = song.duration, abs(seconds - descriptor.duration) > 3 { return false }
            return true
        }
        if descriptor.duration <= 0 { return matching.first(where: { $0.songID != nil }) ?? matching.first }
        return matching.min { left, right in
            let lhs = left.duration.map { abs($0 - descriptor.duration) } ?? .greatestFiniteMagnitude
            let rhs = right.duration.map { abs($0 - descriptor.duration) } ?? .greatestFiniteMagnitude
            if lhs == rhs { return left.songID != nil && right.songID == nil }
            return lhs < rhs
        }
    }

    static func parseLyricsResponse(_ data: Data, duration: Double) -> [LyricLine] {
        guard let root = jsonObject(data) else { return [] }
        var node = root
        if let lyric = root["lyric"] as? [String: Any] {
            guard number(root["code"]) == 0, number(lyric["code"]) == 0,
                  let nested = lyric["data"] as? [String: Any] else { return [] }
            node = nested
        } else {
            guard number(root["retcode"] ?? root["code"] ?? root["subcode"]) == 0 else { return [] }
        }
        func decode(_ value: Any?) -> String? {
            guard let value = value as? String, !value.isEmpty else { return nil }
            if let data = Data(base64Encoded: value), let decoded = String(data: data, encoding: .utf8) { return decoded }
            return value.contains("[") ? value : nil
        }
        guard let original = decode(node["lyric"]) else { return [] }
        let parsed = QQMusicQRCParser.parse(qrcContent: original, translationContent: decode(node["trans"]), duration: duration > 0 ? duration : nil)
        return QQMusicQRCParser.applyTranslations(parsed.lines, translations: parsed.translations)
    }

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        var input = data
        if let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           value.first != "{", let open = value.firstIndex(of: "("), let close = value.lastIndex(of: ")"), open < close {
            input = Data(value[value.index(after: open)..<close].utf8)
        }
        return (try? JSONSerialization.jsonObject(with: input)) as? [String: Any]
    }

    private static func number(_ value: Any?) -> Double? {
        let number = (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
        return number.flatMap { $0.isFinite ? $0 : nil }
    }
    private static func normalize(_ value: String) -> String {
        let simplified = value.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? value
        return simplified.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
    private static func queries(_ descriptor: QQTrackDescriptor) -> [String] {
        let value = "\(descriptor.artist) \(descriptor.title)"
        let simplified = value.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? value
        return simplified == value ? [value] : [simplified, value]
    }
}
