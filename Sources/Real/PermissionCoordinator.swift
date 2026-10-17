import AppKit
import ApplicationServices
import Combine
import Foundation

enum RealPermission: String, CaseIterable, Identifiable {
    case accessibility, screenRecording, inputMonitoring
    var id: String { rawValue }
    var title: String {
        switch self {
        case .accessibility: return "辅助功能"
        case .screenRecording: return "屏幕录制"
        case .inputMonitoring: return "输入监控"
        }
    }
    var reason: String {
        switch self {
        case .accessibility: return "让 Real 收起和恢复应用窗口，并响应硬件按键。"
        case .screenRecording: return "用于识别当前桌面的窗口。只有手动开启声音频谱时才启动捕获。"
        case .inputMonitoring: return "如果系统仍阻止程序坞点击或硬件按键监听，可补充允许这项权限。"
        }
    }
    var privacySection: String {
        switch self {
        case .accessibility: return "Privacy_Accessibility"
        case .screenRecording: return "Privacy_ScreenCapture"
        case .inputMonitoring: return "Privacy_ListenEvent"
        }
    }
    static func required(dock: Bool, hud: Bool) -> [RealPermission] {
        var result: [RealPermission] = []
        if dock || hud { result.append(.accessibility) }
        if dock { result.append(.screenRecording) }
        // The active event taps require Accessibility. Input Monitoring is a
        // fallback, not a universal prerequisite for completing setup.
        return result
    }
}

/// Owns setup progress, never grants permission or assumes a request succeeded.
/// Dependencies allow first-run/denial/relaunch testing without touching TCC.
@MainActor final class PermissionCoordinator: ObservableObject {
    static let choiceKey = "permissionSetupChoiceV1"
    @Published private(set) var granted: Set<RealPermission> = []
    @Published private(set) var required: [RealPermission] = []
    @Published private(set) var isPresented = false
    @Published private(set) var requested: Set<RealPermission> = []
    @Published private(set) var waitingFor: RealPermission?
    var onPermissionsChanged: (() -> Void)?
    var onRelaunch: (() -> Void)?
    private let defaults: UserDefaults
    private let read: () -> Set<RealPermission>
    private let request: (RealPermission) -> Void
    private let openSettings: (RealPermission) -> Void
    private var active = false
    private var presentedThisRun = false
    private var timer: Timer?

    init(defaults: UserDefaults = .standard,
         read: (() -> Set<RealPermission>)? = nil,
         request: ((RealPermission) -> Void)? = nil,
         openSettings: ((RealPermission) -> Void)? = nil) {
        self.defaults = defaults
        self.read = read ?? Self.readSystemPermissions
        self.request = request ?? Self.requestSystemPermission
        self.openSettings = openSettings ?? Self.openSystemSettings
        granted = self.read()
    }
    var current: RealPermission? { required.first { !granted.contains($0) } }
    var complete: Bool { current == nil }
    var isActive: Bool { active }
    var completedCount: Int { required.filter { granted.contains($0) }.count }

    func configure(active: Bool, dock: Bool, hud: Bool) {
        self.active = active
        let needed = RealPermission.required(dock: dock, hud: hud)
        if required != needed { required = needed }
        if !active { isPresented = false; stopPolling() }
        refresh()
    }
    /// Call when the settings window is explicitly opened, including a reopen
    /// of an app that originally launched silently as a login item.
    func presentAutomaticallyIfNeeded() {
        guard active else { return }
        refresh()
        guard !complete, !presentedThisRun,
              defaults.string(forKey: Self.choiceKey) == nil else { return }
        present()
    }
    func presentManually() {
        guard active else { return }
        refresh(); present()
    }
    private func present() {
        guard !isPresented else { return }
        presentedThisRun = true; requested = []; waitingFor = nil
        isPresented = true
        let timer = Timer(timeInterval: 0.65, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    func refresh() {
        let snapshot = read()
        let changed = granted != snapshot
        if changed { granted = snapshot }
        if let waitingFor, snapshot.contains(waitingFor) { self.waitingFor = nil }
        if active, complete { defaults.set("completed", forKey: Self.choiceKey) }
        if changed, active { onPermissionsChanged?() }
    }
    func requestCurrent() { if let current { requestPermission(current) } }
    func requestPermission(_ permission: RealPermission) {
        guard active, !granted.contains(permission), !requested.contains(permission) else { return }
        requested.insert(permission); waitingFor = permission
        // System requests can be asynchronous. Only a subsequent read advances
        // the guide; neither a button press nor a request return value can do so.
        request(permission)
        refresh()
    }
    func showSystemSettings(for permission: RealPermission) {
        guard active, !granted.contains(permission) else { return }
        openSettings(permission)
    }
    @discardableResult func finish() -> Bool {
        refresh()
        guard active, complete else { return false }
        defaults.set("completed", forKey: Self.choiceKey)
        close(); return true
    }
    func dismiss() {
        guard isPresented else { return }
        if active, !complete, defaults.string(forKey: Self.choiceKey) != "completed" {
            defaults.set("later", forKey: Self.choiceKey)
        }
        close()
    }
    func relaunch() { if active, isPresented { onRelaunch?() } }
    private func close() { isPresented = false; waitingFor = nil; stopPolling() }
    func stopPolling() { timer?.invalidate(); timer = nil }
    deinit { timer?.invalidate() }

    private static func readSystemPermissions() -> Set<RealPermission> {
        var result: Set<RealPermission> = []
        if AXIsProcessTrusted() { result.insert(.accessibility) }
        if CGPreflightScreenCaptureAccess() { result.insert(.screenRecording) }
        if CGPreflightListenEventAccess() { result.insert(.inputMonitoring) }
        return result
    }
    private static func requestSystemPermission(_ permission: RealPermission) {
        switch permission {
        case .accessibility:
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        case .screenRecording: _ = CGRequestScreenCaptureAccess()
        case .inputMonitoring: _ = CGRequestListenEventAccess()
        }
        // Leave the native prompt in front. Opening settings immediately here
        // would cover it with a second window; the guide supplies that fallback.
    }
    private static func openSystemSettings(_ permission: RealPermission) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + permission.privacySection) else { return }
        NSWorkspace.shared.open(url)
    }
}
