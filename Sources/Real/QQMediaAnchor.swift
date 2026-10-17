import Foundation

/// Validated snapshot from the separately licensed adapter. A timestamp is an
/// actual player anchor, not the time this application started observing.
struct QQMediaAnchor {
    static let bundleID = "com.tencent.QQMusicMac"
    let contentID: String
    let title: String
    let artist: String
    let album: String
    let processID: Int32
    let duration: Double
    let elapsed: Double
    let timestamp: Date
    let rate: Double
    let playing: Bool
    let artworkData: Data?
    var sourceBundleIdentifier: String = QQMediaAnchor.bundleID

    static func decode(_ data: Data, now: Date = Date(), expectedPID: Int32, expectedBundleID: String = bundleID) -> QQMediaAnchor? {
        guard data.count <= 2_000_000,
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["bundleIdentifier"] as? String == expectedBundleID,
              let pid = number(value["processIdentifier"]), pid == Double(expectedPID), expectedPID > 0,
              let title = value["title"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let duration = number(value["duration"]), duration > 0, duration <= 604_800,
              let elapsed = number(value["elapsedTime"]), elapsed >= 0, elapsed <= duration,
              let rate = number(value["playbackRate"]), rate >= 0, rate <= 4,
              let playingValue = value["playing"] as? NSNumber, CFGetTypeID(playingValue) == CFBooleanGetTypeID(),
              let timestampString = value["timestamp"] as? String,
              let timestamp = parseDate(timestampString)
        else { return nil }
        let playing = playingValue.boolValue
        let age = now.timeIntervalSince(timestamp)
        // A paused anchor may legitimately be old. Bound both cases to seven days;
        // a fresh read heartbeat, checked by the owner, confirms its freshness.
        guard age >= -2, age <= 604_800, !playing || rate > 0 else { return nil }
        // Validate the raw clock here, but defer its projected position until
        // resolvingClock. QQ may reuse this pair after a long pause; projecting
        // paused wall time before applying the saved correction rejects a valid
        // resume and makes timing/lyrics disappear for the rest of the track.
        var artwork: Data?
        if let encoded = value["artworkData"] as? String, encoded.utf8.count <= 1_400_000,
           let decoded = Data(base64Encoded: encoded), decoded.count <= 1_000_000 { artwork = decoded }
        return QQMediaAnchor(contentID: String((value["contentItemIdentifier"] as? String ?? "").prefix(4096)), title: String(title.prefix(4096)), artist: String((value["artist"] as? String ?? "").prefix(4096)),
            album: String((value["album"] as? String ?? "").prefix(4096)), processID: expectedPID,
            duration: duration, elapsed: elapsed, timestamp: timestamp, rate: rate, playing: playing, artworkData: artwork, sourceBundleIdentifier: expectedBundleID)
    }

    func hasSameTrack(as other: QQMediaAnchor) -> Bool {
        sourceBundleIdentifier == other.sourceBundleIdentifier && processID == other.processID && contentID == other.contentID
            && title == other.title && artist == other.artist && duration == other.duration
    }

    /// Timestamps are comparable only within one track; a different player item
    /// may carry an older anchor, for example when returning to a paused queue.
    func supersedes(_ previous: QQMediaAnchor?) -> Bool {
        guard let previous, hasSameTrack(as: previous) else { return true }
        return timestamp >= previous.timestamp
    }

    /// QQ can toggle its playback flag without refreshing the elapsed/timestamp
    /// pair. Treat that pair as one clock generation: pause freezes the last
    /// credible extrapolation, and resume continues from that frozen point until
    /// a genuinely new clock pair arrives. Keep the raw pair separately so a
    /// repeated heartbeat cannot erase this correction or count paused wall time.
    func resolvingClock(previousRaw: QQMediaAnchor?, previousResolved: QQMediaAnchor?,
                        receivedAt now: Date) -> QQMediaAnchor? {
        guard supersedes(previousRaw) else { return nil }
        guard let previousRaw, let previousResolved,
              hasSameTrack(as: previousRaw), hasSameTrack(as: previousResolved),
              timestamp == previousRaw.timestamp, elapsed == previousRaw.elapsed else { return self }
        if playing == previousRaw.playing && (!playing || rate == previousRaw.rate) {
            return usingClock(elapsed: previousResolved.elapsed, timestamp: previousResolved.timestamp,
                              rate: previousResolved.rate)
        }
        guard let frozen = previousResolved.position(at: now) else { return nil }
        return usingClock(elapsed: frozen, timestamp: now, rate: playing ? rate : 0)
    }

    private func usingClock(elapsed: Double, timestamp: Date, rate: Double) -> QQMediaAnchor {
        QQMediaAnchor(contentID: contentID, title: title, artist: artist, album: album,
            processID: processID, duration: duration, elapsed: elapsed, timestamp: timestamp,
            rate: rate, playing: playing, artworkData: artworkData, sourceBundleIdentifier: sourceBundleIdentifier)
    }

    func position(at date: Date) -> Double? {
        let age = date.timeIntervalSince(timestamp)
        guard age.isFinite, age >= -2, age <= 604_800 else { return nil }
        let result = elapsed + max(0, age) * (playing ? rate : 0)
        guard result.isFinite, result <= duration + 2 else { return nil }
        return min(duration, max(0, result))
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
