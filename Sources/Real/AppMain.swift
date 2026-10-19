import AppKit
import SwiftUI
import Carbon
import ServiceManagement

@main struct RealMain {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--self-test") || CommandLine.arguments.contains("--self-test-headless") {
            var failures = runDockPolicyTests() + runLyricsTests() + runPreferencesTests() + runSystemKeyPolicyTests() + runShelfDragPolicyTests() + runAudioSpectrumTests() + runDisplayPolicyTests() + runQQPlaybackTests() + runQQMusicLyricsTests() + runQQMediaAnchorTests() + runMediaSelectionTests() + runSystemServiceTests() + runIslandPolicyTests() + runPermissionTests() + runUninstallTests() + runLayeredPlayerPolicyTests() + runRuntimeHealthTests() + runLyricDisplayTests() + runSettingsUsabilityTests() + runMaturityPreferencesTests()
            failures += runKaraokeParserTests() + runLyricPlaybackClockTests() + runKaraokeRenderingTests()
            failures += runKaraokeNativeViewTests()
            failures += runTimedLyricsEnrichmentTests()
            if CommandLine.arguments.contains("--self-test-headless") {
                print("SKIP: native SeekControl UI tests require a desktop session")
            } else { failures += runSeekControlTests() }
            if failures.isEmpty { print("PASS: Dock, system key, shelf drag, audio FFT/PCM, lyrics and preferences policies") }
            else { failures.forEach { print("FAIL: " + $0) } }
            exit(failures.isEmpty ? 0 : 1)
        }
        let app = NSApplication.shared
        app.applicationIconImage = BrandMark.image
        let delegate = RealDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor final class RealDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var model: AppModel!
    private var uninstaller: UninstallService!
    private var island: IslandHost?
    private var keyboard: SystemKeyMonitor?
    private var menuItem: NSStatusItem?
    private var preferencesObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var previousFlags: [String: Bool] = [:]
    private var previousLanguage = ""
    private var isCurrentLoginEvent: Bool {
        NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let showOnLaunch = RealLaunchPolicy.shouldShowSettings(isLoginEvent: isCurrentLoginEvent, arguments: CommandLine.arguments)
        if let same = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "local.dan.real").first(where: { $0.processIdentifier != getpid() }) {
            if showOnLaunch { same.activate(options: []) }
            NSApp.terminate(nil)
            return
        }
        model = AppModel()
        configureUninstaller()
        model.showUninstall = { [weak self] in
            guard let self, !self.model.previewOnly, !self.model.isUninstalling else { return }
            self.uninstaller.present()
        }
        model.showSettings = { [weak self] in self?.showSettings() }
        model.permissions.onRelaunch = { [weak self] in self?.relaunchForPermissions() }
        island = IslandHost(model: model)
        model.refreshHosts = { [weak self] in self?.island?.refresh() }
        keyboard = SystemKeyMonitor(system: model.system, preferences: model.preferences)
        keyboard?.onHUD = { [weak self] kind, value in self?.model.showHUD(kind, value: value) }
        model.permissionStateChanged = { [weak self] in
            guard let self, !self.model.previewOnly, !self.model.isUninstalling else { return }
            self.keyboard?.stop()
            if self.model.preferences.enabled("hud") { self.keyboard?.start() }
        }
        let preview = RealLaunchPolicy.isDesignPreview(bundleIdentifier: Bundle.main.bundleIdentifier)
            || CommandLine.arguments.contains("--preview") || anotherRealRunning()
        model.start(preview: preview)
        previousFlags = model.preferences.flags
        previousLanguage = model.preferences.language
        preferencesObserver = NotificationCenter.default.addObserver(forName: .realPreferencesChanged, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.preferencesChanged() } }
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.model.isUninstalling else { return }
                self.model.permissions.refresh()
                self.model.refreshLoginStatus()
                self.model.applyPreferences()
                if !self.model.previewOnly { self.keyboard?.start() }
            }
        }
        configureMainMenu()
        applyPresence()
        if !preview { island?.refresh(); keyboard?.start() }
        if showOnLaunch {
            showSettings()
            if CommandLine.arguments.contains("--resume-permission-setup") { model.permissions.presentManually() }
        }
    }
    private func configureUninstaller() {
        let target = UninstallTarget(appURL: Bundle.main.bundleURL,
                                     homeURL: FileManager.default.homeDirectoryForCurrentUser)
        let trash: (URL) throws -> Void = { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        uninstaller = UninstallService(target: target, unregister: { [weak self] in
            if SMAppService.mainApp.status != .notRegistered { try SMAppService.mainApp.unregister() }
            self?.model.refreshLoginStatus()
        }, suspend: { [weak self] in
            guard let self else { return }
            self.model.isUninstalling = true
            self.model.permissions.configure(active: false, dock: false, hud: false)
            self.model.dock.pauseDiagnosticsForUninstall(true)
            self.keyboard?.stop(); self.island?.stop(); self.model.stop()
        }, resume: { [weak self] in
            guard let self else { return }
            self.model.isUninstalling = false
            self.model.dock.pauseDiagnosticsForUninstall(false)
            self.model.start(preview: false)
            self.island?.refresh(); self.keyboard?.start()
        }, trash: trash, cleanData: {
            target.cleanData(trash: trash, clearPreferences: {
                UserDefaults.standard.removePersistentDomain(forName: UninstallTarget.identifier)
            }, clearTokens: { try MediaTokenStore.removeAll() })
        }, finish: { failures in
            if !failures.isEmpty {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = tr("Real 已移到废纸篓")
                alert.informativeText = tr("以下数据未能清理，可稍后在访达或钥匙串访问中移除：") + "\n" + failures.joined(separator: "\n")
                alert.addButton(withTitle: tr("退出 Real"))
                alert.runModal()
            }
            NSApp.terminate(nil)
        })
    }
    private func anotherRealRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            RealLaunchPolicy.conflicts(candidatePID: $0.processIdentifier, currentPID: getpid(), bundleIdentifier: $0.bundleIdentifier)
        }
    }
    private func preferencesChanged() {
        guard !model.isUninstalling else { return }
        let p = model.preferences
        let languageChanged = p.language != previousLanguage
        if languageChanged { configureMainMenu() }
        if languageChanged || p.enabled("dockIcon") != (previousFlags["dockIcon"] ?? false)
            || p.enabled("menuIcon") != (previousFlags["menuIcon"] ?? false) { applyPresence() }
        model.calendar.includeCompleted = model.preferences.enabled("completed")
        model.applyPreferences()
        if !model.previewOnly {
            if model.preferences.enabled("hud") { keyboard?.start() } else { keyboard?.stop() }
        }
        previousFlags = model.preferences.flags
        previousLanguage = model.preferences.language
    }
    private func configureMainMenu() {
        let main = NSMenu()
        let item = NSMenuItem(); main.addItem(item)
        let appMenu = NSMenu(title: "Real"); item.submenu = appMenu
        appMenu.addItem(withTitle: tr("打开设置"), action: #selector(openSettingsAction), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: tr("隐藏 Real"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: tr("退出 Real"), action: #selector(quitAction), keyEquivalent: "q").target = self
        let edit = NSMenuItem(); edit.title = tr("编辑"); edit.submenu = NSMenu(title: tr("编辑")); main.addItem(edit)
        for (title, selector, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            edit.submenu?.addItem(withTitle: tr(title), action: Selector(selector), keyEquivalent: key)
        }
        let windows = NSMenuItem(); windows.title = tr("窗口"); windows.submenu = NSMenu(title: tr("窗口")); main.addItem(windows)
        windows.submenu?.addItem(withTitle: tr("最小化"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windows.submenu?.addItem(withTitle: tr("关闭窗口"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        NSApp.mainMenu = main
    }
    private func applyPresence() {
        let p = model.preferences
        let desiredPolicy: NSApplication.ActivationPolicy = p.enabled("dockIcon") ? .regular : .accessory
        if NSApp.activationPolicy() != desiredPolicy { NSApp.setActivationPolicy(desiredPolicy) }
        if p.enabled("menuIcon") {
            if menuItem == nil { menuItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength); menuItem?.button?.title = "R" }
            let menu = NSMenu()
            menu.addItem(withTitle: tr("打开设置"), action: #selector(openSettingsAction), keyEquivalent: ",").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: tr("退出 Real"), action: #selector(quitAction), keyEquivalent: "q").target = self
            menuItem?.menu = menu
        } else if let menuItem { NSStatusBar.system.removeStatusItem(menuItem); self.menuItem = nil }
    }
    func showSettings() {
        guard !model.isUninstalling else { return }
        model.permissions.presentAutomaticallyIfNeeded()
        model.refreshLoginStatus()
        if window == nil {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: CompactStyle.contentSize), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Real"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false; window.delegate = self
            window.identifier = NSUserInterfaceItemIdentifier("real.settings")
            window.contentMinSize = CompactStyle.contentSize; window.contentMaxSize = CompactStyle.contentSize
            window.standardWindowButton(.zoomButton)?.isEnabled = false
            window.contentView = NSHostingView(rootView: RealRootView(model: model, p: model.preferences, permissions: model.permissions, uninstaller: uninstaller, start: { [weak self] in self?.startBackground() }))
            window.center(); self.window = window
        }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func relaunchForPermissions() {
        guard !model.previewOnly, !model.isUninstalling else { return }
        // Pass the path as an argument, never interpolate it into shell code.
        // Wait for this PID to exit so single-instance detection cannot consume
        // the replacement launch. The original installation/login path is kept.
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", """
        attempts=0
        while kill -0 "$1" 2>/dev/null; do
            attempts=$((attempts + 1))
            if [ "$attempts" -ge 200 ]; then exit 1; fi
            /bin/sleep 0.1
        done
        /usr/bin/open -n "$2" --args --resume-permission-setup
        """, "real-permission-relaunch", String(getpid()), Bundle.main.bundleURL.path]
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        do { try helper.run(); NSApp.terminate(nil) }
        catch { model.errorMessage = tr("无法自动重新打开 Real，请手动退出后再打开。") }
    }
    func windowWillClose(_ notification: Notification) {
        if let closing = notification.object as? NSWindow, closing === window {
            model.permissions.dismiss()
        }
    }
    private func startBackground() {
        guard !model.isUninstalling else { return }
        guard !RealLaunchPolicy.isDesignPreview(bundleIdentifier: Bundle.main.bundleIdentifier) else {
            model.errorMessage = tr("此测试窗口使用独立设置，后台功能保持关闭。")
            return
        }
        guard !anotherRealRunning() else { model.errorMessage = tr("请先退出旧版 Real，避免两套后台同时控制窗口。"); return }
        model.start(preview: false)
        model.permissions.presentAutomaticallyIfNeeded()
        model.objectWillChange.send(); island?.refresh(); keyboard?.start()
    }
    @objc private func openSettingsAction() { showSettings() }
    @objc private func quitAction() { NSApp.terminate(nil) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Only the incoming login event is quiet. A later explicit reopen must
        // work even when this process originally started with --background.
        guard !isCurrentLoginEvent else { return false }
        // Dock can deliver its reopen message after our click has requested
        // minimization. Do not immediately undo that same operation.
        guard model?.dock.shouldSuppressOwnReopen != true else { return false }
        showSettings()
        return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { keyboard?.stop(); island?.stop(); model?.stop() }
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: tr("打开设置"), action: #selector(openSettingsAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: tr(model.preferences.enabled("dockIcon") ? "隐藏程序坞图标" : "显示程序坞图标"), action: #selector(toggleDock), keyEquivalent: "").target = self
        return menu
    }
    @objc private func toggleDock() { model.preferences.set("dockIcon", !model.preferences.enabled("dockIcon")) }
}

private struct RealRootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var p: Preferences
    @ObservedObject var permissions: PermissionCoordinator
    @ObservedObject var uninstaller: UninstallService
    let start: () -> Void
    @State private var welcome = false
    @State private var word = false
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                if model.previewOnly { HStack { Text(tr("原生预览")); Spacer(); Button(tr("启动后台功能"), action: start) }.font(.caption).padding(.horizontal, 28).padding(.vertical, 8).background(.tint.opacity(0.06)) }
                SettingsView(model: model, p: p)
            }
            if welcome {
                HStack(spacing: 0) { Text("R"); if word { Text("eal").transition(.move(edge: .leading).combined(with: .opacity)) } }
                    .font(.system(size: word ? 46 : 80, weight: .medium, design: .rounded))
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(.background)
                    .allowsHitTesting(false).transition(.opacity)
            }
        }.sheet(isPresented: Binding(get: { permissions.isPresented }, set: { if !$0 { permissions.dismiss() } })) {
            PermissionSetupView(coordinator: permissions, preferences: p)
        }.sheet(isPresented: Binding(get: { uninstaller.isPresented }, set: { if !$0 { uninstaller.dismiss() } })) {
            UninstallView(service: uninstaller)
        }.task {
            let defaults = UserDefaults.standard
            guard !model.previewOnly, p.enabled("intro"), !defaults.bool(forKey: "welcomed") else { return }
            defaults.set(true, forKey: "welcomed")
            guard !permissions.isPresented, !reducedMotion else { return }
            welcome = true
            try? await Task.sleep(nanoseconds: 220_000_000)
            withAnimation(.easeInOut(duration: 0.45)) { word = true }
            try? await Task.sleep(nanoseconds: 650_000_000)
            withAnimation(.easeOut(duration: 0.18)) { welcome = false }
        }
    }
}
