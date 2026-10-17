import Foundation

func runQQMediaAnchorTests() -> [String] {
    var failures: [String] = []
    let now = Date(timeIntervalSince1970: 1_700_000_010)
    var sample: [String: Any] = ["bundleIdentifier": "com.tencent.QQMusicMac", "processIdentifier": 42,
        "title": "Example", "artist": "Artist", "album": "Album", "duration": 100.0,
        "elapsedTime": 20.0, "playbackRate": 1.0, "playing": true, "timestamp": "2023-11-14T22:13:20Z"]
    func decode(_ value: [String: Any]) -> QQMediaAnchor? {
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return QQMediaAnchor.decode(data, now: now, expectedPID: 42)
    }
    func check(_ condition: Bool, _ message: String) { if !condition { failures.append("QQ anchor: " + message) } }
    check(decode(sample)?.position(at: now) == 30, "advances from supplied anchor, not app launch")
    var neteaseSample = sample
    neteaseSample["bundleIdentifier"] = "com.netease.163music"
    let neteaseData = try! JSONSerialization.data(withJSONObject: neteaseSample)
    let neteaseAnchor = QQMediaAnchor.decode(neteaseData, now: now, expectedPID: 42, expectedBundleID: "com.netease.163music")
    check(neteaseAnchor?.position(at: now) == 30 && neteaseAnchor?.sourceBundleIdentifier == "com.netease.163music",
          "NetEase anchor validates its own configured bundle and retains source identity")
    check(QQMediaAnchor.decode(neteaseData, now: now, expectedPID: 42) == nil, "QQ service cannot consume NetEase metadata")
    check(QQMediaAnchor.decode(try! JSONSerialization.data(withJSONObject: sample), now: now, expectedPID: 42, expectedBundleID: "com.netease.163music") == nil,
          "NetEase service cannot consume QQ metadata")
    check(!neteaseAnchor!.hasSameTrack(as: decode(sample)!), "matching process/track fields from different bundles are distinct identities")
    sample["playing"] = false
    check(decode(sample)?.position(at: now) == 20, "pause does not advance")
    sample["playing"] = true; sample["processIdentifier"] = 43
    check(decode(sample) == nil, "rejects another process")
    sample["processIdentifier"] = 42; sample["bundleIdentifier"] = "com.apple.Music"
    check(decode(sample) == nil, "rejects other source")
    sample["bundleIdentifier"] = "com.tencent.QQMusicMac"; sample["timestamp"] = "2023-11-14T22:13:40Z"
    check(decode(sample) == nil, "rejects future timestamp")
    sample["timestamp"] = "2023-11-14T22:13:20.500Z"
    check(decode(sample)?.position(at: now) == 29.5, "fractional ISO timestamp")
    sample["elapsedTime"] = 99
    check(decode(sample)?.position(at: now) == nil, "unresolved anchor beyond track end cannot supply a position")
    sample["elapsedTime"] = -1
    check(decode(sample) == nil, "rejects negative elapsed")
    sample["elapsedTime"] = true
    check(decode(sample) == nil, "boolean is not a clock number")
    sample["elapsedTime"] = 20; sample["duration"] = 0
    check(decode(sample) == nil, "rejects unavailable duration")
    sample["duration"] = 100; sample["playbackRate"] = 0
    check(decode(sample) == nil, "playing requires positive rate")
    sample["playing"] = false
    check(decode(sample)?.position(at: now) == 20, "zero rate pause accepted")
    sample["timestamp"] = "not a date"
    check(decode(sample) == nil, "malformed timestamp rejected")
    sample["timestamp"] = "2023-11-14T22:13:20Z"; sample["playing"] = false
    sample["playbackRate"] = 0; sample["processIdentifier"] = 42.5
    check(decode(sample) == nil, "fractional PID is not truncated to another process")
    sample["processIdentifier"] = 42
    let earlier = decode(sample)!
    sample["timestamp"] = "2023-11-14T22:13:21Z"
    let later = decode(sample)!
    check(!earlier.supersedes(later), "old same-track anchor cannot rewind timeline")
    sample["title"] = "Different item"; sample["timestamp"] = "2023-11-14T22:13:19Z"
    check(decode(sample)!.supersedes(later), "new track may legitimately have an earlier paused anchor")
    check(!decode(sample)!.hasSameTrack(as: later), "seek identity includes title even without content ID")
    // Regression: QQ pauses by toggling only `playing`; elapsed=1 remains a
    // track-start anchor, not the current paused position (66 seconds).
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    func fixture(elapsed: Double = 1, timestamp: Date? = nil, playing: Bool,
                 title: String = "Fixture") -> QQMediaAnchor {
        QQMediaAnchor(contentID: "fixture", title: title, artist: "Artist", album: "Album", processID: 42,
            duration: 200, elapsed: elapsed, timestamp: timestamp ?? start,
            rate: playing ? 1 : 0, playing: playing, artworkData: nil)
    }
    let running = fixture(playing: true)
    let stalePause = fixture(playing: false)
    let pauseAt = start.addingTimeInterval(65)
    let frozen = stalePause.resolvingClock(previousRaw: running, previousResolved: running, receivedAt: pauseAt)!
    check(frozen.position(at: pauseAt) == 66, "unchanged paused clock freezes 66 seconds instead of jumping to raw elapsed=1")
    check(frozen.position(at: start.addingTimeInterval(85)) == 66, "frozen pause excludes later wall-clock time")
    let repeatedPause = stalePause.resolvingClock(previousRaw: stalePause, previousResolved: frozen, receivedAt: start.addingTimeInterval(85))!
    check(repeatedPause.position(at: start.addingTimeInterval(85)) == 66, "repeated paused heartbeat cannot restore stale elapsed=1")
    let changedPaused = fixture(elapsed: 12, timestamp: start.addingTimeInterval(85), playing: false)
    check(changedPaused.resolvingClock(previousRaw: stalePause, previousResolved: frozen, receivedAt: start.addingTimeInterval(85))?.position(at: start.addingTimeInterval(85)) == 12,
          "genuine paused seek with a changed clock pair remains authoritative")
    let freshResume = fixture(elapsed: 66, timestamp: start.addingTimeInterval(90), playing: true)
    check(freshResume.resolvingClock(previousRaw: stalePause, previousResolved: frozen, receivedAt: start.addingTimeInterval(90))?.position(at: start.addingTimeInterval(124)) == 100,
          "fresh resume clock produces the correct 100-second position")
    let staleResume = fixture(playing: true)
    let resumed = staleResume.resolvingClock(previousRaw: stalePause, previousResolved: frozen, receivedAt: start.addingTimeInterval(90))!
    check(resumed.position(at: start.addingTimeInterval(90)) == 66, "unchanged resume clock must not count time spent paused")
    let resumedHeartbeat = staleResume.resolvingClock(previousRaw: staleResume, previousResolved: resumed, receivedAt: start.addingTimeInterval(100))!
    check(resumedHeartbeat.position(at: start.addingTimeInterval(100)) == 76, "unchanged running heartbeat retains corrected resume baseline")
    // The raw QQ pair now projects beyond the track end, but the corrected
    // pause baseline is still 66 seconds. Decode must let reconciliation run.
    var longPauseJSON = sample
    longPauseJSON["title"] = "Fixture"; longPauseJSON["artist"] = "Artist"
    longPauseJSON["contentItemIdentifier"] = "fixture"
    longPauseJSON["duration"] = 200; longPauseJSON["elapsedTime"] = 1
    longPauseJSON["playing"] = true; longPauseJSON["playbackRate"] = 1
    longPauseJSON["timestamp"] = "2023-11-14T22:13:20Z"
    let longResumeTime = start.addingTimeInterval(3600)
    let longPauseData = try! JSONSerialization.data(withJSONObject: longPauseJSON)
    let longResumeRaw = QQMediaAnchor.decode(longPauseData, now: longResumeTime, expectedPID: 42)
    let longResume = longResumeRaw?.resolvingClock(previousRaw: stalePause, previousResolved: frozen, receivedAt: longResumeTime)
    check(longResume?.position(at: longResumeTime) == 66, "resuming after an hour excludes paused wall time before validating track end")
    check(longResumeRaw?.position(at: longResumeTime) == nil, "without an observed pause baseline an expired raw clock remains unusable")
    let changedTrack = fixture(playing: false, title: "Other")
    check(changedTrack.resolvingClock(previousRaw: running, previousResolved: running, receivedAt: pauseAt)?.position(at: pauseAt) == 1,
          "different tracks do not inherit the previous song's position")
    check(stalePause.resolvingClock(previousRaw: nil, previousResolved: nil, receivedAt: pauseAt)?.elapsed == 1,
          "initial paused observation cannot invent an unobserved position")
    // Parent's read-only live evidence, 2026-10-13: elapsedTime=45,
    // timestamp=2026-10-13T10:34:14Z, rate=1 both before and after pause.
    // Only playing changed true->false. The adapter's elapsedNow kept advancing
    // (93.98 before / 109.025 after), while Real correctly held 102.2075.
    let observedStart = ISO8601DateFormatter().date(from: "2026-10-13T10:34:14Z")!
    let observedPlaying = QQMediaAnchor(contentID: "live-evidence-fixture", title: "Fixture", artist: "Artist", album: "", processID: 42,
        duration: 249, elapsed: 45, timestamp: observedStart, rate: 1, playing: true, artworkData: nil)
    let observedPaused = QQMediaAnchor(contentID: "live-evidence-fixture", title: "Fixture", artist: "Artist", album: "", processID: 42,
        duration: 249, elapsed: 45, timestamp: observedStart, rate: 1, playing: false, artworkData: nil)
    let observedFrozen = observedPaused.resolvingClock(previousRaw: observedPlaying, previousResolved: observedPlaying,
        receivedAt: observedStart.addingTimeInterval(57.2075))!
    check(abs((observedFrozen.position(at: observedStart.addingTimeInterval(64.025)) ?? -1) - 102.2075) < 0.001,
          "observed QQ pause keeps 102.2075 even when raw playbackRate remains 1")
    let faster = QQMediaAnchor(contentID: "fixture", title: "Fixture", artist: "Artist", album: "Album", processID: 42,
        duration: 200, elapsed: 1, timestamp: start, rate: 2, playing: true, artworkData: nil)
    let changedRate = faster.resolvingClock(previousRaw: running, previousResolved: running, receivedAt: pauseAt)!
    check(changedRate.position(at: pauseAt.addingTimeInterval(10)) == 86,
          "rate-only updates preserve current position and apply the new rate forward")
    return failures
}

#if QQ_ANCHOR_STANDALONE
@main struct QQAnchorTestRunner {
    static func main() {
        let failures = runQQMediaAnchorTests()
        if failures.isEmpty { print("PASS: QQ anchor validation, identity, paused and running clocks") }
        else { failures.forEach { print("FAIL: " + $0) }; exit(1) }
    }
}
#endif
