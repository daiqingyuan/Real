import Foundation

/// Render-only projection of a verified player position. Uptime keeps a running
/// lyric independent of wall-clock corrections and of the service's publish rate.
/// Source snapshots remain authoritative: a seek or track change replaces the
/// anchor immediately, including when its position moves backwards.
struct LyricPlaybackClock {
    private struct Anchor {
        let position: Double
        let duration: Double
        let rate: Double
        let uptime: TimeInterval
        var verifiedUptime: TimeInterval
    }

    private var anchor: Anchor?
    private static let maximumAge: TimeInterval = 20

    /// `position` is the source-derived position at this exact uptime. A paused
    /// source may still report a nonzero rate; its effective render rate is zero.
    mutating func accept(position: Double, duration: Double, rate: Double,
                         isPlaying: Bool, at uptime: TimeInterval) {
        guard position.isFinite, duration.isFinite, rate.isFinite, uptime.isFinite,
              duration > 0, position >= 0, position <= duration, rate >= 0,
              !isPlaying || rate > 0, uptime >= 0,
              anchor.map({ uptime >= $0.verifiedUptime }) ?? true else {
            invalidate()
            return
        }
        anchor = Anchor(position: position, duration: duration,
                        rate: isPlaying ? rate : 0, uptime: uptime, verifiedUptime: uptime)
    }

    /// A verified heartbeat for the same source clock extends freshness without
    /// rebasing from a later wall-clock sample or from a 5 Hz published position.
    mutating func refresh(at uptime: TimeInterval) {
        guard var current = anchor, uptime.isFinite, uptime >= current.verifiedUptime else {
            invalidate()
            return
        }
        current.verifiedUptime = uptime
        anchor = current
    }

    func position(at uptime: TimeInterval) -> Double? {
        guard let anchor, uptime.isFinite, uptime >= anchor.verifiedUptime,
              uptime - anchor.verifiedUptime <= Self.maximumAge else { return nil }
        let position = anchor.position + (uptime - anchor.uptime) * anchor.rate
        guard position.isFinite else { return nil }
        return min(anchor.duration, max(0, position))
    }

    mutating func invalidate() { anchor = nil }
}
