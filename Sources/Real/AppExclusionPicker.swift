import AppKit
import SwiftUI

/// A compact entry point replacing the bundle-ID text field. Changes inside
/// the sheet take effect immediately; closing, searching, scanning, and opening
/// the sheet do not write the binding.
@MainActor
struct AppExclusionPicker: View {
    @Binding var selection: String
    var showsDescription = true
    @ObservedObject private var preferences = Preferences.shared
    @State private var showingApplications = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if showsDescription {
                VStack(alignment: .leading, spacing: 3) {
                    Text(tr("排除应用"))
                    Text(tr("这些应用保留原本的程序坞点击行为。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else { Text(tr("选择排除的应用")) }
            Spacer(minLength: 8)
            Button {
                showingApplications = true
            } label: {
                Text(tr("选择应用…") + " (\(ApplicationExclusions.identifiers(in: selection).count))")
            }.accessibilityLabel(tr("选择排除的应用"))
        }
        .padding(.vertical, 10)
        .sheet(isPresented: $showingApplications) {
            AppExclusionSelectionSheet(selection: $selection)
        }
    }
}

@MainActor
private struct AppExclusionSelectionSheet: View {
    @Binding var selection: String
    @ObservedObject private var preferences = Preferences.shared
    @Environment(\.dismiss) private var dismiss
    @StateObject private var catalog = ApplicationCatalogModel()
    @State private var query = ""

    private var applications: [CatalogApplication] {
        let all = ApplicationExclusions.applications(catalog.snapshot.applications, preserving: selection)
        let tokens = SettingsSearchIndex.tokens(in: query)
        guard !tokens.isEmpty else { return all }
        return all.filter { app in
            let text = SettingsSearchIndex.normalized(app.name + " " + app.bundleIdentifier)
            return tokens.allSatisfy { text.contains($0) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(tr("排除应用")).font(.title2.weight(.semibold))
                    Text(tr("勾选后立即生效，Real 将不再收起这些应用的窗口。"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(tr("完成")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(tr("搜索应用名称或标识"), text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).accessibilityLabel(tr("清空搜索"))
                }
            }.padding(9).background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(applications) { app in
                        Toggle(isOn: Binding(get: {
                            ApplicationExclusions.identifiers(in: selection).contains(app.bundleIdentifier)
                        }, set: { excluded in
                            let updated = ApplicationExclusions.updating(selection, identifier: app.bundleIdentifier, excluded: excluded)
                            if updated != selection { selection = updated }
                        })) {
                            HStack(spacing: 10) {
                                appIcon(app).frame(width: 32, height: 32)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(app.name).lineLimit(1)
                                    if app.name != app.bundleIdentifier {
                                        Text(app.bundleIdentifier).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    if app.url == nil {
                                        Text(tr("未在应用列表中找到，仍保留此排除项。"))
                                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                Spacer(minLength: 6)
                                if app.isRunning { Text(tr("正在运行")).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        .toggleStyle(.checkbox).padding(.vertical, 9).padding(.horizontal, 8)
                        .accessibilityLabel(app.name + ", " + app.bundleIdentifier)
                        Divider().opacity(0.4)
                    }
                    if applications.isEmpty {
                        Text(tr(catalog.isScanning ? "正在读取应用列表…" : "没有找到匹配的应用。"))
                            .foregroundStyle(.secondary).padding(30).frame(maxWidth: .infinity)
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            HStack(spacing: 10) {
                if catalog.isScanning { ProgressView().controlSize(.small) }
                Text(tr("仅查看应用信息，不会打开应用。"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(tr("刷新列表")) { catalog.refresh() }.disabled(catalog.isScanning)
            }
            if !catalog.snapshot.failedPaths.isEmpty || catalog.snapshot.truncated {
                Text(tr("部分应用未能读取，已有排除项保持不变。可刷新列表重试。"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(22).frame(minWidth: 540, idealWidth: 580, minHeight: 440, idealHeight: 540)
        .onAppear { catalog.refresh() }
        .onDisappear { catalog.cancel() }
    }

    @ViewBuilder private func appIcon(_ app: CatalogApplication) -> some View {
        if let url = app.url {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit()
                .accessibilityHidden(true)
        } else {
            Image(systemName: "app.dashed").font(.system(size: 26)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}
