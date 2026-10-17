import Foundation

func runMediaSelectionTests() -> [String] {
    var failures: [String] = []
    func expect(_ actual: MediaSelection, _ expected: MediaSelection, _ label: String) {
        if actual != expected { failures.append("Media selection: " + label + " (got " + actual.rawValue + ")") }
    }
    func state(_ source: MediaSelection, _ available: Bool = true, _ playing: Bool = false) -> MediaSourceState {
        MediaSourceState(source: source, available: available, playing: playing)
    }
    func legacy(_ mode: String = "auto", _ previous: MediaSelection, _ qa: Bool, _ qp: Bool,
                _ na: Bool, _ np: Bool, _ expected: MediaSelection, _ label: String) {
        expect(MediaSelectionPolicy.select(mode: mode, previous: previous, qqAvailable: qa,
            qqPlaying: qp, nativeAvailable: na, nativePlaying: np), expected, label)
    }
    legacy("auto", .qq, true, false, true, false, .qq, "paused QQ retains its track and resume control")
    legacy("auto", .qq, true, false, true, true, .native, "playing native source takes over paused QQ")
    legacy("auto", .native, true, true, true, false, .qq, "playing QQ takes over paused native")
    legacy("auto", .native, true, true, true, true, .native, "startup tie retains current selection")
    legacy("auto", .qq, false, false, true, false, .native, "closed QQ releases selection")
    legacy("qq", .native, true, false, true, true, .qq, "explicit QQ is respected")
    legacy("ytm", .qq, true, true, true, true, .youtube, "explicit companion is respected")

    var tracker = MediaActivityTracker()
    expect(tracker.select(mode: "auto", previous: .native, states: [state(.qq, true, true), state(.netease)]),
           .qq, "QQ starts first")
    expect(tracker.select(mode: "auto", previous: .qq, states: [state(.qq, true, true), state(.netease, true, true)]),
           .netease, "NetEase starts later and takes over while QQ still plays")
    expect(tracker.select(mode: "auto", previous: .netease, states: [state(.netease, true, true), state(.qq, true, true)]),
           .netease, "reordered metadata poll cannot let older QQ steal selection")
    expect(tracker.select(mode: "auto", previous: .netease, states: [state(.qq), state(.netease, true, true)]),
           .netease, "QQ pause does not change active NetEase")
    expect(tracker.select(mode: "auto", previous: .netease, states: [state(.qq, true, true), state(.netease, true, true)]),
           .qq, "QQ resume is the newest start and takes selection back")
    expect(tracker.select(mode: "auto", previous: .qq, states: [state(.qq), state(.netease, true, true)]),
           .netease, "pausing selected QQ falls back to playing NetEase")
    expect(tracker.select(mode: "auto", previous: .netease, states: [state(.qq), state(.netease)]),
           .netease, "all paused retains selected NetEase track")
    expect(tracker.select(mode: "auto", previous: .netease, states: [state(.qq), state(.netease, false, false)]),
           .qq, "exited selected source falls back to available paused track")
    expect(tracker.select(mode: "auto", previous: .qq, states: []), .native, "no available sources returns empty native state")

    var manual = MediaActivityTracker()
    expect(manual.select(mode: "qq", previous: .native, states: [state(.qq, true, true), state(.netease)]),
           .qq, "manual QQ starts activity history")
    expect(manual.select(mode: "qq", previous: .qq, states: [state(.qq, true, true), state(.netease, true, true)]),
           .qq, "manual QQ remains selected when NetEase starts")
    expect(manual.select(mode: "auto", previous: .qq, states: [state(.qq, true, true), state(.netease, true, true)]),
           .netease, "manual to auto uses starts observed while manual")
    expect(manual.select(mode: "netease", previous: .qq, states: [state(.qq, true, true)]),
           .netease, "manual NetEase stays selected while unavailable")
    expect(manual.select(mode: "qq", previous: .netease, states: []), .qq, "manual QQ stays selected while unavailable")
    expect(manual.select(mode: "ytm", previous: .qq, states: []), .youtube, "manual YouTube stays selected while unavailable")

    var gap = MediaActivityTracker()
    _ = gap.select(mode: "auto", previous: .native, states: [state(.qq, true, true), state(.netease)])
    _ = gap.select(mode: "auto", previous: .qq, states: [state(.qq, true, true), state(.netease, true, true)])
    expect(gap.select(mode: "auto", previous: .netease, states: [state(.qq, false, true), state(.netease, true, true)]),
           .netease, "unavailable older source cannot take ownership")
    expect(gap.select(mode: "auto", previous: .netease, states: [state(.qq, true, true), state(.netease, true, true)]),
           .netease, "returning metadata without a new play edge does not steal selection")
    expect(gap.select(mode: "auto", previous: .netease, states: [state(.qq, true, true)]),
           .qq, "omitted selected source is treated as absent")
    expect(gap.select(mode: "auto", previous: .qq, states: [state(.qq, true, true), state(.netease, true, true)]),
           .netease, "source relaunch after absence counts as new start")

    var unavailable = MediaActivityTracker()
    expect(unavailable.select(mode: "auto", previous: .qq, states: [state(.qq, false, true), state(.native)]),
           .native, "unavailable playing bit cannot suppress available paused source")
    expect(unavailable.select(mode: "auto", previous: .native, states: [state(.qq, true, true), state(.native)]),
           .qq, "first available playback counts despite earlier unavailable metadata")
    var ties = MediaActivityTracker()
    expect(ties.select(mode: "auto", previous: .youtube, states: [state(.native, true, true), state(.netease, true, true), state(.qq, true, true)]),
           .qq, "startup tie with no eligible previous uses fixed order independent of input order")
    var selectedTie = MediaActivityTracker()
    expect(selectedTie.select(mode: "auto", previous: .netease, states: [state(.qq, true, true), state(.netease, true, true)]),
           .netease, "startup tie preserves already selected NetEase")
    var youtube = MediaActivityTracker()
    expect(youtube.select(mode: "auto", previous: .youtube, states: [state(.youtube, true, true), state(.netease)]),
           .netease, "automatic mode excludes explicit-only companion source")
    return failures
}
