import SwiftUI

/// A drawing of the interface, deliberately independent of AppModel and its
/// services. All controls in the drawing are decorative; only the mode picker
/// changes local preview state.
struct CompactIslandPreview: View {
    let module: String
    @ObservedObject var p: Preferences
    @State private var mode: CompactNativePreviewMode = .expanded

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                HStack {
                    Text("Real").font(.system(size: 10, weight: .medium))
                    Spacer()
                    Image(systemName: "wifi").font(.system(size: 10))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .frame(height: 24)
                .accessibilityHidden(true)
                drawing
                    .frame(width: previewWidth)
                    .padding(.horizontal, 20)
            }
            .frame(maxWidth: .infinity, minHeight: screenHeight, alignment: .top)
            .background {
                LinearGradient(colors: [Color.primary.opacity(0.055), Color.primary.opacity(0.015)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            HStack(spacing: 14) {
                Text(tr("预览")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                ForEach(options) { option in
                    Button { mode = option.mode } label: {
                        Text(tr(option.title))
                            .font(.system(size: 11, weight: mode == option.mode ? .medium : .regular))
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(mode == option.mode ? Color.primary.opacity(0.07) : .clear,
                                        in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .disabled(!p.enabled(module) || !option.enabled)
                    .accessibilityAddTraits(mode == option.mode ? .isSelected : []).accessibilityRemoveTraits(mode == option.mode ? [] : .isSelected)
                }
            }.padding(.horizontal, 12).padding(.vertical, 9)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.08)))
        .onAppear(perform: normalizeMode)
        .onChange(of: module) { _, _ in mode = .expanded; normalizeMode() }
        .onChange(of: p.flags) { _, _ in normalizeMode() }
    }

    @ViewBuilder private var drawing: some View {
        if mode == .compact {
            collapsed
        } else if !p.enabled(module) {
            expandedIsland {
                VStack(spacing: 8) {
                    Image(systemName: "pause.circle")
                    Text(tr("已关闭"))
                }.font(.caption).frame(maxWidth: .infinity, minHeight: 72)
            }
        } else if module == "music", mode == .lyrics {
            VStack(spacing: 8) {
                collapsed
                KaraokeLyricText(lyric: karaokePreviewLine(tr("音乐响起，歌词随行")), time: 0.48,
                                 fontSize: lyricSize, weight: p.enabled("lyricsBold") ? .semibold : .regular,
                                 highlight: p.lyricsColor)
                    .frame(width: 250, height: ceil(lyricSize * 1.4))
                    .padding(.horizontal, 13).padding(.vertical, 6)
                    .background(.black.opacity(p.lyricsBackgroundOpacity), in: RoundedRectangle(cornerRadius: 7))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tr("悬浮歌词颜色预览"))
        } else {
            expandedIsland {
                VStack(alignment: .leading, spacing: 12) {
                    if p.enabled("showTabs") || p.enabled("islandSettings") { previewHeader }
                    expandedContent
                }
            }
        }
    }

    private var collapsed: some View {
        HStack {
            Spacer()
            if module == "music", p.enabled("music") {
                HStack(alignment: .center, spacing: 2) {
                    ForEach(Array([3.0, 7.0, 10.0, 6.0].enumerated()), id: \.offset) { item in
                        RoundedRectangle(cornerRadius: 1).fill(.white.opacity(0.6))
                            .frame(width: 2, height: item.element)
                    }
                }.padding(.trailing, 10).accessibilityHidden(true)
            }
        }
        .frame(width: 168, height: 25)
        .background(.black, in: UnevenRoundedRectangle(bottomLeadingRadius: 13, bottomTrailingRadius: 13))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("收起的灵动岛预览"))
    }

    private var previewHeader: some View {
        HStack(spacing: 7) {
            if p.enabled("showTabs") {
                Image(systemName: moduleIcon)
                Text(tr(moduleTitle))
            }
            Spacer()
            if module == "music", p.enabled("spectrum") {
                Image(systemName: "waveform").foregroundStyle(p.lyricsColor)
            }
            if p.enabled("islandSettings") { Image(systemName: "gearshape") }
        }
        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
        .accessibilityHidden(true)
    }

    @ViewBuilder private var expandedContent: some View {
        switch module {
        case "music": musicDrawing
        case "calendar": calendarDrawing
        case "shelf": shelfDrawing
        case "hud": hudDrawing
        case "mirror": mirrorDrawing
        default: EmptyView()
        }
    }

    private var musicDrawing: some View {
        HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 8)
                .fill(LinearGradient(colors: [Color(red: 0.83, green: 0.68, blue: 0.57),
                                               Color(red: 0.37, green: 0.48, blue: 0.43)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(Text("Real").font(.system(size: 12, design: .serif)).foregroundStyle(.white))
                .frame(width: 56, height: 66)
            VStack(alignment: .leading, spacing: 5) {
                Text(tr("示例歌曲")).font(.system(size: 12, weight: .medium))
                Text("Real Sessions").font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
                if p.enabled("lyrics") {
                    Text(tr("音乐响起，歌词随行"))
                        .font(.system(size: lyricSize, weight: p.enabled("lyricsBold") ? .semibold : .regular))
                        .foregroundStyle(p.lyricsColor).lineLimit(1)
                }
                ProgressView(value: 0.42).tint(.white.opacity(0.7)).padding(.top, 2)
                HStack(spacing: 12) {
                    ForEach(Array(controlSymbols.enumerated()), id: \.offset) { item in
                        Image(systemName: item.element).font(.system(size: 11))
                    }
                }.foregroundStyle(.white.opacity(0.7)).padding(.top, 3)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if p.enabled("calendar") {
                VStack(alignment: .leading, spacing: 7) {
                    Text(tr("今天")).font(.system(size: 11, weight: .medium))
                    Text(tr("阅读时间")).font(.system(size: 10))
                    Text("16:00 – 16:30").font(.system(size: 9)).foregroundStyle(.white.opacity(0.5))
                }.frame(width: 100, alignment: .leading)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("音乐界面示例，不控制实际播放。"))
    }

    private var calendarDrawing: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr("今天")).font(.system(size: 12, weight: .medium))
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    calendarEntry("阅读时间", time: "16:00 – 16:30")
                    if p.enabled("allDay") { calendarEntry("整理本周计划", time: tr("全天")) }
                    if p.enabled("reminders") {
                        calendarEntry("出门散步", time: "18:00")
                        if p.enabled("completed") { calendarEntry("整理桌面", time: tr("已完成"), completed: true) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 85).scrollDisabled(!p.enabled("calendarScroll"))
        }
    }

    private func calendarEntry(_ title: String, time: String, completed: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1).fill(.green.opacity(0.7)).frame(width: 2, height: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(tr(title)).font(.system(size: 11)).strikethrough(completed)
                    .lineLimit(p.enabled("fullTitles") ? nil : 1)
                Text(time).font(.system(size: 9)).foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private var shelfDrawing: some View {
        VStack(alignment: .leading, spacing: 9) {
            sampleFile("项目笔记.pdf", icon: "doc.text")
            sampleFile("灵感图片.png", icon: "photo")
        }
    }

    private func sampleFile(_ name: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 16))
            Text(tr(name)).font(.system(size: 11))
            Spacer()
        }
        .padding(9)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder private var hudDrawing: some View {
        if !p.enabled("volumeHUD") && !p.enabled("brightnessHUD") {
            Text(tr("尚未选择提示内容")).font(.caption)
                .frame(maxWidth: .infinity, minHeight: 52)
        } else {
            HStack(spacing: 14) {
                Image(systemName: mode == .brightness ? "sun.max.fill" : "speaker.wave.2.fill")
                ProgressView(value: mode == .brightness ? 0.75 : 0.6).tint(.white)
                if p.enabled("hudPercent") { Text(mode == .brightness ? "75%" : "60%").font(.caption) }
            }.padding(.vertical, 16)
        }
    }

    @ViewBuilder private var mirrorDrawing: some View {
        if mode == .idle {
            Image(systemName: "face.smiling").font(.system(size: 38))
                .frame(maxWidth: .infinity, minHeight: 78)
        } else {
            HStack(spacing: 18) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 36))
                    .frame(width: 72, height: 72)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: p.enabled("mirrorRound") ? 36 : 10))
                Text(tr("示意画面 · 未打开摄像头")).font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
            }
        }
    }

    private func expandedIsland<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 17).padding(.top, 12).padding(.bottom, 16)
            .foregroundStyle(.white)
            .background {
                UnevenRoundedRectangle(bottomLeadingRadius: 23, bottomTrailingRadius: 23).fill(.black)
                if module == "music", p.enabled("coverTint") {
                    UnevenRoundedRectangle(bottomLeadingRadius: 23, bottomTrailingRadius: 23)
                        .fill(LinearGradient(colors: [.brown.opacity(0.2), .clear], startPoint: .leading, endPoint: .trailing))
                }
                if module == "music", p.enabled("coverBlur") {
                    UnevenRoundedRectangle(bottomLeadingRadius: 23, bottomTrailingRadius: 23)
                        .fill(.white.opacity(0.025))
                }
            }
            .shadow(color: .black.opacity(p.enabled("shadow") ? 0.13 : 0), radius: 8, y: 6)
            .allowsHitTesting(false)
    }

    private var lyricSize: CGFloat { p.lyricsTextSize == "large" ? 15 : p.lyricsTextSize == "small" ? 10 : 12 }
    private var controlSymbols: [String] {
        let defaults = ["previous", "play", "next", "mute", "volume"]
        let symbols = ["previous": "backward.end.fill", "play": "pause.fill", "next": "forward.end.fill",
                       "mute": "speaker.slash.fill", "volume": "speaker.wave.2.fill"]
        return (0..<5).map { index in
            let key = p.controllerSlots.indices.contains(index) ? p.controllerSlots[index] : defaults[index]
            return symbols[key] ?? symbols[defaults[index]]!
        }
    }
    private var moduleTitle: String {
        ["music": "音乐与歌词", "calendar": "日历与提醒", "shelf": "文件暂存", "hud": "系统提示", "mirror": "镜子与趣味"][module] ?? "灵动岛"
    }
    private var moduleIcon: String {
        ["music": "music.note", "calendar": "calendar", "shelf": "tray", "hud": "slider.horizontal.3", "mirror": "person.crop.square"][module] ?? "circle"
    }
    private var previewWidth: CGFloat {
        module == "music" ? 420 : module == "calendar" ? 280 : module == "shelf" ? 340 : 270
    }
    private var screenHeight: CGFloat {
        if mode == .compact { return 88 }
        if mode == .lyrics { return 115 }
        return module == "music" ? 168 : module == "hud" ? 125 : 168
    }
    private var options: [CompactNativePreviewOption] {
        switch module {
        case "music":
            return [.init(.expanded, "展开"), .init(.compact, "收起")] + (p.enabled("lyrics") ? [.init(.lyrics, "悬浮歌词")] : [])
        case "hud":
            return [.init(.volume, "音量", enabled: p.enabled("volumeHUD")),
                    .init(.brightness, "亮度", enabled: p.enabled("brightnessHUD"))]
        case "mirror":
            return [.init(.expanded, "镜像画面"), .init(.compact, "收起")] + (p.enabled("idleFace") ? [.init(.idle, "闲置表情")] : [])
        case "calendar": return [.init(.expanded, "日程"), .init(.compact, "收起")]
        default: return [.init(.expanded, "暂存文件"), .init(.compact, "收起")]
        }
    }
    private func normalizeMode() {
        if !options.contains(where: { $0.mode == mode && $0.enabled }) {
            mode = options.first(where: \.enabled)?.mode ?? options.first?.mode ?? .expanded
        }
    }
}

private enum CompactNativePreviewMode: String {
    case expanded, compact, lyrics, volume, brightness, idle
}

private struct CompactNativePreviewOption: Identifiable {
    let mode: CompactNativePreviewMode
    let title: String
    let enabled: Bool
    var id: String { mode.rawValue }
    init(_ mode: CompactNativePreviewMode, _ title: String, enabled: Bool = true) {
        self.mode = mode; self.title = title; self.enabled = enabled
    }
}
