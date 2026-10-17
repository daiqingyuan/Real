import Foundation

@MainActor func runPermissionTests() -> [String] {
    final class SystemFixture {
        var granted: Set<RealPermission> = []
        var requests: [RealPermission] = []
        var settings: [RealPermission] = []
    }
    var failures: [String] = []
    var suites: [String] = []
    var coordinators: [PermissionCoordinator] = []
    defer {
        coordinators.forEach { $0.stopPolling() }
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
    }
    func check(_ value: Bool, _ label: String) { if !value { failures.append("Permission setup: " + label) } }
    func fixture(_ allowed: Set<RealPermission> = [], choice: String? = nil)
        -> (PermissionCoordinator, SystemFixture, UserDefaults) {
        let suite = "local.dan.real.tests.permissions." + UUID().uuidString
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        if let choice { defaults.set(choice, forKey: PermissionCoordinator.choiceKey) }
        let system = SystemFixture(); system.granted = allowed
        let service = PermissionCoordinator(defaults: defaults, read: { system.granted },
            request: { system.requests.append($0) }, openSettings: { system.settings.append($0) })
        coordinators.append(service)
        return (service, system, defaults)
    }
    let (fresh, system, store) = fixture()
    fresh.configure(active: true, dock: true, hud: true)
    check(!fresh.isPresented && system.requests.isEmpty, "launch checks never themselves request OS access")
    fresh.presentAutomaticallyIfNeeded()
    check(fresh.isPresented && fresh.current == .accessibility, "first explicit open shows first missing permission")
    check(system.requests.isEmpty, "showing the guide does not trigger a native permission prompt")
    check(!fresh.finish() && store.string(forKey: PermissionCoordinator.choiceKey) == nil,
          "Finish cannot persist completion while any required grant is missing")
    fresh.requestCurrent(); fresh.requestCurrent()
    check(system.requests == [.accessibility], "denied/pending permission cannot repeatedly spawn native prompts")
    check(fresh.current == .accessibility && !fresh.complete, "a request is never mistaken for authorization")
    fresh.showSystemSettings(for: .accessibility)
    check(system.settings == [.accessibility], "pending grant has an explicit settings fallback")
    system.granted.insert(.accessibility); fresh.refresh()
    check(fresh.current == .screenRecording && fresh.waitingFor == nil,
          "verified permission automatically advances to the next missing item")
    check(store.string(forKey: PermissionCoordinator.choiceKey) == nil, "partial approval is not persisted as completed")
    fresh.requestCurrent()
    check(system.requests == [.accessibility, .screenRecording], "second native request occurs only after explicit action")
    system.granted.insert(.screenRecording); fresh.refresh()
    check(fresh.complete && fresh.isPresented && store.string(forKey: PermissionCoordinator.choiceKey) == "completed",
          "actual required grants persist completion and leave a clear success screen")
    check(fresh.finish() && !fresh.isPresented, "success screen finishes without any extra permission")
    let relaunched = PermissionCoordinator(defaults: store, read: { system.granted }, request: { system.requests.append($0) })
    coordinators.append(relaunched)
    relaunched.configure(active: true, dock: true, hud: true); relaunched.presentAutomaticallyIfNeeded()
    check(!relaunched.isPresented && system.requests.count == 2, "completed setup survives a new coordinator without any repeat prompt")
    system.granted.remove(.accessibility); relaunched.refresh(); relaunched.presentAutomaticallyIfNeeded()
    check(!relaunched.isPresented, "later revocation updates status without repeatedly opening onboarding")
    relaunched.presentManually()
    check(relaunched.isPresented && relaunched.current == .accessibility, "manual guide remains available after revocation")
    relaunched.dismiss()
    check(store.string(forKey: PermissionCoordinator.choiceKey) == "completed", "manual dismissal does not corrupt completed history")

    let (partial, partialSystem, partialStore) = fixture([.accessibility, .inputMonitoring])
    partial.configure(active: true, dock: true, hud: true); partial.presentAutomaticallyIfNeeded()
    check(partial.current == .screenRecording && partial.completedCount == 1,
          "already allowed items are skipped even on first use")
    partial.requestCurrent()
    check(partialSystem.requests == [.screenRecording], "already authorized capabilities are never re-requested")
    partial.dismiss()
    check(partialStore.string(forKey: PermissionCoordinator.choiceKey) == "later", "Later/whole-window close persists deferral")
    let deferred = PermissionCoordinator(defaults: partialStore, read: { partialSystem.granted }, request: { _ in })
    coordinators.append(deferred)
    deferred.configure(active: true, dock: true, hud: true); deferred.presentAutomaticallyIfNeeded()
    check(!deferred.isPresented, "deferral prevents nagging on the next launch")
    deferred.presentManually(); check(deferred.isPresented, "deferral can be resumed from settings")

    let (existing, existingSystem, existingStore) = fixture([.accessibility, .screenRecording])
    existing.configure(active: true, dock: true, hud: true); existing.presentAutomaticallyIfNeeded()
    check(!existing.isPresented && existing.complete && existingSystem.requests.isEmpty,
          "existing authorized users skip the entire first-use guide and optional input permission")
    check(existingStore.string(forKey: PermissionCoordinator.choiceKey) == "completed", "existing grants migrate silently to completed setup")
    let (silent, silentSystem, silentStore) = fixture()
    silent.configure(active: true, dock: true, hud: true)
    check(!silent.isPresented && silentSystem.requests.isEmpty && silentStore.string(forKey: PermissionCoordinator.choiceKey) == nil,
          "silent login/background launch does not show or consume first-open onboarding")
    silent.presentAutomaticallyIfNeeded()
    check(silent.isPresented, "explicit reopen after background launch still shows first-use guide")

    let (preview, previewSystem, previewStore) = fixture()
    preview.configure(active: false, dock: true, hud: true)
    preview.presentAutomaticallyIfNeeded(); preview.presentManually(); preview.requestPermission(.accessibility)
    preview.showSystemSettings(for: .screenRecording)
    check(!preview.finish() && !preview.isPresented && previewSystem.requests.isEmpty && previewSystem.settings.isEmpty,
          "preview cannot present, request grants, open privacy settings, or finish real setup")
    check(previewStore.string(forKey: PermissionCoordinator.choiceKey) == nil, "preview leaves setup history untouched")
    preview.configure(active: true, dock: true, hud: true); preview.presentAutomaticallyIfNeeded()
    check(preview.isPresented, "explicitly activating the preview backend enables first-use setup")

    let (hudOnly, _, _) = fixture([.accessibility])
    hudOnly.configure(active: true, dock: false, hud: true); hudOnly.presentAutomaticallyIfNeeded()
    check(hudOnly.complete && hudOnly.required == [.accessibility] && !hudOnly.isPresented,
          "HUD-only user is not asked for unrelated screen recording")
    let (none, _, _) = fixture()
    none.configure(active: true, dock: false, hud: false); none.presentAutomaticallyIfNeeded()
    check(none.complete && none.required.isEmpty && !none.isPresented, "disabled protected features need no permissions")
    check(RealPermission.required(dock: true, hud: false) == [.accessibility, .screenRecording], "Dock prerequisites reflect its actual engine gates")
    check(!RealPermission.required(dock: true, hud: true).contains(.inputMonitoring), "input monitoring is not forced without a need")
    return failures
}
