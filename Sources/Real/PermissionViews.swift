import SwiftUI

struct PermissionSetupView: View {
    @ObservedObject var coordinator: PermissionCoordinator
    @ObservedObject var preferences: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                BrandMark(size: 48)
                VStack(alignment: .leading, spacing: 5) {
                    Text(tr(coordinator.complete ? "Real 已准备就绪" : "让 Real 准备就绪"))
                        .font(.title2.weight(.semibold))
                    Text(tr(coordinator.complete ? "必要权限已允许，以后打开不会重复询问。" : "只设置尚未允许的权限，已允许的会自动跳过。"))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 14) {
                ForEach(coordinator.required) { permission in
                    HStack(spacing: 10) {
                        Image(systemName: coordinator.granted.contains(permission) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(coordinator.granted.contains(permission) ? Color.green : Color.secondary)
                        Text(tr(permission.title))
                        Spacer()
                        Text(tr(coordinator.granted.contains(permission) ? "已允许" : permission == coordinator.current ? "当前步骤" : "下一步"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.padding(18).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))

            if let current = coordinator.current {
                VStack(alignment: .leading, spacing: 10) {
                    Text(tr(current.title)).font(.headline)
                    Text(tr(current.reason)).foregroundStyle(.secondary)
                    if coordinator.requested.contains(current) {
                        Text(tr("在系统提示中允许访问；如果打开了系统设置，请开启 Real 旁边的开关。返回后会自动检查。"))
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 14) {
                            Button(tr("打开对应设置")) { coordinator.showSystemSettings(for: current) }
                            Button(tr("检查授权")) { coordinator.refresh() }
                        }
                        Text(tr("如果系统要求重新打开应用，请按系统提示操作，或使用下方的重新打开按钮。"))
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(tr("点击下方按钮后，macOS 会显示授权提示。最终授权需要你亲自确认。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Label(tr("日历、提醒事项和镜子等权限，会在你第一次使用对应功能时再申请。"), systemImage: "checkmark.shield")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                if !coordinator.complete {
                    Button(tr("稍后设置")) { coordinator.dismiss() }
                    if coordinator.current.map({ coordinator.requested.contains($0) }) == true {
                        Button(tr("重新打开 Real")) { coordinator.relaunch() }
                    }
                }
                Spacer()
                if coordinator.complete {
                    Button(tr("开始使用")) { coordinator.finish() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                } else if let current = coordinator.current, !coordinator.requested.contains(current) {
                    Button(tr("允许并继续")) { coordinator.requestCurrent() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                } else {
                    Text(tr("等待系统授权…")).font(.callout).foregroundStyle(.secondary)
                }
            }
        }.padding(28).frame(width: 520)
            .environment(\.locale, preferences.locale)
            .interactiveDismissDisabled()
    }
}

struct PermissionStatusCard: View {
    @ObservedObject var coordinator: PermissionCoordinator
    @ObservedObject var preferences: Preferences
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(tr("权限")).font(.headline)
                Spacer()
                Button(tr("授权引导")) { coordinator.presentManually() }.disabled(!coordinator.isActive)
            }.padding(.vertical, 16)
            ForEach(RealPermission.allCases) { permission in
                HStack(spacing: 10) {
                    let allowed = coordinator.granted.contains(permission)
                    Image(systemName: allowed ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(allowed ? Color.green : Color.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 7) {
                            Text(tr(permission.title))
                            if permission == .inputMonitoring { Text(tr("按需允许")).font(.caption).foregroundStyle(.secondary) }
                        }
                        Text(tr(permission.reason)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if allowed {
                        Text(tr("已允许")).font(.callout).foregroundStyle(.green)
                    } else {
                        Button(tr(coordinator.requested.contains(permission) ? "打开对应设置" : "允许访问")) {
                            if coordinator.requested.contains(permission) { coordinator.showSystemSettings(for: permission) }
                            else { coordinator.requestPermission(permission) }
                        }.disabled(!coordinator.isActive)
                    }
                }.padding(.vertical, 12)
            }
        }.padding(.horizontal, 18).padding(.bottom, 8).frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.06)))
            .environment(\.locale, preferences.locale)
    }
}
