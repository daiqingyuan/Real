import Foundation

func runLyricPlaybackClockTests() -> [String] {
    var failures: [String] = []
    func check(_ condition: Bool, _ message: String) {
        if !condition { failures.append("Lyric playback clock: " + message) }
    }
    func near(_ actual: Double?, _ expected: Double) -> Bool {
        actual.map { abs($0 - expected) < 0.000_001 } ?? false
    }

    var clock = LyricPlaybackClock()
    check(clock.position(at: 100) == nil, "no source anchor means no invented position")
    clock.accept(position: 10, duration: 240, rate: 1, isPlaying: true, at: 100)
    for frame in 0...12 {
        let delta = Double(frame) / 60
        check(near(clock.position(at: 100 + delta), 10 + delta),
              "each animation frame advances between 0.2-second observation ticks (frame \(frame))")
    }
    check(near(clock.position(at: 101.25), 11.25), "projection uses source position plus monotonic elapsed time")

    clock.accept(position: 11.25, duration: 240, rate: 1, isPlaying: false, at: 101.25)
    check(near(clock.position(at: 117), 11.25), "pause freezes even if the source retains a nonzero playback rate")
    clock.refresh(at: 119)
    check(near(clock.position(at: 129), 11.25), "same-clock paused heartbeat preserves the frozen baseline")
    clock.accept(position: 11.25, duration: 240, rate: 1, isPlaying: true, at: 130)
    check(near(clock.position(at: 130.25), 11.5), "resume starts from verified pause position and excludes paused time")

    clock.accept(position: 80, duration: 240, rate: 1, isPlaying: true, at: 132)
    check(near(clock.position(at: 132), 80) && near(clock.position(at: 132.5), 80.5),
          "forward seek replaces the old projection immediately")
    clock.accept(position: 15, duration: 240, rate: 1, isPlaying: true, at: 133)
    check(near(clock.position(at: 133), 15) && near(clock.position(at: 133.5), 15.5),
          "backward seek is authoritative and has no smoothing delay")
    clock.accept(position: 2, duration: 30, rate: 0, isPlaying: false, at: 134)
    check(near(clock.position(at: 150), 2), "replacement paused track cannot inherit previous track's position or motion")
    clock.accept(position: 1, duration: 4, rate: 2, isPlaying: true, at: 151)
    check(near(clock.position(at: 152), 3) && near(clock.position(at: 153), 4),
          "replacement playing track uses its own rate and duration, clamping at its end")

    for rate in [0.5, 1.0, 1.5, 2.0, 4.0] {
        var rated = LyricPlaybackClock()
        rated.accept(position: 20, duration: 240, rate: rate, isPlaying: true, at: 10)
        check(near(rated.position(at: 12.25), 20 + 2.25 * rate), "true playback rate \(rate) controls continuous advancement")
    }
    var heartbeat = LyricPlaybackClock()
    heartbeat.accept(position: 20, duration: 240, rate: 1.5, isPlaying: true, at: 10)
    heartbeat.refresh(at: 20)
    check(near(heartbeat.position(at: 20.5), 35.75), "heartbeat refreshes freshness without resetting elapsed projection")
    check(near(heartbeat.position(at: 40), 65), "freshness includes the exact 20-second boundary from latest verification")
    check(heartbeat.position(at: 40.000_001) == nil, "expired running source becomes unavailable between observation ticks")
    check(heartbeat.position(at: 19.99) == nil, "render time before the last verification is a discontinuity, not negative progression")
    heartbeat.refresh(at: 41)
    check(near(heartbeat.position(at: 41.5), 67.25), "fresh verified heartbeat can reestablish freshness without losing source progression")
    heartbeat.invalidate()
    check(heartbeat.position(at: 42) == nil, "stream invalidation or stop removes a render clock immediately")
    heartbeat.accept(position: 3, duration: 100, rate: 0, isPlaying: false, at: 43)
    check(near(heartbeat.position(at: 63), 3) && heartbeat.position(at: 63.01) == nil,
          "a paused source also requires verification within 20 seconds")

    var discontinuity = LyricPlaybackClock()
    discontinuity.accept(position: 5, duration: 100, rate: 1, isPlaying: true, at: 100)
    check(discontinuity.position(at: 99) == nil, "backward uptime read cannot rewind a live source")
    check(discontinuity.position(at: 10_000) == nil, "a large uptime discontinuity expires instead of extrapolating indefinitely")
    discontinuity.refresh(at: 99)
    check(discontinuity.position(at: 101) == nil, "out-of-order verification invalidates rather than reviving an old timeline")
    discontinuity.accept(position: 5, duration: 100, rate: 1, isPlaying: true, at: 100)
    discontinuity.accept(position: 99, duration: 100, rate: 1, isPlaying: true, at: 99)
    check(discontinuity.position(at: 101) == nil, "out-of-order source acceptance cannot replace a newer timeline")

    for invalid in [Double.nan, Double.infinity, -Double.infinity] {
        var invalidClock = LyricPlaybackClock()
        invalidClock.accept(position: 5, duration: 100, rate: 1, isPlaying: true, at: 10)
        check(invalidClock.position(at: invalid) == nil, "nonfinite render uptime is rejected")
        invalidClock.refresh(at: invalid)
        check(invalidClock.position(at: 11) == nil, "nonfinite verification invalidates the previous anchor")
        for field in 0..<4 {
            invalidClock.accept(position: 5, duration: 100, rate: 1, isPlaying: true, at: 10)
            invalidClock.accept(position: field == 0 ? invalid : 5,
                                duration: field == 1 ? invalid : 100,
                                rate: field == 2 ? invalid : 1, isPlaying: true,
                                at: field == 3 ? invalid : 11)
            check(invalidClock.position(at: 12) == nil, "nonfinite source clock field \(field) invalidates instead of leaking old timing")
        }
    }
    for invalidSample in [(position: -1.0, duration: 100.0, rate: 1.0, uptime: 10.0),
                          (position: 101, duration: 100, rate: 1, uptime: 10),
                          (position: 0, duration: 0, rate: 1, uptime: 10),
                          (position: 5, duration: 100, rate: -1, uptime: 10),
                          (position: 5, duration: 100, rate: 0, uptime: 10),
                          (position: 5, duration: 100, rate: 1, uptime: -1)] {
        var invalidClock = LyricPlaybackClock()
        invalidClock.accept(position: invalidSample.position, duration: invalidSample.duration,
                            rate: invalidSample.rate, isPlaying: true, at: invalidSample.uptime)
        check(invalidClock.position(at: 11) == nil, "invalid position, duration, playing rate, or uptime cannot supply lyrics")
    }
    var overflow = LyricPlaybackClock()
    overflow.accept(position: 5, duration: 100, rate: Double.greatestFiniteMagnitude, isPlaying: true, at: 0)
    check(overflow.position(at: 2) == nil, "finite input that overflows during extrapolation is rejected")
    return failures
}

#if LYRIC_PLAYBACK_CLOCK_STANDALONE
@main struct LyricPlaybackClockTestRunner {
    static func main() {
        let failures = runLyricPlaybackClockTests()
        if failures.isEmpty { print("PASS: continuous lyric clock, pause/resume, seeks, rates, replacement, freshness, and invalidation") }
        else { failures.forEach { print("FAIL: " + $0) }; exit(1) }
    }
}
#endif
