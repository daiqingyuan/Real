import SwiftUI

/// Waiting and paused are normal states; checking never controls playback.
struct RuntimeMediaStatusView: View {
    @ObservedObject var player: QQPlaybackService
    @ObservedObject var media: MediaService
    @ObservedObject var youtube: YouTubeMusicService
    @ObservedObject var lyrics: LyricsService
    @ObservedObject var preferences: Preferences
    let usingDesktop: Bool
    let preview: Bool

    private var useYouTube: Bool { preferences.mediaSource == "ytm" }
    private var title: String { usingDesktop ? player.title : useYouTube ? youtube.title : media.title }
    private var playing: Bool { usingDesktop ? player.isPlaying : useYouTube ? youtube.isPlaying : media.isPlaying }
    private var hasError: Bool { usingDesktop ? player.errorMessage != nil : useYouTube ? youtube.errorMessage != nil : media.errorMessage != nil }
    private var timing: Bool {
        let time = usingDesktop ? player.position : useYouTube ? youtube.position : media.position
        return time.isFinite && time >= 0 && (!usingDesktop || player.hasTiming)
    }
    private var playerStatus: String {
        if preview { return tr("预览") }
        if !preferences.enabled("music") { return tr("已关闭") }
        if hasError { return tr("播放器连接暂时不可用") }
        if title.isEmpty { return tr("等待播放器开始播放") }
        return tr(playing ? "正在播放" : "已暂停")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text(tr("播放器")); Spacer(); Text(playerStatus).foregroundStyle(.secondary) }
            HStack {
                Text(tr("歌词")); Spacer()
                Text(!preferences.enabled("lyrics") || !preferences.enabled("music") ? tr("已关闭")
                     : preview ? tr("预览") : lyrics.displayMessage(hasReliableTiming: timing))
                    .foregroundStyle(.secondary)
            }
        }.font(.callout)
    }
}
