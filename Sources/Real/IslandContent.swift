import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct IslandContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject var p: Preferences
    let expanded: Bool
    var demo = false
    @State private var demoTab = "music"
    private var selectedTab: String { demo ? demoTab : model.islandTab }
    var topInset: CGFloat = 32
    var notchWidth: CGFloat = 185
    var popoverChanged: (Bool) -> Void = { _ in }
    var body: some View {
        VStack(spacing: 0) {
            if expanded { header }
            Group {
                if let hud = model.hud {
                    HStack(spacing: 14) { Image(systemName: hud.0); ProgressView(value: hud.1).tint(.white); if p.enabled("hudPercent") { Text("\(Int(hud.1 * 100))%").font(.caption).monospacedDigit() } }
                } else if !expanded {
                    CompactIsland(media: model.media, youtube: model.youtube, player: model.desktopPlayer, p: p, recentlyActive: model.mediaRecentlyActive, useDesktop: model.usingDesktopPlayer)
                } else {
                    switch selectedTab {
                    case "calendar": CalendarContent(service: model.calendar, p: p, demo: demo).disabled(demo).allowsHitTesting(!demo)
                    case "shelf": ShelfContent(service: model.shelf, p: p, demo: demo).disabled(demo).allowsHitTesting(!demo)
                    case "empty": Text("Real").font(.headline).frame(height: 130)
                    case "mirror": MirrorContent(service: model.mirror, p: p, demo: demo)
                    default:
                        HStack(alignment: .top, spacing: 22) {
                            PlayerView(spectrum: model.spectrum, player: model.desktopPlayer, media: model.media, youtube: model.youtube, lyrics: model.lyrics, system: model.system, preferences: p, demo: demo && !model.liveQQPreview && model.previewOnly, useDesktopPlayer: model.usingDesktopPlayer, interactionEnabled: !demo, popoverChanged: popoverChanged)
                                .frame(maxWidth: .infinity)
                            if p.enabled("calendar") {
                                CalendarContent(service: model.calendar, p: p, demo: demo).frame(width: 185).disabled(demo).allowsHitTesting(!demo)
                            }
                        }
                    }
                }
            }.padding(.horizontal, expanded ? 22 : 6).padding(.top, expanded ? 10 : 2).padding(.bottom, expanded ? 18 : 2)
        }.frame(maxWidth: .infinity)
            .foregroundStyle(.white).background(.black, in: UnevenRoundedRectangle(bottomLeadingRadius: expanded ? 26 : 14, bottomTrailingRadius: expanded ? 26 : 14))
            // Scope the island's dark styling to its subtree. A preferred
            // scheme propagates to the hosting window, including Settings
            // when this component is embedded as the live preview.
            .environment(\.colorScheme, .dark).environment(\.locale, p.locale)
    }
    private var header: some View {
        HStack(spacing: 0) {
            HStack(spacing: 14) {
                if p.enabled("showTabs") || selectedTab != "music" {
                    if p.enabled("music") { tab("music", "music.note", "音乐与歌词") }
                    if p.enabled("calendar") && !p.enabled("music") { tab("calendar", "calendar", "日历与提醒") }
                    if p.enabled("shelf") { tab("shelf", "tray", "文件暂存") }
                    if p.enabled("mirror") { tab("mirror", "person.crop.square", "镜子与趣味") }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: notchWidth).accessibilityHidden(true)
            HStack(spacing: 12) {
                if p.enabled("islandSettings") { Button { model.showSettings?() } label: { Image(systemName: "gearshape") }.help(tr("偏好设置")) }
            }.frame(maxWidth: .infinity, alignment: .trailing)
        }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
            .padding(.horizontal, 22).frame(height: max(30, topInset))
    }
    private func tab(_ id: String, _ icon: String, _ title: String) -> some View {
        Button {
            if demo { withAnimation(.easeInOut(duration: 0.18)) { demoTab = id }; return }
            if model.islandTab == "mirror" { model.mirror.stop() }
            withAnimation(.easeInOut(duration: 0.18)) { model.islandTab = id }
            if id == "mirror", !demo { model.mirror.start() }
            if p.enabled("rememberTab") { UserDefaults.standard.set(id, forKey: "islandTab") }
        } label: { Image(systemName: icon).foregroundStyle(selectedTab == id ? .white : .white.opacity(0.45)) }.help(tr(title))
    }
}

private struct CompactIsland: View {
    @ObservedObject var media: MediaService
    @ObservedObject var youtube: YouTubeMusicService
    @ObservedObject var player: QQPlaybackService
    @ObservedObject var p: Preferences
    let recentlyActive: Bool
    let useDesktop: Bool
    private var playing: Bool { p.enabled("music") && (useDesktop ? player.isPlaying : p.mediaSource == "ytm" ? youtube.isPlaying : media.isPlaying) }
    var body: some View {
        HStack(spacing: 0) {
            if !playing && !recentlyActive && p.enabled("idleFace") {
                Image(systemName: "face.smiling").font(.system(size: 11)).frame(width: 26)
            }
            Spacer(minLength: 12)
            if playing { Image(systemName: "waveform").font(.system(size: 12)).foregroundStyle(p.lyricsColor.opacity(0.8)).frame(width: 26) }
        }
    }
}

private struct CalendarContent: View {
    @ObservedObject var service: CalendarService
    @ObservedObject var p: Preferences
    let demo: Bool
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                Text(Date(), format: .dateTime.month().day().weekday()).font(.headline)
                ForEach(service.events.filter { p.enabled("allDay") || !$0.isAllDay }.prefix(20)) { event in
                    HStack(alignment: .top) {
                        RoundedRectangle(cornerRadius: 2).fill(.blue).frame(width: 3)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(event.title).font(.system(size: 13)).lineLimit(p.enabled("fullTitles") ? nil : 1)
                            Text(event.isAllDay ? tr("全天") : event.start.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(p.locale))).font(.caption).foregroundStyle(.white.opacity(0.55))
                        }
                        Spacer()
                    }
                }
                if p.enabled("reminders") {
                    ForEach(service.reminders.filter { p.enabled("completed") || !$0.completed }.prefix(15)) { reminder in
                        Button { guard !demo else { return }; service.completeReminder(id: reminder.id, completed: !reminder.completed) } label: {
                            HStack { Image(systemName: reminder.completed ? "checkmark.circle.fill" : "circle"); Text(reminder.title).strikethrough(reminder.completed); Spacer() }
                        }.buttonStyle(.plain).font(.system(size: 13))
                    }
                }
                if service.events.isEmpty && service.reminders.isEmpty { Text(StatusCopy.text(service.status, language: p.effectiveLanguage, translations: Copy.translations)).font(.caption).foregroundStyle(.white.opacity(0.55)); Button(tr("允许访问日历与提醒事项")) { if !demo { service.requestAccess() } } }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.frame(height: 140).scrollDisabled(!p.enabled("calendarScroll"))
    }
}

private struct ShelfContent: View {
    @ObservedObject var service: ShelfService
    @ObservedObject var p: Preferences
    let demo: Bool
    @State private var targeted = false
    var body: some View {
        VStack(spacing: 12) {
            if service.items.isEmpty { VStack(spacing: 10) { Image(systemName: "tray.and.arrow.down").font(.largeTitle); Text(tr("拖入文件，随时取用")).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, minHeight: 100) }
            else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(service.items) { item in
                            HStack {
                                if demo { Text(item.name).font(.system(size: 12)).lineLimit(1) }
                                else { ShelfDragHandle(item: item, service: service, preferences: p).frame(height: 28) }
                                Spacer()
                                Button { if !demo { service.share(id: item.id) } } label: { Image(systemName: "square.and.arrow.up") }.help(tr("分享"))
                                Button { if !demo { service.remove(id: item.id) } } label: { Image(systemName: "xmark") }.help(tr("移除"))
                            }.buttonStyle(.plain).padding(8).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                                .contextMenu { Button(tr("快速查看")) { if !demo { service.preview(id: item.id) } }; Button(tr("打开")) { if !demo { service.open(id: item.id) } }; Button(tr("在 Finder 中显示")) { if !demo { service.reveal(id: item.id) } }; Button(tr("分享")) { if !demo { service.share(id: item.id) } }; Button(tr("移除")) { if !demo { service.remove(id: item.id) } } }
                        }
                    }
                }.frame(maxHeight: 160)
            }
            if !service.status.isEmpty { Text(service.status).font(.caption).foregroundStyle(.orange) }
        }.frame(maxWidth: .infinity).padding(8).background(targeted ? .white.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 12))
            .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in !demo && acceptFiles(providers, service: service) }
    }
}

@MainActor func acceptFiles(_ providers: [NSItemProvider], service: ShelfService) -> Bool {
    guard !ShelfDragPolicy.isDraggingFromShelf else { return false }
    let matching = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
    for provider in matching {
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?
            if let value = item as? URL { url = value }
            else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
            else { url = nil }
            if let url { Task { @MainActor in service.add(urls: [url]) } }
        }
    }
    return !matching.isEmpty
}

private struct MirrorContent: View {
    @ObservedObject var service: MirrorService
    @ObservedObject var p: Preferences
    let demo: Bool
    @State private var previewID = UUID()
    var body: some View {
        VStack {
            if service.active && !demo { CameraSurface(session: service.session).frame(width: 155, height: 155).clipShape(RoundedRectangle(cornerRadius: p.enabled("mirrorRound") ? 78 : 16)) }
            else { Image(systemName: "person.crop.circle").font(.system(size: 55)).frame(height: 120); if !demo { Button(tr("打开镜子")) { service.start() } } }
            if !service.status.isEmpty { Text(service.status).font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity).onAppear { if !demo { service.retainPreview(previewID) } }.onDisappear { if !demo { service.releasePreview(previewID) } }
    }
}
