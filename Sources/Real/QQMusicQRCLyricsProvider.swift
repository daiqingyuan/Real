import Foundation

// Adapted from the user's QQMusicQRCLyricsProvider.swift. The DES decoder's attribution is retained separately.
final class QQMusicQRCLyricsProvider {
    private let transport: QQMusicLyricsProvider
    init(transport: QQMusicLyricsProvider) { self.transport = transport }

    func fetchLyrics(for descriptor: QQTrackDescriptor, match: QQMusicLyricsProvider.SongMatch) async throws -> QQMusicLyricsProvider.Payload? {
        // QRC requires the numeric song ID; never send musicid=0 for a missing legacy field.
        guard let id = match.songID, id > 0 else { return nil }
        var request = QQMusicLyricsProvider.request(url: URL(string: "https://c.y.qq.com/qqmusic/fcgi-bin/lyric_download.fcg")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("https://c.y.qq.com/", forHTTPHeaderField: "Referer")
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "musicid", value: String(id)), URLQueryItem(name: "version", value: "15"),
                           URLQueryItem(name: "miniversion", value: "82"), URLQueryItem(name: "lrctype", value: "4")]
        request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        let data = try await transport.data(for: request)
        guard let xml = String(data: data, encoding: .utf8) else { throw QQMusicLyricsProvider.RequestError.response }
        let fields = QQMusicQRCParser.extractFromXML(xml)
        guard let original = fields.orig else { throw QQMusicLyricsProvider.RequestError.response }
        if original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        guard QQMusicQRCParser.decodePayload(original) != nil else { throw QQMusicLyricsProvider.RequestError.response }
        let lines = QQMusicQRCParser.parseResponse(original: original, translation: fields.trans,
                                                  duration: descriptor.duration > 0 ? descriptor.duration : nil)
        try Task.checkCancellation()
        return QQMusicQRCParser.hasUsableLyrics(lines) ? .init(lines: lines, source: "QQ QRC") : nil
    }
}
