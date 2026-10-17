import AppKit
import SwiftUI

struct BrandMark: View {
    static let image = Bundle.main.url(forResource: "Real", withExtension: "icns")
        .flatMap(NSImage.init(contentsOf:)) ?? NSImage(size: NSSize(width: 38, height: 38))
    var size: CGFloat = 38
    var body: some View {
        Image(nsImage: BrandMark.image).resizable().interpolation(.high).scaledToFit().frame(width: size, height: size)
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var p: Preferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var searchText = ""
    @State private var searchPresented = false
    @State private var focusedSetting: String?
    @State private var navigationRequest = 0
    @State private var dockSection = "behavior"
    @State private var preferencesSection = "general"
    @State private var musicDetailsExpanded = false
    @State private var lyricDetailsExpanded = false
    @State private var appearanceDetailsExpanded = false
    private let modules = [("music", "音乐与歌词", "music.note"), ("hud", "系统提示", "slider.horizontal.3"), ("calendar", "日历与提醒", "calendar"), ("shelf", "文件暂存", "tray"), ("mirror", "镜子与趣味", "person.crop.square")]
    private let preferencePages = [("general", "通用", "slider.horizontal.3"), ("appearance", "灵动岛外观", "rectangle.topthird.inset.filled"), ("icons", "图标显示", "app"), ("runtime", "运行与权限", "checkmark.shield"), ("about", "关于 Real", "info.circle")]
    private var navigationKey: String { model.page + "|" + (model.page == "island" ? model.selectedModule : model.page == "dock" ? dockSection : preferencesSection) }
    private var title: String {
        switch model.page {
        case "dock": return dockSection == "exclusions" ? "排除应用" : "点击收起"
        case "preferences": return preferencePages.first { $0.0 == preferencesSection }?.1 ?? "通用"
        default: return modules.first { $0.0 == model.selectedModule }?.1 ?? "音乐与歌词"
        }
    }
    private var subtitle: String {
        switch model.page {
        case "dock": return dockSection == "exclusions" ? "这些应用保留原本的程序坞点击行为。" : "点一下收起当前桌面的应用窗口，再点一下原样恢复。"
        case "preferences":
            switch preferencesSection {
            case "appearance": return "调整灵动岛的展开方式与显示位置。"
            case "icons": return "图标的显示与隐藏，不影响后台运行。"
            case "runtime": return "查看运行状态，检查权限与连接。"
            case "about": return ""
            default: return "让 Real 按你的习惯，安静地运行。"
            }
        default:
            switch model.selectedModule {
            case "hud": return "在灵动岛显示音量与亮度变化。"
            case "calendar": return "选择你想在灵动岛查看的日程和提醒。"
            case "shelf": return "拖入文件，随时取用。"
            case "mirror": return "随时查看镜像画面，收起后释放摄像头。"
            default: return "控制播放来源，调整悬浮歌词的显示方式。"
            }
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                sidebar
                Divider()
                ScrollViewReader { reader in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            pageHeading
                            switch model.page {
                            case "dock": dockContent
                            case "preferences":
                                CompactPreferencesPage(model: model, p: p, section: preferencesSection, appearanceDetailsExpanded: $appearanceDetailsExpanded)
                            default:
                                CompactIslandSettings(model: model, p: p, musicDetailsExpanded: $musicDetailsExpanded, lyricDetailsExpanded: $lyricDetailsExpanded)
                            }
                        }.padding(.horizontal, 28).padding(.top, 25).padding(.bottom, 28)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }.accessibilityIdentifier("real.settings.content")
                        .task(id: navigationKey + "|" + (focusedSetting ?? "") + "|" + String(navigationRequest)) {
                            let target = focusedSetting ?? "settings.top"
                            try? await Task.sleep(nanoseconds: 70_000_000)
                            guard !Task.isCancelled else { return }
                            reader.scrollTo(target, anchor: .top)
                        }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.font(.system(size: 13)).tint(CompactStyle.accent)
            .background(CompactStyle.surface).frame(width: CompactStyle.contentSize.width)
            .frame(maxHeight: .infinity).environment(\.locale, p.locale)
            .alert(tr("提示"), isPresented: Binding(get: { !model.errorMessage.isEmpty }, set: { if !$0 { model.errorMessage = "" } })) {
                Button(tr("完成")) { model.errorMessage = "" }
            } message: { Text(model.errorMessage) }
    }
    private var toolbar: some View {
        ZStack {
            HStack(spacing: 8) {
                BrandMark(size: 27)
                Text("Real").font(.system(size: 17, weight: .medium))
                Spacer()
                Button { searchPresented.toggle() } label: {
                    Image(systemName: "magnifyingglass").frame(width: 30, height: 30).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(.secondary).help(tr("搜索设置"))
                    .accessibilityLabel(tr("搜索设置")).accessibilityIdentifier("real.settings.search.open")
                    .keyboardShortcut("f", modifiers: .command)
                    .popover(isPresented: $searchPresented, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 12) {
                            TextField(tr("搜索设置"), text: $searchText).textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("real.settings.search")
                            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                CompactNote(text: "输入关键词查找设置")
                            } else {
                                ScrollView { SettingsSearchResults(query: searchText, language: p.effectiveLanguage, onSelect: selectSearchResult) }.frame(maxHeight: 360)
                            }
                        }.padding(16).frame(width: 390).environment(\.locale, p.locale)
                    }
                Button { navigate("preferences") } label: {
                    Image(systemName: "gearshape").frame(width: 30, height: 30)
                        .background(model.page == "preferences" ? CompactStyle.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(model.page == "preferences" ? Color.primary : .secondary)
                    .help(tr("偏好设置")).accessibilityLabel(tr("偏好设置")).accessibilityIdentifier("real.nav.preferences")
            }
            HStack(spacing: 2) { topTab("dock", "程序坞"); topTab("island", "灵动岛") }
                .padding(3).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
        }.padding(.horizontal, 20).frame(height: 55)
    }
    private func topTab(_ id: String, _ label: String) -> some View {
        Button { navigate(id) } label: {
            Text(tr(label)).font(.system(size: 12.5, weight: .medium)).fixedSize().frame(minWidth: 78, minHeight: 28).padding(.horizontal, 10)
                .background(model.page == id ? CompactStyle.surface : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(model.page == id ? Color.primary : .secondary)
            .accessibilityIdentifier("real.nav." + id).accessibilityAddTraits(model.page == id ? .isSelected : []).accessibilityRemoveTraits(model.page == id ? [] : .isSelected)
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(tr(model.page == "dock" ? "程序坞" : model.page == "preferences" ? "偏好设置" : "灵动岛"))
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 5)
            if model.page == "dock" {
                sideButton("behavior", "点击收起", "rectangle.on.rectangle", selected: dockSection) { dockSection = "behavior" }
                sideButton("exclusions", "排除应用", "line.3.horizontal.decrease.circle", selected: dockSection) { dockSection = "exclusions" }
            } else if model.page == "preferences" {
                ForEach(preferencePages, id: \.0) { page in
                    sideButton(page.0, page.1, page.2, selected: preferencesSection) { preferencesSection = page.0 }
                }
            } else {
                ForEach(modules, id: \.0) { module in
                    sideButton(module.0, module.1, module.2, selected: model.selectedModule) { model.selectedModule = module.0 }
                }
            }
            Spacer()
            Text(AppVersion.label).font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 10)
        }.padding(.horizontal, 10).padding(.top, 23).padding(.bottom, 18)
            .frame(width: CompactStyle.sidebarWidth).frame(maxHeight: .infinity).background(CompactStyle.rail)
    }
    private func sideButton(_ id: String, _ title: String, _ icon: String, selected: String, action: @escaping () -> Void) -> some View {
        Button { focusedSetting = nil; action() } label: {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 13)).frame(width: 15).foregroundStyle(selected == id ? CompactStyle.accent : Color.secondary)
                Text(tr(title)).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }.padding(.horizontal, 10).padding(.vertical, 8).frame(minHeight: 35)
                .background(selected == id ? CompactStyle.selected : .clear, in: RoundedRectangle(cornerRadius: 6)).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(selected == id ? Color.primary : .secondary)
            .accessibilityIdentifier("real.sidebar." + id).accessibilityAddTraits(selected == id ? .isSelected : []).accessibilityRemoveTraits(selected == id ? [] : .isSelected)
    }
    private var pageHeading: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(tr(title)).font(.system(size: 21, weight: .medium))
                if !subtitle.isEmpty { Text(tr(subtitle)).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 0)
            if model.page == "island" || (model.page == "dock" && dockSection == "behavior") {
                Toggle(tr("启用"), isOn: p.binding(model.page == "dock" ? "dockEnabled" : model.selectedModule))
                    .toggleStyle(.switch).controlSize(.small).fixedSize()
                    .accessibilityLabel(tr(model.page == "dock" ? "启用点击收起" : title))
                    .accessibilityIdentifier("real.module.enabled")
            }
        }
    }
    @ViewBuilder private var dockContent: some View {
        if dockSection == "exclusions" {
            CompactSection(title: "") {
                AppExclusionPicker(selection: $p.excludedApps, showsDescription: false)
                DisclosureGroup(tr("高级：手动编辑排除标识")) {
                    TextField(tr("排除应用的标识，用逗号分隔"), text: $p.excludedApps).textFieldStyle(.roundedBorder).padding(.vertical, 9)
                }.padding(.top, 10)
            }.id("dock.behavior")
        } else {
            DockBehaviorPreview()
            CompactSection(title: "点击行为") {
                CompactNote(text: "只处理当前桌面的普通窗口；恢复同一组，保留原本手动最小化的窗口。")
                CompactDockStatus(engine: model.dock)
            }.id("dock.behavior")
        }
    }
    private func navigate(_ page: String) { searchPresented = false; searchText = ""; focusedSetting = nil; model.page = page }
    private func selectSearchResult(_ entry: SettingsSearchEntry) {
        focusedSetting = nil
        model.page = entry.page
        if let module = entry.module { model.selectedModule = module }
        if entry.id == "dock.exclusions" { dockSection = "exclusions" }
        else if entry.page == "dock" { dockSection = "behavior" }
        if entry.anchor == "dock.presence" { model.page = "preferences"; preferencesSection = "icons" }
        else if entry.anchor == "island.appearance" { model.page = "preferences"; preferencesSection = "appearance" }
        else if entry.page == "preferences" {
            switch entry.anchor {
            case "permissions", "runtime.health", "runtime.diagnostics": preferencesSection = "runtime"
            case "preferences.support", "preferences.uninstall": preferencesSection = "about"
            default: preferencesSection = "general"
            }
        }
        if entry.expand == "music" { musicDetailsExpanded = true }
        if entry.id == "music.lyrics.sync" { lyricDetailsExpanded = true }
        if entry.expand == "appearance" { appearanceDetailsExpanded = true }
        searchPresented = false; searchText = ""; focusedSetting = entry.anchor; navigationRequest += 1
    }
}
private struct CompactDockStatus: View {
    @ObservedObject var engine: DockEngine
    @ObservedObject private var p = Preferences.shared
    var body: some View { Text(StatusCopy.text(engine.status, language: p.effectiveLanguage, translations: Copy.translations)).font(.system(size: 11.5)).foregroundStyle(.secondary).textSelection(.enabled).padding(.vertical, 7) }
}
private struct DockBehaviorPreview: View {
    @ObservedObject private var preferences = Preferences.shared
    @State private var minimized = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                ForEach(0..<2) { _ in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 4) { ForEach(0..<3) { _ in Circle().fill(.secondary.opacity(0.3)).frame(width: 5, height: 5) }; Spacer() }
                        Divider()
                        RoundedRectangle(cornerRadius: 2).fill(.secondary.opacity(0.12)).frame(width: 56, height: 4)
                        RoundedRectangle(cornerRadius: 2).fill(.secondary.opacity(0.09)).frame(width: 80, height: 4)
                        Spacer(minLength: 0)
                    }.padding(9).frame(width: 130, height: 78)
                        .background(CompactStyle.surface, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.primary.opacity(0.1)))
                        .scaleEffect(minimized ? 0.15 : 1, anchor: .bottom).opacity(minimized ? 0 : 1).accessibilityHidden(true)
                }
            }.frame(height: 90)
            Button(tr(minimized ? "演示恢复" : "演示收起")) {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { minimized.toggle() }
            }.controlSize(.small)
            Text(tr("仅演示，不操作其他应用窗口。")).font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(18).frame(maxWidth: .infinity).background(CompactStyle.rail, in: RoundedRectangle(cornerRadius: 9))
    }
}
