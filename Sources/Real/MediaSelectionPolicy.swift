import Foundation

enum MediaSelection: String { case native, qq, netease, youtube }

struct MediaSourceState {
    let source: MediaSelection
    let available: Bool
    let playing: Bool
}

/// Tracks play transitions, not metadata refresh time. Call on every source
/// snapshot, including while an explicit source is selected. A shared snapshot's
/// new starts receive the same rank: keep the previous source on a tie, otherwise
/// use QQ, NetEase, then native Music/Spotify. YouTube remains explicit-only.
struct MediaActivityTracker {
    private var previousPlaying: [MediaSelection: Bool] = [:]
    private var startedAt: [MediaSelection: UInt64] = [:]
    private var serial: UInt64 = 0
    private static let automaticSources: [MediaSelection] = [.qq, .netease, .native]

    mutating func select(mode: String, previous: MediaSelection,
                         states: [MediaSourceState]) -> MediaSelection {
        var snapshot: [MediaSelection: MediaSourceState] = [:]
        for state in states { snapshot[state.source] = state }
        var started: [MediaSelection] = []
        for source in Self.automaticSources {
            guard let state = snapshot[source] else {
                previousPlaying[source] = false
                continue
            }
            guard state.available else {
                // A transient metadata gap with an unchanged playing bit is not
                // a new play event. An explicit stopped/absent state resets the
                // edge so a subsequent real restart can take ownership.
                if !state.playing { previousPlaying[source] = false }
                continue
            }
            if state.playing && previousPlaying[source] != true { started.append(source) }
            previousPlaying[source] = state.playing
        }
        if !started.isEmpty {
            serial += 1
            for source in started { startedAt[source] = serial }
        }

        switch mode {
        case "qq": return .qq
        case "netease": return .netease
        case "ytm": return .youtube
        default: break
        }
        let available = Self.automaticSources.filter { snapshot[$0]?.available == true }
        let playing = available.filter { snapshot[$0]?.playing == true }
        if !playing.isEmpty { return mostRecent(playing, previous: previous) }
        // Keep the selected paused track and its resume controls until it exits.
        if available.contains(previous) { return previous }
        return available.isEmpty ? .native : mostRecent(available, previous: previous)
    }

    private func mostRecent(_ candidates: [MediaSelection], previous: MediaSelection) -> MediaSelection {
        let newest = candidates.map { startedAt[$0] ?? 0 }.max() ?? 0
        let tied = candidates.filter { (startedAt[$0] ?? 0) == newest }
        return tied.contains(previous) ? previous : tied[0]
    }
}

/// Compatibility for callers without retained activity state. Such a caller has
/// no historical play edges, so simultaneous playback retains its previous source.
enum MediaSelectionPolicy {
    static func select(mode: String, previous: MediaSelection, qqAvailable: Bool,
                       qqPlaying: Bool, nativeAvailable: Bool, nativePlaying: Bool) -> MediaSelection {
        var tracker = MediaActivityTracker()
        return tracker.select(mode: mode, previous: previous, states: [
            MediaSourceState(source: .qq, available: qqAvailable, playing: qqPlaying),
            MediaSourceState(source: .native, available: nativeAvailable, playing: nativePlaying)
        ])
    }
}
