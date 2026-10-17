import CoreGraphics
import Foundation

struct LyricLine: Identifiable, Equatable, Sendable {
    let id: Int
    let time: Double
    let text: String
    let translation: String?
    let endTime: Double?

    init(id: Int, time: Double, text: String, translation: String? = nil, endTime: Double? = nil) {
        self.id = id; self.time = time; self.text = text
        self.translation = translation; self.endTime = endTime
    }
}

enum LyricsAvailability: Equatable {
    case waiting, loading, ready, instrumental, unavailable, temporaryFailure, coolingDown

    var messageKey: String {
        switch self {
        case .waiting: return "等待曲目信息"
        case .loading: return "正在加载歌词…"
        case .ready: return "同步歌词已就绪"
        case .instrumental: return "这是一首纯音乐。"
        case .unavailable: return "暂未找到这首歌的同步歌词。"
        case .temporaryFailure: return "歌词暂时不可用，可稍后重试。"
        case .coolingDown: return "歌词服务繁忙，请稍后重试。"
        }
    }
}

/// Display preferences never modify a player's transport or the provider's LRC.
enum LyricDisplayPolicy {
    static func trackKey(sourceBundleIdentifier: String?, title: String, artist: String) -> String {
        func normalized(_ text: String) -> String {
            text.precomposedStringWithCanonicalMapping
                .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                .lowercased(with: Locale(identifier: "en_US_POSIX"))
        }
        let title = normalized(title)
        guard !title.isEmpty else { return "" }
        // Prefix lengths distinguish embedded separators and Unicode components.
        return [normalized(sourceBundleIdentifier ?? ""), title, normalized(artist)]
            .map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }

    static func fontSize(for textSize: String) -> CGFloat {
        switch textSize { case "small": return 11; case "large": return 16; default: return 13 }
    }

    static func clampedOffset(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return (min(5, max(-5, value)) * 5).rounded() / 5
    }

    /// Positive values advance the displayed lyric. A negative result is useful:
    /// a delayed first line must remain absent until its adjusted start time.
    static func displayTime(playbackTime: Double, offset: Double) -> Double {
        guard playbackTime.isFinite, playbackTime >= 0 else { return .nan }
        let result = playbackTime + clampedOffset(offset)
        return result.isFinite ? result : .nan
    }

    static func backgroundOpacity(_ value: Double) -> Double {
        value.isFinite ? min(0.9, max(0, value)) : 0.65
    }

    /// Hold the previous readable line through rests and blank markers. Exact
    /// singing end times remain available through currentLyricLine instead.
    static func line(in lines: [LyricLine], at time: Double) -> LyricLine? {
        guard time.isFinite, time >= 0 else { return nil }
        return lines.last { $0.time <= time && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

/// Kept independent of scroll-view geometry so a track change cannot inherit
/// another song's manual-browsing state.
struct LyricFollowState {
    private(set) var trackKey = ""
    private(set) var following = true

    mutating func selectTrack(_ key: String) {
        guard key != trackKey else { return }
        trackKey = key; following = true
    }
    mutating func userScrolled() { following = false }
    mutating func resumeFollowing() { following = true }
}
