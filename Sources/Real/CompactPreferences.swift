import AppKit
import SwiftUI

/// Preference destinations for the compact shell. The shell owns navigation,
/// headings, scrolling, and search; this view only binds the existing settings
/// and actions. Reading or switching a section has no side effects.
struct CompactPreferencesPage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var p: Preferences
    let section: String
    @Binding var appearanceDetailsExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            switch section {
            case "appearance": appearance
            case "icons": icons
            case "runtime": runtime
            case "about": about
            default: general
            }
        }
        .font(.system(size: 13))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var general: some View {
        CompactSection(title: "语言与启动") {
            HStack(spacing: 12) {
                Text(tr("界面语言"))
                Spacer(minLength: 12)
                Picker(tr("界面语言"), selection: $p.language) {
                    Text(tr("跟随系统")).tag("system")
                    Text("简体中文").tag("zh-Hans")
                    Text("English").tag("en")
                    Text("日本語").tag("ja")
                    Text("Русский").tag("ru")
                }
                .labelsHidden().frame(width: 160)
                .accessibilityLabel(tr("界面语言"))
            }.padding(.vertical, 9)
            Divider()
            HStack(spacing: 12) {
                Text(tr("登录时启动"))
                Spacer(minLength: 12)
                Toggle(tr("登录时启动"), isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(model.previewOnly)
            }.padding(.vertical, 9)
            Divider()
            CompactToggle(p: p, key: "intro", title: "首次打开时显示品牌动画")
            CompactNote(text: "登录后直接在后台运行，不弹窗口或播放动画。")
        }.id("preferences.general")
    }

    private var appearance: some View {
        VStack(alignment: .leading, spacing: 20) {
            CompactSection(title: "外观与展开方式") {
                CompactToggle(p: p, key: "hover", title: "悬停时展开")
                HStack(spacing: 12) {
                    Text(tr("展开等待"))
                    Spacer(minLength: 12)
                    Text(String(format: "%.1f s", p.hoverDelay))
                        .foregroundStyle(.secondary).monospacedDigit().frame(minWidth: 34, alignment: .trailing)
                    Slider(value: $p.hoverDelay, in: 0...1.5, step: 0.1)
                        .frame(width: 120).accessibilityLabel(tr("展开等待"))
                }.padding(.vertical, 9)
                Divider()
                CompactToggle(p: p, key: "allDisplays", title: "在所有显示器上显示")
                if !p.enabled("allDisplays") {
                    HStack(spacing: 12) {
                        Text(tr("首选显示器"))
                        Spacer(minLength: 12)
                        Picker(tr("首选显示器"), selection: $p.selectedDisplay) {
                            Text(tr("主显示器")).tag("")
                            ForEach(NSScreen.screens, id: \.self) { screen in
                                Text(screen.localizedName).tag(DisplayPolicy.identifier(for: screen))
                            }
                        }
                        .labelsHidden().frame(maxWidth: 220)
                        .accessibilityLabel(tr("首选显示器"))
                    }.padding(.vertical, 9)
                    Divider()
                }
            }
            DisclosureGroup(tr("更多外观设置"), isExpanded: $appearanceDetailsExpanded) {
                VStack(alignment: .leading, spacing: 0) {
                    CompactToggle(p: p, key: "automaticDisplay", title: "自动切换显示器")
                    CompactToggle(p: p, key: "haptics", title: "触觉反馈")
                    CompactToggle(p: p, key: "rememberTab", title: "记住上次标签页")
                    CompactToggle(p: p, key: "showTabs", title: "始终显示标签页")
                    CompactToggle(p: p, key: "islandSettings", title: "显示设置入口")
                    CompactToggle(p: p, key: "shadow", title: "显示阴影")
                    CompactToggle(p: p, key: "hideLocked", title: "锁屏时隐藏")
                    HStack(spacing: 12) {
                        Text(tr("灵动岛高度"))
                        Spacer(minLength: 12)
                        Text(p.islandHeight == 0 ? tr("自动") : "\(Int(p.islandHeight))")
                            .foregroundStyle(.secondary).monospacedDigit().frame(minWidth: 36, alignment: .trailing)
                        Slider(value: $p.islandHeight, in: 0...60, step: 1)
                            .frame(width: 120).accessibilityLabel(tr("灵动岛高度"))
                    }.padding(.vertical, 9)
                    Divider()
                }.padding(.top, 5)
            }
            .font(.system(size: 13))
        }.id("island.appearance")
    }

    private var icons: some View {
        CompactSection(title: "Real 的图标") {
            CompactToggle(p: p, key: "dockIcon", title: "在程序坞中显示")
            CompactToggle(p: p, key: "menuIcon", title: "在菜单栏中显示")
            CompactNote(text: "隐藏图标或关闭设置窗口，后台继续运行。只有退出才结束。")
        }.id("dock.presence")
    }

    private var runtime: some View {
        VStack(alignment: .leading, spacing: 20) {
            CompactSection(title: "运行自检") {
                RuntimeHealthView(engine: model.dock, preview: model.previewOnly,
                                  onCheck: model.checkRuntime, onRepair: model.repairRuntime)
                    .padding(.vertical, 8)
                Divider()
                RuntimeMediaStatusView(player: model.desktopPlayer, media: model.media,
                                       youtube: model.youtube, lyrics: model.lyrics,
                                       preferences: p, usingDesktop: model.usingDesktopPlayer,
                                       preview: model.previewOnly)
                    .padding(.vertical, 10)
            }.id("runtime.health")
            PermissionStatusCard(coordinator: model.permissions, preferences: p)
                .id("permissions")
            CompactSection(title: "导出诊断") {
                HStack(spacing: 12) {
                    Button(tr("导出诊断")) { model.exportDiagnostics() }
                    Spacer(minLength: 0)
                }.padding(.vertical, 9)
            }.id("runtime.diagnostics")
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 20) {
            CompactSection(title: "") {
                HStack(spacing: 12) {
                    Text(tr("版本"))
                    Spacer(minLength: 12)
                    Text(AppVersion.version).foregroundStyle(.secondary)
                }.padding(.vertical, 9)
                Divider()
                Text(tr("由 dan 创作")).padding(.vertical, 9)
                Divider()
                HStack(spacing: 12) {
                    Button(tr("退出 Real")) { NSApp.terminate(nil) }
                    Spacer(minLength: 0)
                }.padding(.vertical, 9)
            }.id("preferences.support")
            CompactSection(title: "卸载 Real") {
                CompactNote(text: "不再使用？可以安全移除应用，并选择是否保留设置。")
                HStack(spacing: 12) {
                    Button(tr("卸载 Real…"), role: .destructive) { model.showUninstall?() }
                        .disabled(model.previewOnly)
                    Spacer(minLength: 0)
                }.padding(.vertical, 9)
                if model.previewOnly {
                    CompactNote(text: "请从正在使用的 Real 中卸载；预览不会移除日常版本。")
                }
            }.id("preferences.uninstall")
        }
    }
}
