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
        let subtitle: String
        let alternateTitles: [String]

        init(songmid: String, songID: Int?, title: String, artists: [String], duration: Double?,
             subtitle: String = "", alternateTitles: [String] = []) {
            self.songmid = songmid; self.songID = songID; self.title = title
            self.artists = artists; self.duration = duration
            self.subtitle = subtitle; self.alternateTitles = alternateTitles
        }
    }
    struct Payload: Sendable {
        let lines: [LyricLine]
        let source: String
    }
    enum RequestError: Error {
        case response, oversized, http(Int), service(Int), throttled(until: Date)
        var retryAfter: Date? {
            if case .throttled(let deadline) = self { return deadline }
            return nil
        }
    }

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
        var verifiedResponses = 0
        var lastError: Error = RequestError.response
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
                let candidates = try Self.validatedSearchCandidates(data)
                verifiedResponses += 1
                if let match = Self.bestMatch(candidates, for: descriptor) { return match }
            } catch { try Self.propagateCancellationOrThrottle(error); lastError = error }
        }
        for query in Self.queries(descriptor) {
            try Task.checkCancellation()
            var components = URLComponents(string: "https://c.y.qq.com/soso/fcgi-bin/client_search_cp")!
            components.queryItems = ["w": query, "format": "json", "outCharset": "utf-8", "ct": "24", "qqmusic_ver": "1298",
                                    "remoteplace": "txt.yqq.song", "t": "0", "aggr": "1", "cr": "1", "lossless": "0", "flag_qc": "0", "platform": "yqq.json"]
                .map { URLQueryItem(name: $0.key, value: $0.value) }
            do {
                let response = try await data(for: Self.request(url: components.url!))
                let candidates = try Self.validatedSearchCandidates(response)
                verifiedResponses += 1
                if let match = Self.bestMatch(candidates, for: descriptor) { return match }
            } catch { try Self.propagateCancellationOrThrottle(error); lastError = error }
        }
        if verifiedResponses == 0 { throw lastError }
        return nil
    }

    func fetchLyrics(for descriptor: QQTrackDescriptor, match: SongMatch) async throws -> Payload? {
        try Task.checkCancellation()
        var verifiedResponses = 0
        var lastError: Error = RequestError.response
        let payload: [String: Any] = [
            "comm": Self.commonPayload,
            "lyric": ["method": "GetPlayLyricInfo", "module": "music.musichallSong.PlayLyricInfo",
                      "param": ["songMID": match.songmid, "songID": match.songID ?? 0]]
        ]
        do {
            let response = try await data(for: Self.musicuRequest(payload))
            let lines = try Self.validatedLyricsResponse(response, duration: descriptor.duration)
            verifiedResponses += 1
            if QQMusicQRCParser.hasUsableLyrics(lines) { return Payload(lines: lines, source: "QQ LRC") }
        } catch { try Self.propagateCancellationOrThrottle(error); lastError = error }
        try Task.checkCancellation()
        var components = URLComponents(string: "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg")!
        components.queryItems = [URLQueryItem(name: "songmid", value: match.songmid), URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "outCharset", value: "utf-8"), URLQueryItem(name: "platform", value: "yqq.json")]
        do {
            let response = try await data(for: Self.request(url: components.url!))
            let lines = try Self.validatedLyricsResponse(response, duration: descriptor.duration)
            verifiedResponses += 1
            return QQMusicQRCParser.hasUsableLyrics(lines) ? Payload(lines: lines, source: "QQ LRC") : nil
        } catch { try Self.propagateCancellationOrThrottle(error); lastError = error }
        if verifiedResponses == 0 { throw lastError }
        return nil
    }

    func fetchWithQRCFallback(for descriptor: QQTrackDescriptor) async throws -> Payload? {
        guard descriptor.acceptsQQ else { return nil }
        // Bound all QQ probes together, then allow the caller to try LRCLIB.
        return try await withThrowingTaskGroup(of: Payload?.self) { group in
            group.addTask { [self] in
                guard let match = try await searchSong(descriptor) else { return nil }
                var verifiedQRCResponse = false
                if let id = match.songID, id > 0 {
                    do {
                        let qrc = QQMusicQRCLyricsProvider(transport: self)
                        if let payload = try await qrc.fetchLyrics(for: descriptor, match: match) { return payload }
                        verifiedQRCResponse = true
                    } catch { try Self.propagateCancellationOrThrottle(error) }
                }
                try Task.checkCancellation()
                do { return try await fetchLyrics(for: descriptor, match: match) }
                catch {
                    try Self.propagateCancellationOrThrottle(error)
                    if verifiedQRCResponse { return nil }
                    throw error
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 20_000_000_000)
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
    }

    func data(for request: URLRequest) async throws -> Data {
        try Task.checkCancellation()
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw RequestError.response }
        if [429, 503].contains(http.statusCode) {
            let raw = http.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
            let deadline = Double(raw).flatMap { $0.isFinite ? Date().addingTimeInterval(max(1, $0)) : nil }
                ?? formatter.date(from: raw) ?? Date().addingTimeInterval(60)
            throw RequestError.throttled(until: max(Date().addingTimeInterval(1), deadline))
        }
        guard http.statusCode == 200 else { throw RequestError.http(http.statusCode) }
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
        (try? validatedSearchCandidates(data)) ?? []
    }

    /// A service error or missing schema is not proof that a song has no lyrics.
    static func validatedSearchCandidates(_ data: Data) throws -> [SongMatch] {
        guard let root = jsonObject(data) else { throw RequestError.response }
        try validateCode(root["code"])
        let entries: [[String: Any]]
        if let req = root["req_0"] as? [String: Any] {
            try validateCode(req["code"])
            guard let data = req["data"] as? [String: Any], let body = data["body"] as? [String: Any],
                  let song = body["song"] as? [String: Any], let list = song["list"] as? [[String: Any]] else { throw RequestError.response }
            entries = list
        } else {
            guard let data = root["data"] as? [String: Any], let song = data["song"] as? [String: Any],
                  let list = song["list"] as? [[String: Any]] else { throw RequestError.response }
            entries = list
        }
        return try entries.map { entry in
            guard let mid = (entry["mid"] ?? entry["songmid"]) as? String, !mid.isEmpty,
                  let title = (entry["title"] ?? entry["name"] ?? entry["songname"]) as? String, !title.isEmpty,
                  let singers = entry["singer"] as? [[String: Any]] else { throw RequestError.response }
            let artists = singers.compactMap { $0["name"] as? String }
            guard artists.count == singers.count else { throw RequestError.response }
            return SongMatch(songmid: mid, songID: number(entry["id"] ?? entry["songid"]).flatMap { $0 > 0 && $0 < Double(Int.max) && $0.rounded() == $0 ? Int($0) : nil }, title: title,
                             artists: artists, duration: number(entry["interval"]), subtitle: entry["subtitle"] as? String ?? "",
                             alternateTitles: [entry["name"], entry["songname"]].compactMap { $0 as? String }.filter { !$0.isEmpty && $0 != title })
        }
    }

    static func bestMatch(_ candidates: [SongMatch], for descriptor: QQTrackDescriptor) -> SongMatch? {
        let title = normalize(descriptor.title)
        let artist = normalize(descriptor.artist)
        guard !title.isEmpty, !artist.isEmpty, descriptor.duration.isFinite else { return nil }
        let identities = candidates.filter { song in
            guard normalize(song.title) == title else { return false }
            // A catalog's explicit edition must not vanish just because its
            // title and subtitle are stored in separate fields.
            if !versionTerms(song.subtitle).isSubset(of: versionTerms(descriptor.title)) { return false }
            guard song.artists.contains(where: { normalize($0) == artist }) || normalize(song.artists.joined()) == artist else { return false }
            return true
        }
        if descriptor.duration <= 0, let unknownDurationMatch = identities.first(where: { $0.songID != nil }) ?? identities.first { return unknownDurationMatch }
        let matching = identities.filter { song in
            guard let seconds = song.duration else { return true }
            return seconds.isFinite && seconds > 0 && abs(seconds - descriptor.duration) <= 3
        }
        if let standard = matching.min(by: { left, right in
            let lhs = left.duration.map { abs($0 - descriptor.duration) } ?? .greatestFiniteMagnitude
            let rhs = right.duration.map { abs($0 - descriptor.duration) } ?? .greatestFiniteMagnitude
            if lhs == rhs { return left.songID != nil && right.songID == nil }
            return lhs < rhs
        }) { return standard }

        // The desktop player and catalog can differ by a few seconds of padding.
        // Extend the time allowance only for one unambiguous, complete artist
        // identity. Count identities BEFORE filtering by time so a second version
        // cannot disappear merely because its duration is further away.
        if let padded = uniqueMatch(identities, descriptor: descriptor, artist: artist) { return padded }

        // Alias matching is based only on explicit catalog fields. Never turn
        // an arbitrary "Song (Live)" into "Song" by deleting parentheses.
        let displayTitle = displayTitleKey(descriptor.title)
        let aliases = candidates.filter { song in
            guard song.artists.count == 1, normalize(song.artists[0]) == artist else { return false }
            let versions = versionTerms(song.title).union(versionTerms(song.subtitle))
            guard versions.isSubset(of: versionTerms(descriptor.title)) else { return false }
            let subtitle = song.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let wrapped = (subtitle.hasPrefix("(") && subtitle.hasSuffix(")")) || (subtitle.hasPrefix("（") && subtitle.hasSuffix("）"))
            // A secondary name may add display text, but must not erase ANY
            // part of the canonical title (including unknown edition suffixes).
            let namedAliases = song.alternateTitles.filter { displayTitleKey($0).contains(displayTitleKey(song.title)) }
            let declared = namedAliases + (subtitle.isEmpty ? [] : [song.title + " " + (wrapped ? subtitle : "(" + subtitle + ")")])
            return declared.contains { displayTitleKey($0) == displayTitle }
        }
        return uniqueMatch(identities + aliases, descriptor: descriptor, artist: artist)
    }

    private static func uniqueMatch(_ songs: [SongMatch], descriptor: QQTrackDescriptor, artist: String) -> SongMatch? {
        guard !songs.isEmpty, Set(songs.map(\.songmid)).count == 1,
              Set(songs.compactMap(\.songID)).count <= 1,
              songs.allSatisfy({ !$0.songmid.isEmpty && $0.artists.count == 1 && normalize($0.artists[0]) == artist }) else { return nil }
        if descriptor.duration <= 0 { return songs.first(where: { $0.songID != nil }) ?? songs.first }
        let durations = songs.compactMap(\.duration)
        guard durations.count == songs.count, Set(durations).count == 1,
              let seconds = durations.first, seconds.isFinite, seconds > 0,
              abs(seconds - descriptor.duration) <= min(6, max(3, descriptor.duration * 0.025)) else { return nil }
        return songs.first(where: { $0.songID != nil }) ?? songs.first
    }

    private static func displayTitleKey(_ text: String) -> String {
        let simplified = text.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? text
        return simplified.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(String.init).joined()
    }

    private static func versionTerms(_ text: String) -> Set<String> {
        let folded = displayTitleKey(text)
        var result = Set(["现场", "混音", "翻唱", "伴奏", "不插电", "清唱", "加速", "降速", "重制", "重录"].filter(folded.contains))
        let words = text.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let regex = try! NSRegularExpression(pattern: #"\b(live|remix|cover|acoustic|instrumental|karaoke|demo|remaster(?:ed)?|version|edit)\b"#)
        let ns = words as NSString
        for match in regex.matches(in: words, range: NSRange(location: 0, length: ns.length)) {
            let term = ns.substring(with: match.range)
            result.insert(term == "remastered" ? "remaster" : term)
        }
        return result
    }

    static func parseLyricsResponse(_ data: Data, duration: Double) -> [LyricLine] {
        (try? validatedLyricsResponse(data, duration: duration)) ?? []
    }

    static func validatedLyricsResponse(_ data: Data, duration: Double) throws -> [LyricLine] {
        guard let root = jsonObject(data) else { throw RequestError.response }
        var node = root
        if let lyric = root["lyric"] as? [String: Any] {
            try validateCode(root["code"])
            try validateCode(lyric["code"])
            guard let nested = lyric["data"] as? [String: Any] else { throw RequestError.response }
            node = nested
        } else {
            try validateCode(root["retcode"] ?? root["code"] ?? root["subcode"])
        }
        func decode(_ value: Any?) -> String? {
            guard let value = value as? String, !value.isEmpty else { return nil }
            if let data = Data(base64Encoded: value), let decoded = String(data: data, encoding: .utf8) { return decoded }
            return value.contains("[") ? value : nil
        }
        guard let raw = node["lyric"] as? String else { throw RequestError.response }
        if raw.isEmpty { return [] }
        guard let original = decode(raw) else { throw RequestError.response }
        let parsed = QQMusicQRCParser.parse(qrcContent: original, translationContent: decode(node["trans"]), duration: duration > 0 ? duration : nil)
        return QQMusicQRCParser.applyTranslations(parsed.lines, translations: parsed.translations)
    }

    private static func validateCode(_ value: Any?) throws {
        guard let code = number(value), code.rounded() == code,
              code > Double(Int.min), code < Double(Int.max) else { throw RequestError.response }
        guard code == 0 else { throw RequestError.service(Int(code)) }
    }

    static func propagateCancellationOrThrottle(_ error: Error) throws {
        try Task.checkCancellation()
        if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
        if let requestError = error as? RequestError, requestError.retryAfter != nil { throw requestError }
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
        var seen = Set<String>()
        return ["\(descriptor.artist) \(descriptor.title)", descriptor.title].map {
            ($0.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? $0)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
