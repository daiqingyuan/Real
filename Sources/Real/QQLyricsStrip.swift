import AppKit
import SwiftUI

/// Shared desktop lyric strip for the selected QQ or NetEase player.
/// Only verified player timing selects a lyric; otherwise show track metadata.
struct QQLyricsStrip: View {
    @ObservedObject var player: QQPlaybackService
    @ObservedObject var lyrics: LyricsService
    @ObservedObject var preferences: Preferences
    var previewText: String? = nil
    var body: some View {
        let key = LyricDisplayPolicy.trackKey(sourceBundleIdentifier: player.sourceBundleIdentifier,
                                             title: player.title, artist: player.artist)
        let time = LyricDisplayPolicy.displayTime(playbackTime: player.lyricRenderPosition() ?? .nan,
                                                 offset: preferences.lyricOffset(for: key))
        let line = player.hasTiming && lyrics.trackKey == key ? lyrics.displayLyricLine(at: time) : nil
        let fontSize = LyricDisplayPolicy.fontSize(for: preferences.lyricsTextSize)
        let weight: Font.Weight = preferences.enabled("lyricsBold") ? .bold : .medium
        let background = LyricDisplayPolicy.backgroundOpacity(preferences.lyricsBackgroundOpacity)
        return HStack(spacing: 6) {
            Image(systemName: "music.note").font(.system(size: 12, weight: .medium)).frame(width: 16)
            VStack(alignment: .center, spacing: 2) {
                if let previewText {
                    KaraokeLyricText(lyric: karaokePreviewLine(previewText), time: 0.48,
                                     fontSize: fontSize, weight: weight, highlight: preferences.lyricsColor)
                        .frame(height: ceil(fontSize * 1.4))
                } else {
                    KaraokeLyricText(lyric: LyricLine(id: -1, time: .infinity,
                                                     text: [player.title, player.artist].filter { !$0.isEmpty }.joined(separator: " · ")),
                                     time: .nan, fontSize: fontSize, weight: weight, highlight: preferences.lyricsColor,
                                     playbackClock: {
                                         guard player.hasTiming else { return nil }
                                         return LyricDisplayPolicy.displayTime(playbackTime: player.lyricRenderPosition() ?? .nan,
                                                                               offset: preferences.lyricOffset(for: key))
                                     }, lineAtTime: { time in
                                         guard lyrics.trackKey == key else { return nil }
                                         return lyrics.displayLyricLine(at: time)
                                     }, playing: player.isPlaying && player.hasTiming)
                        .frame(height: ceil(fontSize * 1.4))
                }
                if previewText == nil, !lyrics.isEnglish, let translation = line?.translation, !translation.isEmpty {
                    ScrollingLyric(text: translation, fontSize: max(9, fontSize - 3), weight: weight)
                        .frame(height: ceil(max(9, fontSize - 3) * 1.4))
                        .foregroundStyle(preferences.lyricsColor.opacity(0.7))
                }
            }
            Color.clear.frame(width: 16, height: 1).accessibilityHidden(true)
        }
        .id(key)
        .foregroundStyle(preferences.lyricsColor)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(LinearGradient(stops: [
            .init(color: .black.opacity(background), location: 0),
            .init(color: .black.opacity(background * 0.23), location: 0.5),
            .init(color: .clear, location: 1)
        ], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.08)))
        .environment(\.locale, preferences.locale)
    }
}

/// Decorative color sample only; never used to infer timing for a real track.
func karaokePreviewLine(_ text: String) -> LyricLine {
    LyricLine(id: -1, time: 0, text: text, words: [
        LyricWord(utf16Location: 0, utf16Length: (text as NSString).length, startTime: 0, duration: 1)
    ])
}

struct ScrollingLyric: View {
    let text: String
    var fontSize: CGFloat = 13
    var weight: Font.Weight = .medium
    var centerShortText = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var began = Date()
    private var nativeFont: NSFont {
        let nativeWeight: NSFont.Weight = weight == .bold ? .bold : weight == .semibold ? .semibold : weight == .regular ? .regular : .medium
        return NSFont.systemFont(ofSize: fontSize, weight: nativeWeight)
    }
    var body: some View {
        GeometryReader { geometry in
            let width = (text as NSString).size(withAttributes: [.font: nativeFont]).width
            let distance = max(0, width - geometry.size.width)
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || distance <= 0)) { timeline in
                let travel = distance / 24
                let cycle = 3 + travel * 2
                let elapsed = max(0, timeline.date.timeIntervalSince(began)).truncatingRemainder(dividingBy: max(3, cycle))
                let offset = reduceMotion ? 0 : min(distance, max(0, elapsed < 1.5 + travel ? (elapsed - 1.5) * 24 : (cycle - elapsed) * 24))
                Text(text).font(Font(nativeFont)).fixedSize()
                    .offset(x: distance > 0 ? -offset : (centerShortText ? max(0, (geometry.size.width - width) / 2) : 0))
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
            }
        }.clipped().accessibilityElement(children: .ignore).accessibilityLabel(text)
            .onChange(of: text) { _, _ in began = Date() }
            .onChange(of: fontSize) { _, _ in began = Date() }
            .onChange(of: weight) { _, _ in began = Date() }
    }
}
