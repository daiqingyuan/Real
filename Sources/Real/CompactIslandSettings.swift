import AppKit
import SwiftUI

/// Settings are real preference bindings. The visual sample above them has no
/// access to players, the camera, the file shelf, or permission coordinators.
struct CompactIslandSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject var p: Preferences
    @Binding var musicDetailsExpanded: Bool
    @Binding var lyricDetailsExpanded: Bool
    @State private var showingMediaPreferences = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            CompactIslandPreview(module: model.selectedModule, p: p)
            moduleSettings
                .disabled(!p.enabled(model.selectedModule))
        }
        .id("module.\(model.selectedModule)")
        .environment(\.locale, p.locale)
        .sheet(isPresented: $showingMediaPreferences) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(tr("播放器连接与控制")).font(.headline)
                    Spacer()
                    Button(tr("完成")) { showingMediaPreferences = false }
                        .keyboardShortcut(.defaultAction)
                }
                Divider()
                ScrollView {
                    MediaPreferencesView(media: model.media, youtube: model.youtube,
                                         preferences: p, preview: model.previewOnly)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, 4)
                }
            }
            .padding(24)
            .frame(width: 540, height: 500)
            .environment(\.locale, p.locale)
        }
    }

    @ViewBuilder private var moduleSettings: some View {
        switch model.selectedModule {
        case "music": musicSettings
        case "calendar": calendarSettings
        case "shelf": shelfSettings
        case "hud": hudSettings
        case "mirror": mirrorSettings
        default: EmptyView()
        }
    }

    private var musicSettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            CompactSection(title: "播放") {
                settingRow("播放来源") {
                    Picker(tr("播放来源"), selection: $p.mediaSource) {
                        Text(tr("自动跟随正在播放的应用")).tag("auto")
                        Text(tr("QQ 音乐")).tag("qq")
                        Text(tr("网易云音乐")).tag("netease")
                        Text("YTMDesktop").tag("ytm")
                    }
                    .labelsHidden()
                    .frame(maxWidth: 230)
                    .disabled(model.previewOnly)
                }
                CompactNativeMediaStatus(service: model.media)
            }

            CompactSection(title: "悬浮歌词") {
                CompactToggle(p: p, key: "lyrics", title: "歌词")
                    .id("music.lyrics")
                if p.enabled("lyrics") {
                    settingRow("歌词字号") {
                        Picker(tr("歌词字号"), selection: $p.lyricsTextSize) {
                            Text(tr("小")).tag("small")
                            Text(tr("标准")).tag("standard")
                            Text(tr("大")).tag("large")
                        }.labelsHidden().frame(width: 120)
                    }
                    settingRow("歌词高亮颜色") {
                        HStack(spacing: 12) {
                            Button { LyricsColorPanel.shared.show(for: p) } label: {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(p.lyricsColor)
                                    .frame(width: 34, height: 21)
                                    .overlay(RoundedRectangle(cornerRadius: 5)
                                        .strokeBorder(.primary.opacity(0.15)))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(tr("打开歌词色盘"))
                            .help(tr("打开歌词色盘"))
                            Toggle(tr("歌词加粗"), isOn: p.binding("lyricsBold"))
                                .toggleStyle(.checkbox)
                        }
                    }
                    QQLyricsStrip(player: model.desktopPlayer, lyrics: model.lyrics, preferences: p,
                                  previewText: model.liveQQPreview ? nil : tr("音乐响起，歌词随行"))
                        .frame(maxWidth: 270)
                        .padding(.vertical, 4)
                        .accessibilityLabel(tr("悬浮歌词颜色预览"))
                    DisclosureGroup(tr("歌词显示与同步"), isExpanded: $lyricDetailsExpanded) {
                        VStack(alignment: .leading, spacing: 12) {
                            settingRow("背景深浅") {
                                Slider(value: $p.lyricsBackgroundOpacity, in: 0...0.9)
                                    .frame(width: 170)
                                    .accessibilityLabel(tr("背景深浅"))
                            }
                            CompactNativeLyricSync(playerKey: model.currentLyricTrackKey, p: p)
                            Button(tr("恢复默认粉色")) { p.resetLyricsColor() }
                                .disabled(p.lyricsColorRGB == Preferences.defaultLyricsColorRGB)
                        }.padding(.top, 10)
                    }.padding(.vertical, 7)
                }
                if model.previewOnly {
                    Button(tr(model.liveQQPreview ? "停止 QQ 歌词预览" : "实时预览 QQ 歌词")) {
                        model.toggleQQPreview()
                    }
                    .disabled(!p.enabled("music"))
                    .padding(.vertical, 7)
                    CompactNote(text: "读取 QQ 当前歌曲和歌词，播放控制与窗口控制保持关闭。")
                }
            }

            DisclosureGroup(tr("更多音乐设置"), isExpanded: $musicDetailsExpanded) {
                VStack(alignment: .leading, spacing: 20) {
                    CompactSection(title: "播放器外观") {
                        CompactToggle(p: p, key: "coverTint", title: "播放器跟随封面配色")
                        CompactToggle(p: p, key: "coverBlur", title: "封面背景模糊")
                        CompactToggle(p: p, key: "hideFullscreen", title: "全屏时隐藏")
                        settingRow("暂停后保留音乐状态") {
                            Picker(tr("暂停后保留音乐状态"), selection: $p.musicIdleTimeout) {
                                Text(tr("始终保留")).tag(0.0)
                                Text(tr("15 秒")).tag(15.0)
                                Text(tr("30 秒")).tag(30.0)
                                Text(tr("1 分钟")).tag(60.0)
                                Text(tr("5 分钟")).tag(300.0)
                            }.labelsHidden().frame(width: 145)
                        }
                    }
                    CompactSection(title: "声音频谱") {
                        CompactToggle(p: p, key: "spectrum", title: "彩色频谱")
                        CompactNativeSpectrumControls(service: model.spectrum, p: p,
                                                      preview: model.previewOnly)
                    }
                    CompactSection(title: "播放器连接与控制") {
                        Button(tr("管理播放器连接与控制…")) { showingMediaPreferences = true }
                            .padding(.vertical, 6)
                        CompactNote(text: "设置播放来源、播放器授权与五个控制位置。")
                    }
                }.padding(.top, 15)
            }
            .padding(.vertical, 4)
            .id("music.playback")
        }
    }

    private var calendarSettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            CompactSection(title: "显示内容") {
                CompactToggle(p: p, key: "allDay", title: "显示全天日程")
                CompactToggle(p: p, key: "reminders", title: "显示提醒事项")
                CompactToggle(p: p, key: "completed", title: "显示已完成事项")
                CompactToggle(p: p, key: "fullTitles", title: "显示完整标题")
                CompactToggle(p: p, key: "calendarScroll", title: "允许滚动日历")
            }
            CompactSection(title: "来源与权限") {
                Button(tr("允许访问日历与提醒事项")) {
                    guard !model.previewOnly else { return }
                    model.calendar.requestAccess()
                }
                    .disabled(model.previewOnly)
                    .padding(.vertical, 7)
                CompactNativeCalendarSources(service: model.calendar, p: p)
            }
        }
    }

    private var shelfSettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            CompactSection(title: "拖放行为") {
                CompactToggle(p: p, key: "shelfOnDrag", title: "拖入时展开")
                CompactToggle(p: p, key: "shelfCopy", title: "拖出时复制")
            }
            CompactSection(title: "文件暂存") {
                Button(tr("添加文件"), action: chooseFiles).padding(.vertical, 7)
                CompactToggle(p: p, key: "shelfRemove", title: "使用后自动移除")
                CompactToggle(p: p, key: "shelfPriority", title: "有文件时优先显示")
                CompactToggle(p: p, key: "shelfLargeTarget", title: "扩大文件拖入区域")
            }
        }
    }

    private var hudSettings: some View {
        CompactSection(title: "提示内容") {
            CompactToggle(p: p, key: "volumeHUD", title: "音量提示")
            CompactToggle(p: p, key: "brightnessHUD", title: "亮度提示")
            CompactToggle(p: p, key: "hudPercent", title: "显示百分比")
            Button(tr("预览系统提示")) {
                model.showHUD("speaker.wave.2.fill", value: model.system.volume)
            }.padding(.vertical, 7)
        }
    }

    private var mirrorSettings: some View {
        CompactSection(title: "镜子与闲置显示") {
            CompactToggle(p: p, key: "mirrorRound", title: "圆形镜子")
            CompactToggle(p: p, key: "idleFace", title: "闲置时显示表情")
            CompactNote(text: "摄像头仅在打开镜子时运行。")
        }
    }

    private func settingRow<Control: View>(_ title: String,
                                          @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 16) {
            Text(tr(title))
            Spacer(minLength: 12)
            control()
        }.padding(.vertical, 8)
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        if panel.runModal() == .OK { model.shelf.add(urls: panel.urls) }
    }
}

private struct CompactNativeMediaStatus: View {
    @ObservedObject var service: MediaService
    @ObservedObject private var p = Preferences.shared
    var body: some View {
        if let message = service.errorMessage, !message.isEmpty {
            Text(StatusCopy.text(message, language: p.effectiveLanguage, translations: Copy.translations)).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if !service.sourceName.isEmpty {
            Text(StatusCopy.text(service.sourceName, language: p.effectiveLanguage, translations: Copy.translations)).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct CompactNativeCalendarSources: View {
    @ObservedObject var service: CalendarService
    @ObservedObject var p: Preferences
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(StatusCopy.text(service.status, language: p.effectiveLanguage,
                                 translations: Copy.translations))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup(tr("选择日历与提醒列表")) {
                if service.availableCalendars.isEmpty {
                    CompactNote(text: "尚无可用的日历或提醒列表。")
                } else {
                    ForEach(service.availableCalendars) { calendar in
                        Toggle(calendar.title, isOn: Binding(get: {
                            service.selectedCalendarIDs.contains(calendar.id)
                        }, set: { enabled in
                            if enabled { service.selectedCalendarIDs.insert(calendar.id) }
                            else { service.selectedCalendarIDs.remove(calendar.id) }
                        }))
                        .toggleStyle(.checkbox)
                        .padding(.vertical, 5)
                    }
                }
            }.padding(.vertical, 6)
        }
    }
}

private struct CompactNativeSpectrumControls: View {
    @ObservedObject var service: AudioSpectrumService
    @ObservedObject var p: Preferences
    let preview: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CompactNote(text: "频谱来自系统播放的声音，每次需要时手动开启。")
            Button(tr(service.isRunning || service.isStarting ? "停止声音频谱" : "开启声音频谱")) {
                if service.isRunning || service.isStarting { service.stop() }
                else { service.start() }
            }.disabled(preview)
            if !service.status.isEmpty {
                Text(StatusCopy.text(service.status, language: p.effectiveLanguage,
                                     translations: Copy.translations))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.vertical, 7)
    }
}

private struct CompactNativeLyricSync: View {
    let playerKey: String
    @ObservedObject var p: Preferences
    private var offset: Double { p.lyricOffset(for: playerKey) }
    private var offsetText: String {
        if offset == 0 { return tr("未调整") }
        return String(format: tr(offset > 0 ? "提前 %.1f 秒" : "延后 %.1f 秒"), abs(offset))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(tr("本曲歌词同步"))
                Spacer()
                Text(offsetText).monospacedDigit().foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button(tr("提前 0.2 秒")) { adjust(0.2) }
                    .disabled(playerKey.isEmpty || offset >= 5)
                Button(tr("延后 0.2 秒")) { adjust(-0.2) }
                    .disabled(playerKey.isEmpty || offset <= -5)
                Button(tr("重置")) { p.setLyricOffset(0, for: playerKey) }
                    .disabled(playerKey.isEmpty || offset == 0)
            }
            CompactNote(text: playerKey.isEmpty ? "播放音乐后可调整当前歌曲。" : "仅调整歌词显示，不改变播放进度。")
        }
    }
    private func adjust(_ change: Double) {
        guard !playerKey.isEmpty else { return }
        p.setLyricOffset(LyricDisplayPolicy.clampedOffset(offset + change), for: playerKey)
    }
}
