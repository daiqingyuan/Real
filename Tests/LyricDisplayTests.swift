import Foundation

func runLyricDisplayTests() -> [String] {
    var failures: [String] = []
    func check(_ condition: Bool, _ label: String) { if !condition { failures.append("Lyric display: " + label) } }
    func key(_ source: String? = "com.tencent.QQMusicMac", _ title: String = "Song", _ artist: String = "Artist") -> String {
        LyricDisplayPolicy.trackKey(sourceBundleIdentifier: source, title: title, artist: artist)
    }

    check(key() == key(" COM.TENCENT.QQMUSICMAC ", "  SONG\n", " Artist "), "metadata whitespace and case do not lose a saved correction")
    check(key(nil, "Café", "") == key(nil, "Cafe\u{301}", ""), "Unicode canonical equivalents share a stable key")
    check(key(nil, "Song", "") != "", "missing artist does not prevent local-track adjustment")
    check(key(nil, "  \n", "Artist").isEmpty, "missing title cannot create a shared empty-song setting")
    check(key("com.netease.163music") != key(), "different player sources retain separate corrections")
    check(key(nil, "Song", "Other") != key(nil, "Song", "Artist"), "same-title recordings by different artists remain separate")
    check(key(nil, "Song (Live)", "Artist") != key(nil, "Song", "Artist"), "recording suffixes are preserved")
    check(key("a|b", "c", "d") != key("a", "b|c", "d"), "embedded field delimiters cannot collide")
    check(key("a", "é|x", "d") != key("a", "é", "x|d"), "Unicode byte lengths keep the encoding unambiguous")

    check(LyricDisplayPolicy.fontSize(for: "small") == 11 && LyricDisplayPolicy.fontSize(for: "standard") == 13
        && LyricDisplayPolicy.fontSize(for: "large") == 16 && LyricDisplayPolicy.fontSize(for: "invalid") == 13,
          "font presets include a safe standard fallback")
    check(LyricDisplayPolicy.clampedOffset(9) == 5 && LyricDisplayPolicy.clampedOffset(-9) == -5, "correction stays within five seconds")
    check(LyricDisplayPolicy.clampedOffset(.nan) == 0 && LyricDisplayPolicy.clampedOffset(.infinity) == 0, "non-finite stored corrections are neutral")
    var correction = 0.0
    for _ in 0..<25 { correction = LyricDisplayPolicy.clampedOffset(correction + 0.2) }
    check(correction == 5, "repeated 0.2-second steps reach the upper limit without floating-point drift")
    for _ in 0..<25 { correction = LyricDisplayPolicy.clampedOffset(correction - 0.2) }
    check(correction == 0, "opposite steps restore exact zero")
    check(LyricDisplayPolicy.displayTime(playbackTime: 10, offset: 0.2) == 10.2, "positive correction advances lyrics only")
    check(LyricDisplayPolicy.displayTime(playbackTime: 0, offset: -0.2) == -0.2, "delayed opening lyrics do not appear at zero")
    check(LyricDisplayPolicy.displayTime(playbackTime: .nan, offset: 0).isNaN
        && LyricDisplayPolicy.displayTime(playbackTime: -1, offset: 0).isNaN, "unreliable player times cannot select lyrics")
    let lines = [LyricLine(id: 0, time: 0, text: "Opening", endTime: 1),
                 LyricLine(id: 1, time: 2, text: ""), LyricLine(id: 2, time: 5, text: "Next")]
    check(LyricDisplayPolicy.line(in: lines, at: LyricDisplayPolicy.displayTime(playbackTime: 0, offset: -0.2)) == nil,
          "negative correction waits before the first line")
    check(LyricDisplayPolicy.line(in: lines, at: 3)?.text == "Opening", "rests preserve the last readable line instead of returning to the title")
    check(LyricDisplayPolicy.line(in: lines, at: LyricDisplayPolicy.displayTime(playbackTime: 4.8, offset: 0.2))?.text == "Next",
          "display correction moves the highlighted line without mutating lyric timestamps")
    check(lines[2].time == 5, "provider timestamps are not rewritten by display preferences")
    check(LyricDisplayPolicy.backgroundOpacity(-1) == 0 && LyricDisplayPolicy.backgroundOpacity(1) == 0.9
        && LyricDisplayPolicy.backgroundOpacity(.nan) == 0.65, "invalid background preferences cannot make unsupported opacity")

    var follow = LyricFollowState()
    follow.selectTrack(key())
    follow.userScrolled()
    check(!follow.following, "manual scrolling pauses following")
    follow.selectTrack(key())
    check(!follow.following, "the same track's metadata refresh cannot resume following")
    follow.resumeFollowing()
    check(follow.following, "return-to-current-line explicitly resumes following")
    follow.userScrolled(); follow.selectTrack(key(nil, "Other", "Artist"))
    check(follow.following, "a new track resets manual browsing")
    follow.userScrolled(); follow.selectTrack("")
    check(follow.following, "clearing playback also resets manual browsing")
    check(LyricsAvailability.loading.messageKey != LyricsAvailability.unavailable.messageKey
        && LyricsAvailability.instrumental.messageKey != LyricsAvailability.temporaryFailure.messageKey,
          "loading, absent, instrumental and failed lyrics have distinct explanations")
    return failures
}

#if LYRIC_DISPLAY_POLICY_STANDALONE
@main struct LyricDisplayTestsRunner {
    static func main() {
        let failures = runLyricDisplayTests()
        if failures.isEmpty { print("PASS: lyric identity, display correction, appearance bounds, gap holding and manual following") }
        else { failures.forEach { print("FAIL: " + $0) }; exit(1) }
    }
}
#endif
