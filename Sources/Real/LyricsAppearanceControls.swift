import SwiftUI

struct LyricsAppearanceControls: View {
    let playerKey: String
    @ObservedObject var preferences: Preferences

    private var offset: Double { preferences.lyricOffset(for: playerKey) }
    private var offsetText: String {
        if offset == 0 { return tr("未调整") }
        return String(format: tr(offset > 0 ? "提前 %.1f 秒" : "延后 %.1f 秒"), abs(offset))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(tr("歌词字号"), selection: $preferences.lyricsTextSize) {
                Text(tr("小")).tag("small")
                Text(tr("标准")).tag("standard")
                Text(tr("大")).tag("large")
            }
            Toggle(tr("歌词加粗"), isOn: preferences.binding("lyricsBold"))
            HStack {
                Text(tr("背景深浅"))
                Slider(value: $preferences.lyricsBackgroundOpacity, in: 0...0.9)
                    .accessibilityLabel(tr("背景深浅"))
            }
            Divider()
            HStack {
                Text(tr("本曲歌词同步"))
                Spacer()
                Text(offsetText).monospacedDigit().foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button(tr("提前 0.2 秒")) { adjust(0.2) }.disabled(playerKey.isEmpty || offset >= 5)
                Button(tr("延后 0.2 秒")) { adjust(-0.2) }.disabled(playerKey.isEmpty || offset <= -5)
                Button(tr("重置")) { preferences.setLyricOffset(0, for: playerKey) }
                    .disabled(playerKey.isEmpty || offset == 0)
            }
            Text(tr(playerKey.isEmpty ? "播放音乐后可调整当前歌曲。" : "仅调整歌词显示，不改变播放进度。"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func adjust(_ change: Double) {
        guard !playerKey.isEmpty else { return }
        preferences.setLyricOffset(LyricDisplayPolicy.clampedOffset(offset + change), for: playerKey)
    }
}
