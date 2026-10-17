import Foundation
import Combine
import NaturalLanguage

/// Original line-level LRC reader. Metadata is ignored; offsets apply to every timestamp.
enum LRCParser {
    static func parse(_ input: String, duration: Double? = nil) -> [LyricLine] {
        let rows = input.components(separatedBy: .newlines)
        let offsetPattern = try! NSRegularExpression(pattern: #"(?i)\[offset:\s*([+-]?\d+)\s*\]"#)
        let timePattern = try! NSRegularExpression(pattern: #"\[(\d+):(\d{2})(?:[.:](\d{1,3}))?\]"#)
        var offset = 0.0
        for row in rows {
            let ns = row as NSString
            if let match = offsetPattern.firstMatch(in: row, range: NSRange(location: 0, length: ns.length)),
               let value = Double(ns.substring(with: match.range(at: 1))) {
                offset = value / 1000
            }
        }
        var entries: [(Double, String, Int)] = []
        for row in rows {
            let ns = row as NSString
            let matches = timePattern.matches(in: row, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            let text = ns.substring(from: NSMaxRange(last.range)).trimmingCharacters(in: .whitespaces)
            for match in matches {
                guard let minutes = Double(ns.substring(with: match.range(at: 1))),
                      let seconds = Double(ns.substring(with: match.range(at: 2))), seconds < 60 else { continue }
                let fractionRange = match.range(at: 3)
                let fraction = fractionRange.location == NSNotFound ? 0 : (Double("0." + ns.substring(with: fractionRange)) ?? 0)
                let time = minutes * 60 + seconds + fraction + offset
                guard time.isFinite else { continue }
                entries.append((max(0, time), text, entries.count))
            }
        }
        entries.sort { $0.0 == $1.0 ? $0.2 < $1.2 : $0.0 < $1.0 }
        return entries.enumerated().map { index, entry in
            let end = index + 1 < entries.count ? entries[index + 1].0 : duration.flatMap { $0.isFinite && $0 > entry.0 ? $0 : nil }
            return LyricLine(id: index, time: entry.0, text: entry.1, endTime: end)
        }
    }
}

@MainActor
final class LyricsService: ObservableObject {
    @Published private(set) var lines: [LyricLine] = [] {
        didSet { isEnglish = LyricLanguagePolicy.isEnglish(lines.map(\.text)) }
    }
    @Published private(set) var isEnglish = false
    @Published private(set) var status = tr("等待音乐播放")
    @Published private(set) var availability: LyricsAvailability = .waiting
    @Published private(set) var trackKey = ""

    private struct Record: Decodable {
        let trackName: String
        let artistName: String
        let duration: Double
        let instrumental: Bool
        let syncedLyrics: String?
        let plainLyrics: String?
    }
    private struct Cached {
        let lines: [LyricLine]
        let status: String
        var availability: LyricsAvailability {
            lines.isEmpty ? (status.hasPrefix("纯音乐") ? .instrumental : .unavailable) : .ready
        }
    }
    private struct ActiveRequest {
        let descriptor: QQTrackDescriptor
        let album: String
        let cacheKey: String
    }
    private var cache: [String: Cached] = [:]
    private var cacheOrder: [String] = []
    private var task: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var retryKey: String?
    private var retryCount = 0
    private let retryDelays: [TimeInterval]
    private var generation = UUID()
    private var activeKey: String?
    private var retryAfter = Date.distantPast
    private var currentRequest: ActiveRequest?
    private let session: URLSession
    private let qqProvider: QQMusicLyricsProvider
    private let neteaseProvider: NeteaseLyricsProvider

    init(session: URLSession? = nil, qqProvider: QQMusicLyricsProvider? = nil,
         neteaseProvider: NeteaseLyricsProvider? = nil,
         retryDelays: [TimeInterval] = [2, 5, 15]) {
        self.retryDelays = retryDelays.filter { $0.isFinite && $0 >= 0 }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        self.session = session ?? URLSession(configuration: configuration)
        self.qqProvider = qqProvider ?? QQMusicLyricsProvider()
        self.neteaseProvider = neteaseProvider ?? NeteaseLyricsProvider()
    }

    func load(sourceBundleIdentifier: String? = nil, title: String, artist: String, duration: Double, album: String = "") {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let album = album.trimmingCharacters(in: .whitespacesAndNewlines)
        let duration = duration.isFinite ? max(0, duration) : 0
        let key = "\(sourceBundleIdentifier ?? "")\u{0}\(title)\u{0}\(artist)\u{0}\(duration.rounded())\u{0}\(album)"
        guard activeKey != key else { return }
        task?.cancel()
        retryTask?.cancel(); retryTask = nil
        if retryKey != key { retryKey = key; retryCount = 0 }
        generation = UUID()
        let requestGeneration = generation
        activeKey = key
        trackKey = LyricDisplayPolicy.trackKey(sourceBundleIdentifier: sourceBundleIdentifier, title: title, artist: artist)
        lines = []
        guard !title.isEmpty, !artist.isEmpty else {
            currentRequest = nil; availability = .waiting
            status = tr("等待曲目信息")
            return
        }
        let descriptor = QQTrackDescriptor(sourceBundleIdentifier: sourceBundleIdentifier, title: title, artist: artist, duration: duration)
        currentRequest = ActiveRequest(descriptor: descriptor, album: album, cacheKey: key)
        if let cached = cache[key] {
            lines = cached.lines
            availability = cached.availability
            status = tr(cached.status)
            return
        }
        availability = .loading
        status = tr("正在查找歌词…")
        task = Task { [weak self] in
            guard let self else { return }
            do {
                // Debounce rapid track changes and keep requests modest.
                try await Task.sleep(nanoseconds: 350_000_000)
                if sourceBundleIdentifier == "com.netease.163music" {
                    status = tr("正在查找网易云音乐歌词…")
                    do {
                        if let payload = try await neteaseProvider.fetch(for: descriptor, album: album) {
                            try Task.checkCancellation()
                            guard generation == requestGeneration else { return }
                            let result = Cached(lines: payload.lines, status: payload.source == "NetEase instrumental"
                                ? "纯音乐 · 网易云音乐" : "同步歌词 · 网易云音乐")
                            lines = result.lines; availability = result.availability; status = tr(result.status)
                            cache[key] = result; cacheOrder.append(key)
                            if cacheOrder.count > 64 { cache.removeValue(forKey: cacheOrder.removeFirst()) }
                            return
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch { try Task.checkCancellation() }
                    guard generation == requestGeneration else { return }
                }
                if descriptor.acceptsQQ {
                    status = tr("正在查找 QQ 音乐歌词…")
                    if let payload = try await qqProvider.fetchWithQRCFallback(for: descriptor) {
                        try Task.checkCancellation()
                        guard generation == requestGeneration else { return }
                        let result = Cached(lines: payload.lines, status: payload.source == "QQ QRC" ? "同步歌词 · QQ QRC" : "同步歌词 · QQ LRC")
                        lines = result.lines
                        availability = result.availability
                        status = tr(result.status)
                        cache[key] = result
                        cacheOrder.append(key)
                        if cacheOrder.count > 64 { cache.removeValue(forKey: cacheOrder.removeFirst()) }
                        return
                    }
                    try Task.checkCancellation()
                    guard generation == requestGeneration else { return }
                }
                guard Date() >= retryAfter else {
                    availability = .coolingDown
                    status = tr("歌词服务繁忙，请稍后切换曲目重试。")
                    scheduleRetry(descriptor, album: album, key: key, generation: requestGeneration, notBefore: retryAfter)
                    return
                }
                status = tr("正在查找歌词…")
                var components = URLComponents(string: "https://lrclib.net/api/search")!
                components.queryItems = [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)]
                var request = URLRequest(url: components.url!)
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                // Supply a real project/contact through bundle metadata when distributing.
                let contact = (Bundle.main.object(forInfoDictionaryKey: "LRCLIBClientContact") as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let contactSuffix = contact.flatMap { $0.isEmpty ? nil : " (\($0))" } ?? ""
                request.setValue("real/1.0.0" + contactSuffix, forHTTPHeaderField: "User-Agent")
                let (data, response) = try await session.data(for: request)
                try Task.checkCancellation()
                guard generation == requestGeneration else { return }
                guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                if response.statusCode == 429 || response.statusCode == 503 {
                    let header = response.value(forHTTPHeaderField: "Retry-After") ?? ""
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.timeZone = TimeZone(secondsFromGMT: 0)
                    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
                    retryAfter = Double(header).flatMap { $0.isFinite ? Date().addingTimeInterval(max(1, $0)) : nil }
                        ?? formatter.date(from: header) ?? Date().addingTimeInterval(60)
                    availability = .coolingDown
                    status = tr("歌词服务繁忙，请稍后重试。")
                    scheduleRetry(descriptor, album: album, key: key, generation: requestGeneration, notBefore: retryAfter)
                    return
                }
                guard response.statusCode == 200 else {
                    availability = [500, 502, 504].contains(response.statusCode) ? .temporaryFailure : .unavailable
                    status = String(format: tr("歌词不可用（HTTP %@）"), String(response.statusCode))
                    if [500, 502, 504].contains(response.statusCode) {
                        scheduleRetry(descriptor, album: album, key: key, generation: requestGeneration)
                    } else { activeKey = nil }
                    return
                }
                guard response.mimeType?.contains("json") == true, data.count <= 4_000_000 else {
                    throw URLError(.cannotParseResponse)
                }
                let records = try JSONDecoder().decode([Record].self, from: data)
                let candidates = records.filter {
                    Self.normalized($0.trackName) == Self.normalized(title)
                    && Self.normalized($0.artistName) == Self.normalized(artist)
                    && (duration == 0 || abs($0.duration - duration) <= 2)
                }.enumerated().sorted {
                    // Unknown player duration is not a zero-second song. Do not
                    // accidentally choose the shortest catalog version.
                    let leftDistance = duration > 0 ? abs($0.element.duration - duration) : 0
                    let rightDistance = duration > 0 ? abs($1.element.duration - duration) : 0
                    if leftDistance != rightDistance { return leftDistance < rightDistance }
                    let leftTimed = !($0.element.syncedLyrics ?? "").isEmpty
                    let rightTimed = !($1.element.syncedLyrics ?? "").isEmpty
                    if leftTimed != rightTimed { return leftTimed }
                    return $0.offset < $1.offset
                }.map(\.element)
                let parsed = candidates.compactMap { record -> Cached? in
                    if record.instrumental { return Cached(lines: [], status: "纯音乐 · LRCLIB") }
                    let knownEnd = duration > 0 ? duration : (record.duration.isFinite && record.duration > 0 ? record.duration : nil)
                    let result = LRCParser.parse(record.syncedLyrics ?? "", duration: knownEnd)
                    return result.isEmpty ? nil : Cached(lines: result, status: "同步歌词 · LRCLIB")
                }.first ?? Cached(lines: [], status: candidates.contains(where: { !($0.plainLyrics ?? "").isEmpty })
                    ? "仅有无时间戳歌词 · LRCLIB" : "未找到匹配的同步歌词 · LRCLIB")
                lines = parsed.lines
                availability = parsed.availability
                status = tr(parsed.status)
                cache[key] = parsed
                cacheOrder.append(key)
                if cacheOrder.count > 64 { cache.removeValue(forKey: cacheOrder.removeFirst()) }
            } catch is CancellationError {
                // A newer track owns the UI.
            } catch {
                guard generation == requestGeneration, !Task.isCancelled else { return }
                availability = .temporaryFailure
                status = String(format: tr("歌词不可用：%@"), error.localizedDescription)
                if let networkError = error as? URLError,
                   [.timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                    .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable].contains(networkError.code) {
                    scheduleRetry(descriptor, album: album, key: key, generation: requestGeneration)
                } else { activeKey = nil }
            }
        }
    }

    func displayMessage(hasReliableTiming: Bool) -> String {
        if !hasReliableTiming, !trackKey.isEmpty { return tr("暂时无法读取播放进度，显示歌曲信息。") }
        return tr(availability.messageKey)
    }

    func canRetry(expectedTrackKey: String) -> Bool {
        !expectedTrackKey.isEmpty && expectedTrackKey == trackKey
            && currentRequest != nil && availability != .loading
    }

    /// The caller supplies the displayed track identity, so a stale button can
    /// never retry a different song. Manual retries do not bypass Retry-After or
    /// discard a scheduled recovery while the service is still cooling down.
    @discardableResult
    func retryCurrentTrack(expectedTrackKey: String) -> Bool {
        guard canRetry(expectedTrackKey: expectedTrackKey), let request = currentRequest else { return false }
        guard Date() >= retryAfter else {
            availability = .coolingDown
            status = tr("歌词服务繁忙，请稍后重试。")
            return false
        }
        cache.removeValue(forKey: request.cacheKey)
        cacheOrder.removeAll { $0 == request.cacheKey }
        retryTask?.cancel(); retryTask = nil; retryKey = nil; retryCount = 0
        activeKey = nil
        load(sourceBundleIdentifier: request.descriptor.sourceBundleIdentifier, title: request.descriptor.title,
             artist: request.descriptor.artist, duration: request.descriptor.duration, album: request.album)
        return true
    }

    /// A brief outage should recover within the same song. Retries remain tied
    /// to its source/metadata generation, with a finite budget and the provider's
    /// global Retry-After deadline. Repeated unchanged metadata cannot add work.
    private func scheduleRetry(_ descriptor: QQTrackDescriptor, album: String, key: String, generation requestGeneration: UUID,
                               notBefore deadline: Date = .distantPast) {
        guard generation == requestGeneration, activeKey == key, retryTask == nil else { return }
        guard retryCount < retryDelays.count else { return }
        let delay = max(retryDelays[retryCount], max(0, deadline.timeIntervalSinceNow))
        retryCount += 1
        retryTask = Task { [weak self] in
            // Bound conversion to nanoseconds even for an unreasonable server
            // header. Recheck the actual deadline on the subsequent load.
            try? await Task.sleep(nanoseconds: UInt64(min(delay, 86_400) * 1_000_000_000))
            guard !Task.isCancelled, let self, self.generation == requestGeneration,
                  self.activeKey == key else { return }
            self.retryTask = nil
            self.activeKey = nil
            self.load(sourceBundleIdentifier: descriptor.sourceBundleIdentifier, title: descriptor.title,
                      artist: descriptor.artist, duration: descriptor.duration, album: album)
        }
    }

    func currentLine(at time: Double) -> String {
        displayLyricLine(at: time)?.text ?? ""
    }

    func displayLyricLine(at time: Double) -> LyricLine? {
        LyricDisplayPolicy.line(in: lines, at: time)
    }

    func currentLyricLine(at time: Double) -> LyricLine? {
        guard time.isFinite else { return nil }
        // Upper bound returns the latest line even for repeated timestamps.
        var low = 0
        var high = lines.count
        while low < high {
            let middle = (low + high) / 2
            if lines[middle].time <= time { low = middle + 1 } else { high = middle }
        }
        guard low > 0 else { return nil }
        let line = lines[low - 1]
        if let end = line.endTime, time >= end { return nil }
        return line
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

/// Classifies the original lyrics locally; song titles and translations are excluded.
enum LyricLanguagePolicy {
    static func isEnglish(_ lines: [String]) -> Bool {
        let sample = lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.prefix(80).joined(separator: "\n")
        guard !sample.isEmpty else { return false }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(sample.prefix(12_000)))
        return recognizer.dominantLanguage == .english
    }
}
