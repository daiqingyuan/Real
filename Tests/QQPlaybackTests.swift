import Foundation

func runQQPlaybackTests() -> [String] {
    var failures: [String] = []
    func check(_ condition: Bool, _ message: String) { if !condition { failures.append("QQ playback: " + message) } }
    check(QQTrackLabel.parse("歌曲名：你会不会 - 歌手名：王霏霏/梁根荣 Gen Neo")
        == QQTrackLabel(title: "你会不会", artist: "王霏霏/梁根荣 Gen Neo"), "observed native label parses without altering artist text")
    check(QQTrackLabel.parse("歌曲名：A - B - 歌手名：C") == QQTrackLabel(title: "A - B", artist: "C"), "hyphen in title is preserved")
    check(QQTrackLabel.parse("  歌曲名：Track - 歌手名：Artist  ") == QQTrackLabel(title: "Track", artist: "Artist"), "surrounding whitespace is removed")
    check(QQTrackLabel.parse("Track - Artist") == nil, "unlabelled text is not guessed")
    check(QQTrackLabel.parse("歌曲名： - 歌手名：Artist") == nil, "empty title is rejected")
    check(QQTrackLabel.parse("歌曲名：Track") == nil, "partial label is rejected")
    let track = QQTrackLabel(title: "Fixture", artist: "Lead/Guest")
    check(track.represents(QQTrackLabel(title: "Fixture", artist: "Lead")), "lead-artist adapter metadata matches full AX collaborator component")
    check(!track.represents(QQTrackLabel(title: "Fixture", artist: "Le")), "partial artist names cannot pass transport identity guard")
    check(!track.represents(QQTrackLabel(title: "Other", artist: "Lead")), "transport guard requires exact title")
    let before = QQPlaybackSnapshot(track: track, isPlaying: true)
    check(!before.confirms(.playPause, after: before), "AX success without playback change is not verified")
    let paused = QQPlaybackSnapshot(track: track, isPlaying: false)
    check(paused.confirms(.playPause, after: before), "pause requires observed state change on same track")
    check(!paused.confirms(.next, after: before), "pause cannot falsely confirm skip")
    let next = QQPlaybackSnapshot(track: QQTrackLabel(title: "Next", artist: "Lead"), isPlaying: true)
    check(next.confirms(.next, after: before), "skip requires observed identity change")
    check(!QQPlaybackSnapshot().confirms(.next, after: before), "missing source is not a successful skip")
    check(QQSeekCompletionPolicy.shouldVerify(status: 0, requestedMicroseconds: 30_000_000, stderr: ""), "normal seek completion still requires position verification")
    check(QQSeekCompletionPolicy.shouldVerify(status: 1, requestedMicroseconds: 30_000_000, stderr: "Failed to seek to 30000000\n"), "known void-return adapter bug permits read-back verification")
    check(!QQSeekCompletionPolicy.shouldVerify(status: 1, requestedMicroseconds: 30_000_000, stderr: "Failed to load framework"), "unrelated process failure cannot be treated as seek dispatch")
    check(!QQSeekCompletionPolicy.shouldVerify(status: 1, requestedMicroseconds: 30_000_000, stderr: "Failed to seek to 20000000"), "legacy diagnostic must match this exact requested target")
    check(!QQSeekCompletionPolicy.shouldVerify(status: nil, requestedMicroseconds: 30_000_000, stderr: "Failed to seek to 30000000"), "timeout is not a legacy seek completion")
    check(!QQSeekCompletionPolicy.shouldVerify(status: 1, requestedMicroseconds: nil, stderr: "Failed to seek to 30000000"), "get/stream cannot enter legacy seek compatibility path")
    let clock = QQMediaAnchor(contentID: "fixture", title: "Fixture", artist: "Artist", album: "", processID: 42,
        duration: 190, elapsed: 129, timestamp: Date(), rate: 1, playing: true, artworkData: nil)
    var failure = QQSeekFailureState()
    failure.record(clock); failure.observe(clock)
    check(failure.isBlocked(clock), "ordinary heartbeat cannot erase unconfirmed seek or re-enable slider")
    failure.clear()
    check(!failure.isBlocked(clock), "confirmed seek clears failed capability state")
    failure.record(clock)
    let different = QQMediaAnchor(contentID: "next", title: "Next", artist: "Artist", album: "", processID: 42,
        duration: 190, elapsed: 0, timestamp: Date(), rate: 1, playing: true, artworkData: nil)
    failure.observe(different)
    check(!failure.isBlocked(different), "new track does not inherit the previous failed seek")
    check(DesktopPlayerKind.qq.bundleID == "com.tencent.QQMusicMac" && DesktopPlayerKind.netease.bundleID == "com.netease.163music",
          "desktop service configurations keep player identities separate")
    check(DesktopPlayerKind.netease.menuTitles.contains("控制"), "NetEase uses its observed native Controls menu")
    var neteaseBefore = clock; neteaseBefore.sourceBundleIdentifier = DesktopPlayerKind.netease.bundleID
    var neteasePaused = QQMediaAnchor(contentID: clock.contentID, title: clock.title, artist: clock.artist, album: "", processID: clock.processID,
        duration: clock.duration, elapsed: clock.elapsed, timestamp: clock.timestamp, rate: 0, playing: false, artworkData: nil)
    neteasePaused.sourceBundleIdentifier = DesktopPlayerKind.netease.bundleID
    check(DesktopTransportVerification.confirms(.playPause, before: neteaseBefore, after: neteasePaused),
          "NetEase pause requires same-source same-track playback state change")
    check(!DesktopTransportVerification.confirms(.playPause, before: clock, after: neteasePaused),
          "another player's paused metadata cannot confirm this player's command")
    check(!DesktopTransportVerification.confirms(.next, before: neteaseBefore, after: neteasePaused),
          "pause cannot confirm a Next command")
    var neteaseNext = different; neteaseNext.sourceBundleIdentifier = DesktopPlayerKind.netease.bundleID
    check(DesktopTransportVerification.confirms(.next, before: neteaseBefore, after: neteaseNext),
          "NetEase Next confirms only an observed change on the same player")
    var restarted = QQMediaAnchor(contentID: clock.contentID, title: clock.title, artist: clock.artist, album: "", processID: clock.processID,
        duration: clock.duration, elapsed: 0, timestamp: clock.timestamp, rate: 1, playing: true, artworkData: nil)
    restarted.sourceBundleIdentifier = DesktopPlayerKind.netease.bundleID
    check(DesktopTransportVerification.confirms(.previous, before: neteaseBefore, after: restarted, at: clock.timestamp),
          "native Previous restarting the current song is correctly verified")
    check(!DesktopTransportVerification.confirms(.next, before: neteaseBefore, after: restarted),
          "same-song restart cannot falsely confirm Next")
    let transitionTime = Date()
    var transition = DesktopTrackTransition()
    transition.begin(.next, at: transitionTime)
    check(transition.resolve(observed: false, previous: true, at: transitionTime.addingTimeInterval(0.4)),
          "brief native track-change pause cannot trigger another source")
    check(!transition.resolve(observed: false, previous: true, at: transitionTime.addingTimeInterval(2.1)),
          "failed track change cannot keep playback active beyond bounded grace")
    check(!transition.resolve(observed: false, previous: false, at: transitionTime),
          "track-change grace cannot fabricate playback for an already paused source")
    transition.begin(.playPause, at: transitionTime)
    check(!transition.resolve(observed: false, previous: true, at: transitionTime),
          "explicit pause cancels track-change grace immediately")
    return failures
}

#if QQ_PLAYBACK_STANDALONE
@main struct QQPlaybackTestRunner {
    static func main() {
        let failures = runQQPlaybackTests()
        if failures.isEmpty { print("PASS: QQ native track-label parser") }
        else { failures.forEach { print("FAIL: " + $0) }; exit(1) }
    }
}
#endif
