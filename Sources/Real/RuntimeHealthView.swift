import SwiftUI

/// May be placed in any settings section. It never starts a service itself.
struct RuntimeHealthView: View {
    @ObservedObject var engine: DockEngine
    @ObservedObject private var preferences = Preferences.shared
    let preview: Bool
    let onCheck: () -> Void
    let onRepair: () -> Void

    private var symbol: String {
        switch engine.healthState {
        case .running: return "checkmark.circle.fill"
        case .stopped: return "pause.circle"
        case .recovering: return "arrow.clockwise.circle"
        case .permissionRequired, .listenerFailed: return "exclamationmark.circle"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(tr(engine.healthState.titleKey), systemImage: symbol)
                .font(.headline)
                .foregroundStyle(engine.healthState == .running ? Color.green : Color.primary)
            Text(tr(preview ? "预览模式不会启动或修复后台。" : engine.healthDetail))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(tr("检查运行状态"), action: onCheck).disabled(preview)
                Button(tr("修复后台监听"), action: onRepair)
                    .disabled(preview || !engine.isRequestedToRun || engine.healthState == .running
                              || engine.healthState == .recovering || engine.healthState == .permissionRequired)
            }
        }
        .accessibilityElement(children: .contain)
    }
}
