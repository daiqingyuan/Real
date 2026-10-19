import Foundation

/// Anonymous compatibility with NetEase's own website endpoints. These endpoints
/// are not a documented, guaranteed public API or a grant of lyric usage rights.
/// No account, cookies, player database, or encrypted request emulation is used.
final class NeteaseLyricsProvider: @unchecked Sendable {
    struct Payload: Sendable {
        let lines: [LyricLine]
        let source: String
    }

    private struct SearchResponse: Decodable {
        struct Result: Decodable { let songs: [Song]? }
        let code: Int
        let result: Result?
    }
    private struct Song: Decodable {
        struct Artist: Decodable { let name: String }
        struct Album: Decodable { let name: String }
        let id: Int64
        let name: String
        let artists: [Artist]
        let duration: Double?
        let album: Album?
    }
    private struct LyricsResponse: Decodable {
        struct Text: Decodable { let lyric: String? }
        let code: Int
        let lrc: Text?
        let tlyric: Text?
        let nolyric: Bool?
        let uncollected: Bool?
    }

    enum RequestError: Error {
        case response, oversized
        case http(Int)
        case service(Int)
        case throttled(until: Date)

        /// A provider failure is not evidence that a song has no lyrics. The
        /// caller can keep transient failures out of its negative cache and
        /// apply this provider-wide deadline before trying a different track.
        var retryAfter: Date? {
            if case let .throttled(until) = self { return until }
            return nil
        }
    }
    private let session: URLSession
    private static let maximumBytes = 2_000_000

    init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 5
            configuration.timeoutIntervalForResource = 8
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration)
        }
    }

    /// The optional album disambiguates reissues when the local player provides
    /// it. Missing album is allowed only when title/artists/duration identify one
    /// catalog ID; an arbitrary first search result must never select the lyrics.
    func fetch(for descriptor: QQTrackDescriptor, album: String? = nil) async throws -> Payload? {
        guard descriptor.sourceBundleIdentifier?.lowercased() == "com.netease.163music",
              !Self.normalized(descriptor.title).isEmpty,
              !Self.normalized(descriptor.artist).isEmpty else { return nil }
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: Payload?.self) { group in
            group.addTask { [self] in try await fetchMatchingLyrics(for: descriptor, album: album) }
            group.addTask {
                try await Task.sleep(nanoseconds: 12_000_000_000)
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
    }

    private func fetchMatchingLyrics(for descriptor: QQTrackDescriptor, album: String?) async throws -> Payload? {
        let search = Self.request(path: "/api/search/get", query: [
            URLQueryItem(name: "s", value: "\(descriptor.artist) \(descriptor.title)"),
            URLQueryItem(name: "type", value: "1"), URLQueryItem(name: "limit", value: "30"),
            URLQueryItem(name: "offset", value: "0")
        ])
        let result = try JSONDecoder().decode(SearchResponse.self, from: try await data(for: search))
        try Task.checkCancellation()
        guard result.code == 200 else { throw RequestError.service(result.code) }
        guard let searchResult = result.result else { throw RequestError.response }
        let knownDuration = descriptor.duration.isFinite && descriptor.duration > 0 ? descriptor.duration : nil
        let albumKey = album.map(Self.normalized).flatMap { $0.isEmpty ? nil : $0 }
        let matches = (searchResult.songs ?? []).filter { song in
            guard song.id > 0, Self.normalized(song.name) == Self.normalized(descriptor.title),
                  Self.artistsMatch(song.artists.map(\.name), descriptor.artist) else { return false }
            if let albumKey, song.album.map({ Self.normalized($0.name) }) != albumKey { return false }
            if let knownDuration {
                guard let milliseconds = song.duration, milliseconds.isFinite, milliseconds > 0,
                      abs(milliseconds / 1000 - knownDuration) <= 2 else { return false }
            }
            return true
        }
        // Some searches repeat the same ID. Different IDs, even close-duration
        // reissues, remain ambiguous unless the player's album made one unique.
        guard let match = matches.first, Set(matches.map(\.id)).count == 1 else { return nil }
        try Task.checkCancellation()
        let request = Self.request(path: "/api/song/lyric", query: [
            URLQueryItem(name: "id", value: String(match.id)), URLQueryItem(name: "lv", value: "-1"),
            URLQueryItem(name: "kv", value: "-1"), URLQueryItem(name: "tv", value: "-1")
        ])
        let lyric = try JSONDecoder().decode(LyricsResponse.self, from: try await data(for: request))
        try Task.checkCancellation()
        guard lyric.code == 200 else { throw RequestError.service(lyric.code) }
        if lyric.nolyric == true { return Payload(lines: [], source: "NetEase instrumental") }
        guard lyric.uncollected != true else { return nil }
        guard let originalText = lyric.lrc?.lyric else { throw RequestError.response }
        let duration = knownDuration ?? match.duration.flatMap { $0.isFinite && $0 > 0 ? $0 / 1000 : nil }
        let originals = LRCParser.parse(originalText, duration: duration)
            .filter { $0.time.isFinite && $0.time >= 0 && (duration == nil || $0.time <= duration! + 2) }
        let nonempty = originals.map { line in
            Self.normalized(line.text).unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
        }.filter { !$0.isEmpty }
        guard !nonempty.isEmpty else { return nil }
        let instrumentalNotices = ["纯音乐请欣赏", "纯音乐请您欣赏", "此歌曲为没有填词的纯音乐请您欣赏"]
        if nonempty.allSatisfy({ instrumentalNotices.contains($0) }) {
            return Payload(lines: [], source: "NetEase instrumental")
        }
        let translations = LRCParser.parse(lyric.tlyric?.lyric ?? "", duration: duration)
        let merged = originals.map { line -> LyricLine in
            // Timestamp matching, never row position: translations can omit
            // credits, blank lines, or entire passages from the original LRC.
            let nearby = translations.filter { abs($0.time - line.time) <= 0.2 && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let sorted = nearby.sorted { abs($0.time - line.time) < abs($1.time - line.time) }
            let translation = sorted.first.flatMap { nearest -> String? in
                if sorted.count > 1, abs(abs(sorted[1].time - line.time) - abs(nearest.time - line.time)) < 0.001 { return nil }
                return nearest.text == line.text ? nil : nearest.text
            }
            return LyricLine(id: line.id, time: line.time, text: line.text, translation: translation, endTime: line.endTime)
        }
        try Task.checkCancellation()
        return Payload(lines: merged, source: "NetEase LRC")
    }

    private func data(for request: URLRequest) async throws -> Data {
        try Task.checkCancellation()
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse,
              http.url?.scheme == "https", http.url?.host?.lowercased() == "music.163.com" else { throw RequestError.response }
        if http.statusCode == 429 || http.statusCode == 503 {
            throw RequestError.throttled(until: Self.retryDeadline(http.value(forHTTPHeaderField: "Retry-After")))
        }
        guard http.statusCode == 200 else { throw RequestError.http(http.statusCode) }
        guard http.mimeType?.lowercased().contains("json") == true else { throw RequestError.response }
        guard response.expectedContentLength <= Int64(Self.maximumBytes) else { throw RequestError.oversized }
        var data = Data()
        if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
        for try await byte in bytes {
            guard data.count < Self.maximumBytes else { throw RequestError.oversized }
            data.append(byte)
            if data.count.isMultiple(of: 16_384) { try Task.checkCancellation() }
        }
        try Task.checkCancellation()
        return data
    }

    private static func retryDeadline(_ header: String?, now: Date = Date()) -> Date {
        let value = header?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let earliest = now.addingTimeInterval(1)
        if let seconds = Double(value), seconds.isFinite, seconds >= 0 {
            // Preserve long server deadlines without creating an infinite Date
            // from malformed/extreme numeric input.
            let available = max(1, Date.distantFuture.timeIntervalSince(now))
            return now.addingTimeInterval(min(available, max(1, seconds)))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        for format in ["EEE, dd MMM yyyy HH:mm:ss z", "EEEE, dd-MMM-yy HH:mm:ss z", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return max(earliest, date) }
        }
        return now.addingTimeInterval(60)
    }

    private static func request(path: String, query: [URLQueryItem]) -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"; components.host = "music.163.com"; components.path = path; components.queryItems = query
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Real/1.0.0", forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        return request
    }

    private static func artistsMatch(_ names: [String], _ metadata: String) -> Bool {
        let artists = Set(names.map(normalized).filter { !$0.isEmpty })
        guard !artists.isEmpty else { return false }
        if artists.count == 1 { return artists.first == normalized(metadata) }
        let separator = #"\s+(?:and|feat\.?|ft\.?|featuring|x|×)\s+|[/／;；、,&，]"#
        let regex = try! NSRegularExpression(pattern: separator, options: [.caseInsensitive])
        let split = regex.stringByReplacingMatches(in: metadata, range: NSRange(metadata.startIndex..., in: metadata), withTemplate: "\n")
        let reported = Set(split.components(separatedBy: "\n").map(normalized).filter { !$0.isEmpty })
        return reported == artists
    }

    private static func normalized(_ value: String) -> String {
        let simplified = value.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? value
        return simplified.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            // Preserve title punctuation: A+B and AB can be distinct songs.
            // Whitespace/case/width variation does not identify a new recording.
            .unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(String.init).joined()
    }
}
