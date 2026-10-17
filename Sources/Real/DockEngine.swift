import AppKit
import ApplicationServices
import Combine
import Darwin

/// Pure gesture rules shared by the event tap and the independent self-test runner.
enum DockClickPolicy {
    static let maximumDuration: Double = 0.45
    static let maximumTravel: Double = 4
    // Caps Lock is a persistent typing mode, not a held Dock-click modifier.
    static let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]

    static func accepts(duration: Double, travel: Double, modified: Bool, dragged: Bool, clickCount: Int, prepared: Bool = true, sameDesktop: Bool = true) -> Bool {
        prepared && sameDesktop && duration.isFinite && travel.isFinite && duration >= 0 && duration <= maximumDuration && travel >= 0 && travel <= maximumTravel && !modified && !dragged && clickCount == 1
    }

    /// A verified application may expose different or empty AX/Quartz titles.
    /// Match by mutually unique geometry rather than maintaining an app list.
    static func allowsGeometryFallback(bundleID: String?) -> Bool {
        bundleID.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
    }

    /// Returns an index only when both public API views agree uniquely.
    static func uniqueWindowIndex(title: String, bounds: CGRect,
                                  accessibility: [(String, CGRect)], onScreen: [(String, CGRect)],
                                  allowGeometryFallback: Bool = false) -> Int? {
        guard bounds.width > 0, bounds.height > 0,
              [bounds.minX, bounds.minY, bounds.width, bounds.height].allSatisfy({ $0.isFinite }) else { return nil }
        func sameGeometry(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
            return rhs.width > 0 && rhs.height > 0
                && [rhs.minX, rhs.minY, rhs.width, rhs.height].allSatisfy({ $0.isFinite })
                && abs(lhs.minX - rhs.minX) <= 1 && abs(lhs.minY - rhs.minY) <= 1
                && abs(lhs.width - rhs.width) <= 1 && abs(lhs.height - rhs.height) <= 1
        }
        func geometryMatches(_ candidate: (String, CGRect)) -> Bool { sameGeometry(bounds, candidate.1) }
        func matches(_ candidate: (String, CGRect)) -> Bool {
            candidate.0 == title && geometryMatches(candidate)
        }
        let axIndices = accessibility.indices.filter { matches(accessibility[$0]) }
        let indices = onScreen.indices.filter { matches(onScreen[$0]) }
        // A usable title can distinguish overlapping titled windows. An unknown
        // same-frame title remains a conflict; it must not disappear from a list.
        if !title.isEmpty, axIndices.count == 1, indices.count == 1,
           !accessibility.contains(where: { $0.0.isEmpty && geometryMatches($0) }),
           !onScreen.contains(where: { $0.0.isEmpty && geometryMatches($0) }) {
            let chosenFrame = onScreen[indices[0]].1
            let reverse = accessibility.indices.filter {
                accessibility[$0].0 == title && sameGeometry(chosenFrame, accessibility[$0].1)
            }
            let unknownNearChosen = (accessibility + onScreen).contains {
                $0.0.isEmpty && sameGeometry(chosenFrame, $0.1)
            }
            if reverse.count == 1, reverse[0] == axIndices[0], !unknownNearChosen { return indices[0] }
        }
        // Empty titles are valid (for example NetEase's main window). They need
        // unique geometry across ALL standard AX windows, including minimized
        // and other-Space windows, and current-Space Quartz windows of this PID.
        guard allowGeometryFallback, axIndices.count == 1,
              accessibility.filter(geometryMatches).count == 1 else { return nil }
        let geometryIndices = onScreen.indices.filter { geometryMatches(onScreen[$0]) }
        guard geometryIndices.count == 1 else { return nil }
        let chosenFrame = onScreen[geometryIndices[0]].1
        let reverse = accessibility.indices.filter { sameGeometry(chosenFrame, accessibility[$0].1) }
        guard reverse.count == 1, reverse[0] == axIndices[0] else { return nil }
        return geometryIndices[0]
    }

    /// An actual AX-to-Quartz window number can distinguish separate native
    /// surfaces even when a player puts its lyric overlay over the main window.
    /// Never infer an ID by frame or choose an arbitrary same-frame surface.
    static func identifiedWindowIndex(number: CGWindowID?, bounds: CGRect,
                                      accessibilityNumbers: [CGWindowID?],
                                      onScreen: [(CGWindowID, CGRect)]) -> Int? {
        guard let number, number != kCGNullWindowID,
              bounds.width > 0, bounds.height > 0,
              [bounds.minX, bounds.minY, bounds.width, bounds.height].allSatisfy({ $0.isFinite }),
              accessibilityNumbers.filter({ $0 == number }).count == 1 else { return nil }
        let indices = onScreen.indices.filter { onScreen[$0].0 == number }
        guard indices.count == 1 else { return nil }
        let frame = onScreen[indices[0]].1
        guard frame.width > 0, frame.height > 0,
              [frame.minX, frame.minY, frame.width, frame.height].allSatisfy({ $0.isFinite }),
              abs(bounds.minX - frame.minX) <= 1, abs(bounds.minY - frame.minY) <= 1,
              abs(bounds.width - frame.width) <= 1, abs(bounds.height - frame.height) <= 1 else { return nil }
        return indices[0]
    }

    enum SavedGroupDecision: Equatable { case restore, retain, discard }

    /// Unknown AX state is a temporary read failure, not proof that a saved
    /// window has been restored or closed. Preserve ownership until it is known.
    static func savedGroupDecision(minimizedStates: [Bool?]) -> SavedGroupDecision {
        if minimizedStates.contains(where: { $0 == true }) { return .restore }
        if minimizedStates.contains(where: { $0 == nil }) { return .retain }
        return .discard
    }

    enum SavedGroupPreparation: Equatable { case restore, inspectActiveWindows }
    /// A failed AX read cannot establish that the group has gone away. Execute
    /// the tracked restore path, which never reopens unrelated native windows.
    static func savedGroupPreparation(minimizedStates: [Bool?]?) -> SavedGroupPreparation {
        guard let minimizedStates else { return .restore }
        return savedGroupDecision(minimizedStates: minimizedStates) == .discard ? .inspectActiveWindows : .restore
    }

    static func restoreAtPreparationDeadline(released: Bool, verifiedTarget: Bool,
                                             currentSavedGroup: Bool) -> Bool {
        released && verifiedTarget && currentSavedGroup
    }

    static func isOrdinaryWindow(fullScreen: Bool, modal: Bool, hasSheet: Bool) -> Bool {
        !fullScreen && !modal && !hasSheet
    }

    /// Recheck immediately before writing so a window manually minimized since
    /// discovery never becomes ours. An accepted asynchronous request stays ours
    /// even if the target has not yet published its new AX state.
    enum MutationRequestOutcome { case accepted, uncertain, rejected }
    static func requestMinimization(readMinimized: () -> Bool?, request: () -> MutationRequestOutcome) -> Bool {
        guard readMinimized() == false else { return false }
        switch request() {
        case .accepted, .uncertain: return true
        case .rejected: return false
        }
    }

    static func mayMinimize(targetPID: pid_t, frontmostPID: pid_t?, excluded: Bool, windows: Int) -> Bool {
        !excluded && targetPID == frontmostPID && windows > 0
    }

    /// A native Dock reopen may restore an unrelated pre-minimized window.
    /// Never replay a selected group restore, or any mutation which may still
    /// commit after an AX timeout. Only a never-attempted minimize can fail open.
    static func shouldReturnFailedAction(changedWindows: Int, cancelled: Bool,
                                         sameDesktop: Bool, sameRun: Bool,
                                         restoring: Bool, mutationAttempted: Bool) -> Bool {
        changedWindows == 0 && !cancelled && sameDesktop && sameRun
            && !restoring && !mutationAttempted
    }

    static func mayRestore(savedEpoch: UInt64, currentEpoch: UInt64, sameProcess: Bool, excluded: Bool) -> Bool {
        savedEpoch == currentEpoch && sameProcess && !excluded
    }
}

/// Snapshot of a requested AppKit restoration. nil represents a window which
/// has closed; closing it does not prove that we fulfilled the Dock click.
struct DockRestoreProgress {
    let restored: Int
    let pending: Int
    init(minimizedStates: [Bool?]) {
        restored = minimizedStates.filter { $0 == false }.count
        pending = minimizedStates.filter { $0 == true }.count
    }
    func shouldWait(elapsed: Double, cancelled: Bool) -> Bool {
        pending > 0 && !cancelled && elapsed.isFinite && elapsed >= 0 && elapsed < 1.0
    }
}

/// Retry reads only when AX reports a messaging timeout. Writes are never
/// repeated: a timed-out write can still commit in the receiving application.
/// Both attempts share the restore operation's deadline.
enum DockAXReadRetry {
    static func read<Value>(deadline: Double, isCancelled: () -> Bool,
                           now: () -> Double = { ProcessInfo.processInfo.systemUptime },
                           pause: (Double) -> Void = { Thread.sleep(forTimeInterval: $0) },
                           attempt: (Float, Int) -> (AXError, Value?)) -> Value? {
        let timeouts: [Float] = [0.08, 0.20]
        for (index, timeout) in timeouts.enumerated() {
            let remaining = deadline - now()
            guard !isCancelled(), remaining.isFinite, remaining >= 0.005 else { return nil }
            let result = attempt(min(timeout, Float(remaining)), index + 1)
            if result.0 == .success { return result.1 }
            guard result.0 == .cannotComplete else { return nil }
            if index + 1 < timeouts.count {
                let delay = min(0.02, max(0, deadline - now()))
                if delay > 0, !isCancelled() { pause(delay) }
            }
        }
        return nil
    }
}

/// One worker lease at a time; invalidation never frees a still-running lease.
/// A stale completion may release its own lease but cannot publish a candidate.
struct DockHoverState {
    struct Lease { let id: UUID; let generation: UInt64 }
    private(set) var generation: UInt64 = 0
    private(set) var active: UUID?
    mutating func invalidate() { generation &+= 1 }
    mutating func begin() -> Lease? {
        guard active == nil else { return nil }
        let lease = Lease(id: UUID(), generation: generation)
        active = lease.id
        return lease
    }
    mutating func finish(_ lease: Lease) -> Bool {
        guard active == lease.id else { return false }
        active = nil
        return lease.generation == generation
    }
    static func isFresh(age: Double, sameProcess: Bool, sameDesktop: Bool, sameRun: Bool) -> Bool {
        age.isFinite && age >= 0 && age <= 0.8 && sameProcess && sameDesktop && sameRun
    }
    static func nearDockEdge(_ point: CGPoint, displays: [CGRect]) -> Bool {
        displays.contains { frame in
            guard frame.contains(point) else { return false }
            let margin = min(256, min(frame.width, frame.height) / 4)
            return point.x <= frame.minX + margin || point.x >= frame.maxX - margin || point.y >= frame.maxY - margin
        }
    }
    static func suppressReopen(ownMinimizePending: Bool, sinceSuccessfulMinimize: Double?) -> Bool {
        ownMinimizePending || sinceSuccessfulMinimize.map { $0 >= 0 && $0 <= 0.5 } == true
    }
}

/// Mouse release and AX completion are independent signals. A zero-duration
/// trackpad tap is valid and must wait for AX instead of cancelling it.
struct DockClickReadiness {
    enum Decision: Equatable { case wait, execute, returnToSystem }
    var released = false
    var prepared: Bool?
    var cancelled = false
    var decision: Decision {
        if cancelled || prepared == false { return .returnToSystem }
        return released && prepared == true ? .execute : .wait
    }
}

/// Cancellation shared by the main actor and the serialized Accessibility worker.
/// Every remote mutation checks this flag first. A call already inside another
/// process cannot be revoked; the check and remote call are not an atomic action.
final class DockWorkPermit: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var mutationAttempted = false
    var hasAttemptedMutation: Bool {
        lock.lock()
        defer { lock.unlock() }
        return mutationAttempted
    }
    func markMutationAttempted() {
        lock.lock()
        mutationAttempted = true
        lock.unlock()
    }
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// Public Accessibility, Quartz and AppKit handle gestures and window mutation.
/// An optional read-only native window-number bridge disambiguates layered player
/// windows; missing/failed identity still prevents interception. No Spaces API is used.
@MainActor
final class DockEngine: ObservableObject {
    @Published private(set) var status = tr("已停止")
    @Published private(set) var healthState: DockHealthState = .stopped
    @Published private(set) var healthDetail = "关闭时不会监听或自动恢复。"
    private var recoveryPolicy = RuntimeRecoveryPolicy()
    private var recoveryItem: DispatchWorkItem?
    var isRequestedToRun: Bool { recoveryPolicy.requested }
    var isRunning: Bool {
        guard recoveryPolicy.requested, let tap, CFMachPortIsValid(tap) else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }
    var excludedBundleIDs: Set<String> = [] {
        didSet {
            if oldValue != excludedBundleIDs { invalidateHover() }
            if let mutation = inFlight, excludedBundleIDs.contains(mutation.owner.bundleID) {
                mutation.permit.cancel()
            }
        }
    }

    private struct Identity: Equatable {
        let pid: pid_t
        let launchDate: Date?
        let bundleID: String
        init?(_ app: NSRunningApplication) {
            guard let bundleID = app.bundleIdentifier, !app.isTerminated else { return nil }
            pid = app.processIdentifier
            launchDate = app.launchDate
            self.bundleID = bundleID
        }
    }
    private struct Window {
        let element: AXUIElement
        let title: String
        let bounds: CGRect
        let minimized: Bool
    }
    private struct MatchedWindow {
        let element: AXUIElement
        let number: CGWindowID
        var hideLayeredPlayer = false
    }
    private struct Group {
        let owner: Identity
        let epoch: UInt64
        var windows: [AXUIElement]
        var hiddenPlayer = false
        var visibilityPending = false
    }
    private struct OwnWindow {
        weak var window: NSWindow?
        let number: Int
    }
    private struct OwnGroup {
        let owner: Identity
        let epoch: UInt64
        var windows: [OwnWindow]
    }
    private enum Action {
        case minimize(Identity, [MatchedWindow])
        case restore(Group)
        case minimizeOwn(Identity, [OwnWindow])
        case restoreOwn(OwnGroup)
    }
    private struct Mutation {
        let id = UUID()
        let owner: Identity
        let epoch: UInt64
        let generation: UInt64
        let isRestoring: Bool
        let originalClick: [CGEvent]
        let permit = DockWorkPermit()
    }
    private enum ExternalAction {
        case minimize(Identity, [MatchedWindow])
        case restore(Group)
    }
    private enum ExternalResult {
        case minimized([AXUIElement], uncertainCount: Int)
        case restored(Int, [AXUIElement])
        case playerVisibilityRequested([AXUIElement], hidden: Bool, error: AXError)
        case permissionLost
        case cancelled
    }
    private struct Gesture {
        let token: UUID
        let preparation = DockWorkPermit()
        let point: CGPoint
        let timestamp: CGEventTimestamp
        let frontmostPID: pid_t?
        let epoch: UInt64
        let clickCount: Int
        var cancelled: Bool
        var action: Action?
        let down: CGEvent
        let expectedOwner: Identity
        var up: CGEvent?
        var readiness = DockClickReadiness()
        var ownerHitConfirmed = false
    }

    private struct DockTarget { let owner: Identity; let frame: CGRect }
    private var dockTargets: [DockTarget] = []
    private var targetTimer: Timer?
    private var targetRefreshRunning = false
    private let targetQueue = DispatchQueue(label: "local.dan.real.dock-targets", qos: .userInitiated)
    private let replayMarker: Int64 = 0x5245414C444F434B
    private var replayEvents: [CGEvent] = []
    private var replayAwaiting = false
    private var replaySerial: UInt64 = 0

    private struct HoverCache {
        let owner: Identity
        let epoch: UInt64
        let generation: UInt64
        let inspectedAt: Double
        let action: Action
    }
    private var hoverCache: HoverCache?
    private var hoverState = DockHoverState()
    private var hoverPermit: DockWorkPermit?
    private var hoverScheduled: DispatchWorkItem?
    private var pointerPoint: CGPoint?
    private var lastOwnMinimizedAt: Double?

    /// Protect only the current own-minimize operation and its short native
    /// reopen tail; a later intentional reopen remains available to the user.
    var shouldSuppressOwnReopen: Bool {
        DockHoverState.suppressReopen(
            ownMinimizePending: inFlight.map { $0.owner.pid == ProcessInfo.processInfo.processIdentifier && !$0.isRestoring && !$0.permit.isCancelled } == true,
            sinceSuccessfulMinimize: lastOwnMinimizedAt.map { ProcessInfo.processInfo.systemUptime - $0 })
    }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var spaceObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var inFlight: Mutation?
    private var gesture: Gesture?
    private var groups: [pid_t: Group] = [:]
    private var ownGroup: OwnGroup?
    private let inspectionQueue = DispatchQueue(label: "local.dan.real.dock-accessibility", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private var epoch: UInt64 = 0
    private var runGeneration: UInt64 = 0

    init() {}

    /// Repeated preference application never resets an exhausted retry budget.
    func start() {
        recoveryPolicy.requestStart()
        guard recoveryItem == nil else { return }
        if tap != nil { checkHealth(); return }
        guard recoveryPolicy.attempts < RuntimeRecoveryPolicy.delays.count else { return }
        startListening()
        if healthState == .listenerFailed { scheduleRecovery() }
    }

    /// Read-only checks: no permission prompts, window changes, or listener restart.
    func checkHealth() {
        guard recoveryPolicy.requested else {
            setHealth(.stopped, "关闭时不会监听或自动恢复。"); return
        }
        if let missing = missingPermissionDetail() {
            setHealth(.permissionRequired, missing); return
        }
        if isRunning {
            recoveryPolicy.markHealthy()
            setHealth(.running, "窗口组记录已保留，正常运行不需要重启。")
        } else if recoveryItem != nil {
            setHealth(.recovering, "正在有限次数重试；不会操作已有窗口。")
        } else {
            setHealth(.listenerFailed, "监听未运行。可点击修复后台监听。")
        }
    }

    /// Only an explicit enabled feature can be repaired. Healthy checks retain
    /// the exact current window groups and do not touch the event tap.
    func repairIfNeeded() {
        guard recoveryPolicy.requested else { checkHealth(); return }
        checkHealth()
        guard healthState != .running, healthState != .permissionRequired else { return }
        DockDiagnostics.record("health.manualRequested")
        recoveryItem?.cancel(); recoveryItem = nil
        recoveryPolicy.manualRepair()
        recoverListener()
    }

    /// Safe in-memory aggregate export; does not open/read/write a log file.
    func diagnosticSnapshot() -> String {
        let snapshot: [String: Any] = [
            "schema": 1, "state": healthState.rawValue,
            "requested": recoveryPolicy.requested, "listenerEnabled": isRunning,
            "automaticAttempts": recoveryPolicy.attempts,
            "counters": DockDiagnostics.exportCounts()
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private func setHealth(_ state: DockHealthState, _ detail: String) {
        if healthState != state { healthState = state }
        if healthDetail != detail { healthDetail = detail }
    }
    private func missingPermissionDetail() -> String? {
        if !AXIsProcessTrusted() { return "请在系统设置中允许辅助功能；修复不会自动申请权限。" }
        if !CGPreflightScreenCaptureAccess() { return "请在系统设置中允许屏幕录制；修复不会自动申请权限。" }
        return nil
    }
    private func discardRecoveryInput() {
        // Recovery must never replay a stale physical click or undo a window
        // mutation. Let an already-attempted AX operation settle and be recorded.
        gesture?.preparation.cancel(); gesture = nil
        invalidateHover()
        inFlight?.permit.cancel()
        replaySerial &+= 1; replayEvents.removeAll(); replayAwaiting = false
    }
    private func scheduleRecovery() {
        guard recoveryPolicy.requested, recoveryItem == nil else { return }
        if let missing = missingPermissionDetail() {
            targetTimer?.invalidate(); targetTimer = nil
            setHealth(.permissionRequired, missing); return
        }
        guard let attempt = recoveryPolicy.nextAttempt() else {
            targetTimer?.invalidate(); targetTimer = nil
            setHealth(.listenerFailed, "自动恢复已暂停。请点击修复后台监听。")
            status = tr(DockHealthState.listenerFailed.titleKey)
            DockDiagnostics.record("health.retryExhausted"); return
        }
        setHealth(.recovering, "正在有限次数重试；不会操作已有窗口。")
        status = tr(DockHealthState.recovering.titleKey)
        DockDiagnostics.record("health.retryScheduled", ["attempt": attempt.number])
        enqueueRecovery(attempt)
    }
    private func enqueueRecovery(_ attempt: RuntimeRecoveryPolicy.Attempt) {
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.recoveryPolicy.isCurrent(attempt) else { return }
            self.recoveryItem = nil
            // Dispatch clocks may fire early. Keep the same attempt and budget.
            guard self.recoveryPolicy.isDue(attempt) else { self.enqueueRecovery(attempt); return }
            self.recoverListener()
        }
        recoveryItem = item
        let delay = max(0.001, attempt.dueAt - ProcessInfo.processInfo.systemUptime)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
    private func recoverListener() {
        guard recoveryPolicy.requested else { return }
        if let missing = missingPermissionDetail() {
            setHealth(.permissionRequired, missing); return
        }
        if isRunning { checkHealth(); return }
        discardRecoveryInput()
        // A cancelled AX write may still commit. Preserve its completion path
        // before replacing the listener generation; never issue a reverse write.
        guard inFlight == nil else { scheduleRecovery(); return }
        stopListening(keepingGroups: true, returnBufferedInput: false)
        startListening()
        if isRunning { DockDiagnostics.record("health.listenerRecovered") }
        if healthState == .listenerFailed { scheduleRecovery() }
    }
    private func listenerFailed() {
        guard recoveryPolicy.requested else { return }
        discardRecoveryInput()
        DockDiagnostics.record("health.listenerFailed")
        if let tap, CFMachPortIsValid(tap) { CGEvent.tapEnable(tap: tap, enable: false) }
        setHealth(.listenerFailed, "监听已暂停，正在准备安全恢复。")
        status = tr(DockHealthState.listenerFailed.titleKey)
        scheduleRecovery()
    }

    private func startListening() {
        guard recoveryPolicy.requested, tap == nil else { return }
        guard AXIsProcessTrusted() else {
            status = tr("需要辅助功能权限")
            setHealth(.permissionRequired, "请在系统设置中允许辅助功能；修复不会自动申请权限。")
            return
        }
        // Quartz omits other apps' window titles without this grant. Use titles
        // when available, with unique geometry for apps exposing no title.
        // Preflight only: requesting permission belongs to an explicit UI action.
        guard CGPreflightScreenCaptureAccess() else {
            status = tr("需要屏幕录制权限以识别当前桌面的窗口")
            setHealth(.permissionRequired, "请在系统设置中允许屏幕录制；修复不会自动申请权限。")
            return
        }
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .otherMouseDown, .flagsChanged, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, pointer in
            guard let pointer else { return Unmanaged.passUnretained(event) }
            // This tap is attached exclusively to the main run loop.
            return MainActor.assumeIsolated {
                Unmanaged<DockEngine>.fromOpaque(pointer).takeUnretainedValue().receive(type, event)
            }
        }
        guard let newTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            status = tr("无法监听程序坞点击，请检查辅助功能和输入监控权限")
            setHealth(.listenerFailed, "无法创建点击监听。请检查权限后修复。")
            return
        }
        guard let newSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0) else {
            CFMachPortInvalidate(newTap)
            status = tr("无法创建点击事件源")
            setHealth(.listenerFailed, "无法创建点击监听。请检查权限后修复。")
            return
        }
        tap = newTap
        source = newSource
        runGeneration &+= 1
        CFRunLoopAddSource(CFRunLoopGetMain(), newSource, .commonModes)
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.epoch &+= 1
                self.invalidatePendingWork()
                self.gesture = nil
                self.groups.removeAll()
                self.ownGroup = nil
                self.status = tr("运行中 · 桌面已切换，已清除窗口组记录")
            }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.invalidateHover()
                if let pending = self.gesture,
                   let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                   app.processIdentifier != pending.expectedOwner.pid {
                    self.releaseBufferedClick()
                }
                guard let mutation = self.inFlight,
                      let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.processIdentifier != mutation.owner.pid else { return }
                mutation.permit.cancel()
            }
        }
        CGEvent.tapEnable(tap: newTap, enable: true)
        refreshDockTargets()
        targetTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.recoveryPolicy.requested, self.recoveryItem == nil else { return }
                if self.isRunning { self.refreshDockTargets() }
                else { self.listenerFailed() }
            }
        }
        status = tr("运行中")
        if isRunning {
            recoveryPolicy.markHealthy()
            setHealth(.running, "窗口组记录已保留，正常运行不需要重启。")
        } else { setHealth(.listenerFailed, "监听未运行。可点击修复后台监听。") }
        DockDiagnostics.record("started", ["eventFlags": CGEventSource.flagsState(.combinedSessionState).rawValue])
    }

    func pauseDiagnosticsForUninstall(_ paused: Bool) { DockDiagnostics.setPaused(paused) }

    func stop() {
        recoveryItem?.cancel(); recoveryItem = nil
        recoveryPolicy.stop()
        stopListening(keepingGroups: false, returnBufferedInput: true)
        setHealth(.stopped, "关闭时不会监听或自动恢复。")
    }

    private func stopListening(keepingGroups: Bool, returnBufferedInput: Bool) {
        if returnBufferedInput { releaseBufferedClick(); flushReplay() }
        else { discardRecoveryInput() }
        targetTimer?.invalidate()
        targetTimer = nil
        dockTargets = []
        runGeneration &+= 1
        if returnBufferedInput { invalidatePendingWork() }
        else { inFlight?.permit.cancel(); inFlight = nil }
        gesture = nil
        if !keepingGroups {
            groups.removeAll(); ownGroup = nil; lastOwnMinimizedAt = nil
        }
        if let observer = spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        spaceObserver = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
        status = tr("已停止")
    }

    deinit {
        recoveryItem?.cancel()
        targetTimer?.invalidate()
        hoverScheduled?.cancel()
        hoverPermit?.cancel()
        gesture?.preparation.cancel()
        inFlight?.permit.cancel()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
    }

    // Re-post only the original, unchanged physical events when validation
    // declines a captured click. The marker prevents our tap recapturing them.
    private func replay(_ events: [CGEvent]) {
        replayEvents.append(contentsOf: events)
        pumpReplay()
    }

    private func pumpReplay() {
        guard !replayAwaiting, !replayEvents.isEmpty else { return }
        let next = replayEvents.removeFirst()
        next.setIntegerValueField(.eventSourceUserData, value: replayMarker)
        replayAwaiting = true
        replaySerial &+= 1
        let serial = replaySerial
        next.post(tap: .cgSessionEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.replayAwaiting, self.replaySerial == serial else { return }
            // Another event tap can consume a returned event. Never trap the
            // user's subsequent mouse input indefinitely waiting for its echo.
            self.listenerFailed()
            DockDiagnostics.record("replay.watchdogStopped")
        }
    }

    private func flushReplay() {
        for event in replayEvents {
            event.setIntegerValueField(.eventSourceUserData, value: replayMarker)
            event.post(tap: .cgSessionEventTap)
        }
        replayEvents.removeAll()
        replayAwaiting = false
    }

    private func releaseBufferedClick(extra: CGEvent? = nil) {
        guard let pending = gesture else { return }
        pending.preparation.cancel()
        gesture = nil
        var events = [pending.down]
        if let up = pending.up { events.append(up) }
        if let extra = extra?.copy() { events.append(extra) }
        DockDiagnostics.record("buffer.returnedToSystem", ["events": events.count])
        replay(events)
    }

    private func completePreparation(_ token: UUID, action: Action?) {
        guard gesture?.token == token else { return }
        gesture?.action = action
        gesture?.readiness.prepared = action != nil
        if gesture?.readiness.decision == .returnToSystem {
            releaseBufferedClick()
        } else {
            finishBufferedClick()
        }
    }

    private func finishBufferedClick() {
        guard let pending = gesture, pending.readiness.decision == .execute else { return }
        guard let action = pending.action, pending.epoch == epoch, !pending.cancelled,
              inFlight == nil, valid(pending.expectedOwner) else { releaseBufferedClick(); return }
        let restoring: Bool
        switch action {
        case .restore, .restoreOwn: restoring = true
        case .minimize, .minimizeOwn: restoring = false
        }
        let mutation = Mutation(owner: pending.expectedOwner, epoch: epoch,
                                generation: runGeneration, isRestoring: restoring,
                                originalClick: [pending.down] + (pending.up.map { [$0] } ?? []))
        gesture = nil
        pending.preparation.cancel()
        inFlight = mutation
        invalidateHover()
        DockDiagnostics.record(restoring ? "intercept.restore" : "intercept.minimize")
        DispatchQueue.main.async { [weak self] in self?.perform(action, mutation: mutation) }
    }

    private func receive(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if event.getIntegerValueField(.eventSourceUserData) == replayMarker {
            replayAwaiting = false
            pumpReplay()
            return Unmanaged.passUnretained(event)
        }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            listenerFailed()
            DockDiagnostics.record("tap.recoveryRequested")
            return Unmanaged.passUnretained(event)
        }
        // Keep subsequent physical events behind the older click being
        // returned. Otherwise a new mouse-up could overtake its replayed down.
        if replayAwaiting || !replayEvents.isEmpty {
            if let copy = event.copy() { replay([copy]); return nil }
            return Unmanaged.passUnretained(event)
        }
        let modified = !event.flags.intersection(DockClickPolicy.modifiers).isEmpty
        switch type {
        case .mouseMoved:
            let moved = pointerPoint.map { hypot($0.x - event.location.x, $0.y - event.location.y) > 4 } ?? true
            pointerPoint = event.location
            if moved || !isNearDockEdge(event.location) { invalidateHover() }
            if !modified { scheduleHover() }
        case .leftMouseDown:
            // Preserve order if another physical gesture arrives while AX is
            // checking the preceding one. Both are handed back to macOS.
            if gesture != nil { releaseBufferedClick(extra: event); return nil }
            pointerPoint = event.location
            hoverScheduled?.cancel(); hoverScheduled = nil
            hoverPermit?.cancel(); hoverState.invalidate()
            DockDiagnostics.record("down", ["flags": event.flags.rawValue,
                "clickCount": event.getIntegerValueField(.mouseEventClickState)])
            if let mutation = inFlight { mutation.permit.cancel(); return Unmanaged.passUnretained(event) }
            guard !modified, event.getIntegerValueField(.mouseEventClickState) == 1 else {
                return Unmanaged.passUnretained(event)
            }
            let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let matches = dockTargets.filter { $0.frame.contains(event.location) }
            guard matches.count == 1, let target = matches.first, valid(target.owner),
                  target.owner.pid == frontmost || groups[target.owner.pid] != nil
                    || (target.owner.pid == getpid() && ownGroup != nil),
                  let down = event.copy() else {
                DockDiagnostics.record("down.nativeNoCandidate")
                refreshDockTargets()
                return Unmanaged.passUnretained(event)
            }
            let token = UUID(), generation = runGeneration
            gesture = Gesture(token: token, point: event.location, timestamp: event.timestamp,
                frontmostPID: frontmost, epoch: epoch,
                clickCount: Int(event.getIntegerValueField(.mouseEventClickState)),
                cancelled: false, action: nil, down: down, expectedOwner: target.owner)
            DockDiagnostics.record("buffer.captured")
            let preparation = gesture!.preparation
            let point = event.location, applications = NSWorkspace.shared.runningApplications
            inspectionQueue.async { [weak self] in
                guard !preparation.isCancelled else { return }
                let app = Self.applicationAtDockPoint(point, applications: applications)
                Task { @MainActor [weak self] in
                    guard let self, self.runGeneration == generation,
                          self.gesture?.token == token else { return }
                    guard let app, Identity(app) == target.owner else {
                        self.completePreparation(token, action: nil); return
                    }
                    self.gesture?.ownerHitConfirmed = true
                    self.prepare(token, app: app)
                }
            }
            // Bound the delay even when another application's AX server hangs.
            DispatchQueue.main.asyncAfter(deadline: .now() + DockClickPolicy.maximumDuration) { [weak self] in
                guard let self, self.gesture?.token == token else { return }
                DockDiagnostics.record("buffer.deadline")
                if let pending = self.gesture,
                   let group = self.groups[pending.expectedOwner.pid],
                   DockClickPolicy.restoreAtPreparationDeadline(
                       released: pending.readiness.released, verifiedTarget: pending.ownerHitConfirmed,
                       currentSavedGroup: group.owner == pending.expectedOwner && group.epoch == self.epoch
                           && pending.epoch == self.epoch && !group.windows.isEmpty) {
                    self.completePreparation(token, action: .restore(group))
                } else {
                    self.releaseBufferedClick()
                }
            }
            return nil
        case .leftMouseDragged, .rightMouseDown, .otherMouseDown, .scrollWheel:
            invalidateHover()
            inFlight?.permit.cancel()
            if gesture != nil { releaseBufferedClick(extra: event); return nil }
        case .flagsChanged:
            if modified {
                invalidateHover(); inFlight?.permit.cancel()
                if gesture != nil { releaseBufferedClick(extra: event); return nil }
            }
        case .leftMouseUp:
            DockDiagnostics.record("up")
            guard let pending = gesture else { return Unmanaged.passUnretained(event) }
            let duration = event.timestamp >= pending.timestamp ? Double(event.timestamp - pending.timestamp) / 1_000_000_000 : -1
            let travel = hypot(event.location.x - pending.point.x, event.location.y - pending.point.y)
            guard DockClickPolicy.accepts(duration: duration, travel: travel, modified: modified,
                dragged: pending.cancelled, clickCount: pending.clickCount, prepared: true,
                sameDesktop: pending.epoch == epoch), let up = event.copy() else {
                releaseBufferedClick(extra: event); return nil
            }
            gesture?.up = up
            gesture?.readiness.released = true
            DockDiagnostics.record("buffer.released", ["durationMS": Int(duration * 1000),
                "ready": pending.readiness.prepared == true])
            finishBufferedClick()
            return nil
        default: break
        }
        return Unmanaged.passUnretained(event)
    }

    private func prepare(_ token: UUID, app: NSRunningApplication?) {
        DockDiagnostics.record("prepare.enter", ["hasApp": app != nil, "gestureAlive": gesture?.token == token, "targetIsFrontmost": app?.processIdentifier == gesture?.frontmostPID])
        guard let pending = gesture, pending.token == token, !pending.cancelled,
              pending.epoch == epoch, tap != nil, inFlight == nil,
              let app, let owner = Identity(app),
              !excludedBundleIDs.contains(owner.bundleID) else { completePreparation(token, action: nil); return }
        if let cache = hoverCache,
           DockHoverState.isFresh(age: ProcessInfo.processInfo.systemUptime - cache.inspectedAt,
                sameProcess: cache.owner == owner, sameDesktop: cache.epoch == epoch,
                sameRun: cache.generation == runGeneration) {
            let canUse: Bool
            switch cache.action {
            case .minimize, .minimizeOwn: canUse = pending.frontmostPID == owner.pid
            case .restore, .restoreOwn: canUse = true
            }
            if canUse {
                completePreparation(token, action: cache.action)
                hoverCache = nil
                DockDiagnostics.record("prepare.hoverReady")
                return
            }
        }
        if owner.pid == ProcessInfo.processInfo.processIdentifier {
            if let group = ownGroup,
               DockClickPolicy.mayRestore(savedEpoch: group.epoch, currentEpoch: epoch,
                                          sameProcess: group.owner == owner, excluded: false),
               group.windows.contains(where: { item in
                   guard let window = item.window else { return false }
                   return window.windowNumber == item.number && window.isMiniaturized
               }) {
                completePreparation(token, action: .restoreOwn(group))
            } else {
                ownGroup = nil
                guard pending.frontmostPID == owner.pid else { completePreparation(token, action: nil); return }
                let windows = NSApp.windows.filter(isOrdinaryOwnWindow).map { OwnWindow(window: $0, number: $0.windowNumber) }
                DockDiagnostics.record("prepare.ownWindows", ["count": windows.count])
                completePreparation(token, action: windows.isEmpty ? nil : .minimizeOwn(owner, windows))
            }
            return
        }
        if let group = groups[owner.pid],
           DockClickPolicy.mayRestore(savedEpoch: group.epoch, currentEpoch: epoch,
                                      sameProcess: group.owner == owner, excluded: false),
           !group.windows.isEmpty {
            if group.hiddenPlayer {
                if app.isHidden || group.visibilityPending {
                    completePreparation(token, action: .restore(group)); return
                }
                // A native/manual unhide consumes this ownership. Inspect a
                // later click normally rather than hiding a stale saved group.
                groups.removeValue(forKey: owner.pid)
                prepare(token, app: app)
                return
            }
            let generation = runGeneration
            inspectionQueue.async { [weak self] in
                guard !pending.preparation.isCancelled else { return }
                let live = Self.applicationWindows(owner.pid)
                let surviving = live.map { live in
                    group.windows.filter { window in live.contains(where: { CFEqual($0, window) }) }
                } ?? group.windows
                var states: [Bool?] = []
                if live != nil {
                    for window in surviving {
                        guard !pending.preparation.isCancelled else { return }
                        states.append(Self.bool(window, kAXMinimizedAttribute))
                    }
                }
                let decision = DockClickPolicy.savedGroupPreparation(minimizedStates: live == nil ? nil : states)
                Task { @MainActor [weak self] in
                    guard let self, self.runGeneration == generation,
                          self.gesture?.token == token, self.gesture?.cancelled == false,
                          self.epoch == pending.epoch else { return }
                    switch decision {
                    case .inspectActiveWindows:
                        // A user may already have restored or closed the saved
                        // windows. Do not swallow a click on an obsolete group.
                        self.groups.removeValue(forKey: owner.pid)
                        self.prepare(token, app: app)
                    case .restore:
                        self.completePreparation(token, action: .restore(Group(owner: owner, epoch: group.epoch, windows: surviving)))
                    }
                }
            }
            return
        }
        groups.removeValue(forKey: owner.pid)
        guard pending.frontmostPID == owner.pid else { completePreparation(token, action: nil); return }
        let generation = runGeneration
        inspectionQueue.async { [weak self] in
            guard !pending.preparation.isCancelled else { return }
            let began = ProcessInfo.processInfo.systemUptime
            let windows = Self.currentWindows(owner.pid, permit: pending.preparation)
            DockDiagnostics.record("prepare.windowsFinished", ["count": windows.count, "elapsedMS": Int((ProcessInfo.processInfo.systemUptime - began) * 1000), "cancelled": pending.preparation.isCancelled])
            Task { @MainActor [weak self] in
                guard let self, self.runGeneration == generation,
                      self.gesture?.token == token, self.gesture?.cancelled == false,
                      self.epoch == pending.epoch else { return }
                guard DockClickPolicy.mayMinimize(targetPID: owner.pid, frontmostPID: pending.frontmostPID,
                    excluded: self.excludedBundleIDs.contains(owner.bundleID), windows: windows.count) else {
                    self.completePreparation(token, action: nil)
                    return
                }
                self.completePreparation(token, action: .minimize(owner, windows))
                DockDiagnostics.record("prepare.ready", ["count": windows.count])
            }
        }
    }

    private func invalidateHover() {
        hoverState.invalidate()
        hoverPermit?.cancel()
        hoverCache = nil
        hoverScheduled?.cancel()
        hoverScheduled = nil
    }

    private func isNearDockEdge(_ point: CGPoint) -> Bool {
        let displays = NSScreen.screens.compactMap { screen -> CGRect? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return CGDisplayBounds(number.uint32Value)
        }
        return DockHoverState.nearDockEdge(point, displays: displays)
    }

    private func scheduleHover() {
        guard tap != nil, healthState == .running, gesture == nil, inFlight == nil, let point = pointerPoint, isNearDockEdge(point),
              hoverState.active == nil, hoverScheduled == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hoverScheduled = nil
            self.inspectHover()
        }
        hoverScheduled = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: item)
    }

    private func inspectHover() {
        guard tap != nil, healthState == .running, gesture == nil, inFlight == nil, let point = pointerPoint,
              let lease = hoverState.begin() else { return }
        let permit = DockWorkPermit()
        hoverPermit = permit
        let generation = runGeneration, desktop = epoch
        let inspectedAt = ProcessInfo.processInfo.systemUptime
        let applications = NSWorkspace.shared.runningApplications
        let savedGroups = groups
        let exclusions = excludedBundleIDs
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        inspectionQueue.async { [weak self] in
            let app = permit.isCancelled ? nil : Self.applicationAtDockPoint(point, applications: applications)
            let owner = app.flatMap(Identity.init)
            var prepared: Action?
            if let owner, !permit.isCancelled, !exclusions.contains(owner.bundleID), owner.pid != ProcessInfo.processInfo.processIdentifier {
                if let group = savedGroups[owner.pid], group.owner == owner, group.epoch == desktop {
                    if group.hiddenPlayer {
                        if app?.isHidden == true || group.visibilityPending { prepared = .restore(group) }
                    } else {
                        let live = Self.applicationWindows(owner.pid)
                        let surviving = live.map { live in
                            group.windows.filter { window in live.contains { CFEqual($0, window) } }
                        } ?? group.windows
                        let states: [Bool?]? = live == nil ? nil : surviving.map {
                            permit.isCancelled ? nil : Self.bool($0, kAXMinimizedAttribute)
                        }
                        if !permit.isCancelled, DockClickPolicy.savedGroupPreparation(minimizedStates: states) == .restore {
                            prepared = .restore(Group(owner: owner, epoch: desktop, windows: surviving))
                        }
                    }
                } else if owner.pid == frontmost {
                    let windows = Self.currentWindows(owner.pid, permit: permit)
                    if !windows.isEmpty { prepared = .minimize(owner, windows) }
                }
            }
            let action = prepared
            Task { @MainActor [weak self] in
                guard let self else { return }
                let ownsLease = self.hoverState.active == lease.id
                let mayPublish = self.hoverState.finish(lease)
                if ownsLease { self.hoverPermit = nil }
                guard mayPublish, !permit.isCancelled, self.tap != nil, self.runGeneration == generation,
                      self.epoch == desktop, self.gesture == nil, self.inFlight == nil else {
                    self.scheduleHover()
                    return
                }
                guard let owner, self.valid(owner) else { return }
                if owner.pid == ProcessInfo.processInfo.processIdentifier {
                    // AppKit's exact own-window queries stay on the main actor.
                    // The normal fresh-hit prepare path is already fast for self.
                    self.hoverCache = nil
                } else if let action {
                    self.hoverCache = HoverCache(owner: owner, epoch: desktop, generation: generation,
                        inspectedAt: inspectedAt, action: action)
                    DockDiagnostics.record("hover.ready")
                } else {
                    self.hoverCache = nil
                }
                // No work is queued while a lease is active. Refresh only while
                // hovering a real application icon; ordinary mouse motion does
                // not create a perpetual background AX polling loop.
                if self.pointerPoint.map({ hypot($0.x - point.x, $0.y - point.y) <= 4 }) == true { self.scheduleHover() }
            }
        }
    }

    private func isOrdinaryOwnWindow(_ window: NSWindow) -> Bool {
        window.isVisible && !window.isMiniaturized && window.isOnActiveSpace && window.canBecomeMain
            && window.level == .normal && window.styleMask.contains(.titled)
            && window.styleMask.contains(.miniaturizable)
            && DockClickPolicy.isOrdinaryWindow(fullScreen: window.styleMask.contains(.fullScreen),
                modal: NSApp.modalWindow === window || window.isSheet, hasSheet: window.attachedSheet != nil)
    }

    private func invalidatePendingWork() {
        releaseBufferedClick()
        invalidateHover()
        gesture?.preparation.cancel()
        inFlight?.permit.cancel()
        inFlight = nil
    }

    private func returnFailedAction(_ mutation: Mutation, changedWindows: Int = 0) {
        guard changedWindows == 0, !mutation.permit.isCancelled,
              epoch == mutation.epoch, tap != nil, runGeneration == mutation.generation else { return }
        if mutation.isRestoring {
            // Bringing an application forward does not issue the Dock's reopen
            // action, which could restore a manually minimized, unowned window.
            if valid(mutation.owner) {
                NSRunningApplication(processIdentifier: mutation.owner.pid)?.activate(options: [])
            }
            DockDiagnostics.record("restore.nativeReplaySuppressed")
            return
        }
        guard DockClickPolicy.shouldReturnFailedAction(changedWindows: changedWindows,
            cancelled: mutation.permit.isCancelled, sameDesktop: epoch == mutation.epoch,
            sameRun: tap != nil && runGeneration == mutation.generation,
            restoring: mutation.isRestoring,
            mutationAttempted: mutation.permit.hasAttemptedMutation) else { return }
        DockDiagnostics.record("action.returnedToSystem")
        replay(mutation.originalClick)
    }

    private func perform(_ action: Action, mutation: Mutation) {
        DockDiagnostics.record("perform.enter", ["cancelled": mutation.permit.isCancelled])
        guard inFlight?.id == mutation.id else { return }
        guard tap != nil, runGeneration == mutation.generation, epoch == mutation.epoch,
              !mutation.permit.isCancelled, valid(mutation.owner) else {
            inFlight = nil
            returnFailedAction(mutation)
            return
        }
        switch action {
        case let .minimize(owner, planned):
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == owner.pid else {
                inFlight = nil
                returnFailedAction(mutation)
                return
            }
            performExternal(.minimize(owner, planned), mutation: mutation)
        case let .restore(group):
            guard group.epoch == epoch else { inFlight = nil; return }
            performExternal(.restore(group), mutation: mutation)
        case let .minimizeOwn(owner, planned):
            defer { if inFlight?.id == mutation.id { inFlight = nil }; scheduleHover() }
            guard valid(owner), NSWorkspace.shared.frontmostApplication?.processIdentifier == owner.pid else {
                returnFailedAction(mutation); return
            }
            var minimized: [OwnWindow] = []
            for item in planned {
                guard let window = item.window, window.windowNumber == item.number, isOrdinaryOwnWindow(window) else { continue }
                mutation.permit.markMutationAttempted()
                window.miniaturize(nil)
                // AppKit may publish isMiniaturized only after its animation.
                // Retain the eligible window we requested, as with async AX.
                minimized.append(item)
            }
            if !minimized.isEmpty {
                ownGroup = OwnGroup(owner: owner, epoch: epoch, windows: minimized)
                lastOwnMinimizedAt = ProcessInfo.processInfo.systemUptime
            }
            status = String(format: tr("已最小化 %ld 个窗口"), minimized.count)
            DockDiagnostics.record("perform.ownMinimized", ["count": minimized.count])
            returnFailedAction(mutation, changedWindows: minimized.count)
        case let .restoreOwn(group):
            guard valid(group.owner), group.epoch == epoch else {
                inFlight = nil
                returnFailedAction(mutation)
                return
            }
            lastOwnMinimizedAt = nil
            let requested = group.windows.filter { item in
                guard let window = item.window else { return false }
                return window.windowNumber == item.number && window.isMiniaturized
            }
            guard !requested.isEmpty else {
                ownGroup = nil
                inFlight = nil
                returnFailedAction(mutation)
                return
            }
            for item in requested {
                mutation.permit.markMutationAttempted()
                item.window?.deminiaturize(nil)
            }
            // AppKit's restore animation publishes isMiniaturized later. Activate
            // after the request, then settle asynchronously instead of reporting
            // zero restored windows and leaving Real behind another application.
            NSRunningApplication.current.activate(options: [])
            settleOwnRestore(group, requested: requested, mutation: mutation,
                began: ProcessInfo.processInfo.systemUptime)
        }
    }

    private func settleOwnRestore(_ group: OwnGroup, requested: [OwnWindow],
                                  mutation: Mutation, began: Double) {
        guard inFlight?.id == mutation.id, tap != nil,
              runGeneration == mutation.generation, epoch == mutation.epoch else { return }
        let states: [Bool?] = requested.map { item in
            guard let window = item.window, window.windowNumber == item.number else { return nil }
            return window.isMiniaturized
        }
        let progress = DockRestoreProgress(minimizedStates: states)
        if progress.shouldWait(elapsed: ProcessInfo.processInfo.systemUptime - began,
                               cancelled: mutation.permit.isCancelled) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
                self?.settleOwnRestore(group, requested: requested, mutation: mutation, began: began)
            }
            return
        }
        let remaining = requested.enumerated().compactMap { index, item in
            states[index] == true ? item : nil
        }
        ownGroup = remaining.isEmpty ? nil : OwnGroup(owner: group.owner, epoch: group.epoch, windows: remaining)
        inFlight = nil
        scheduleHover()
        if !mutation.permit.isCancelled {
            status = String(format: tr("已恢复 %ld 个窗口"), progress.restored)
                + (remaining.isEmpty ? "" : String(format: tr("；%ld 个窗口未能恢复"), remaining.count))
        }
        DockDiagnostics.record("perform.ownRestored", ["count": progress.restored, "remaining": remaining.count])
        returnFailedAction(mutation, changedWindows: progress.restored)
    }

    private func performExternal(_ action: ExternalAction, mutation: Mutation) {
        inspectionQueue.async { [weak self] in
            let result = Self.executeExternal(action, permit: mutation.permit)
            Task { @MainActor [weak self] in self?.finishExternal(result, mutation: mutation) }
        }
    }

    private func finishExternal(_ result: ExternalResult, mutation: Mutation) {
        guard inFlight?.id == mutation.id else { return }
        inFlight = nil
        defer { scheduleHover() }
        guard tap != nil, runGeneration == mutation.generation, epoch == mutation.epoch,
              valid(mutation.owner) else {
            returnFailedAction(mutation)
            return
        }
        // After a new user interaction, preserve successfully changed members
        // for exact later restoration, but never steal focus or overwrite status.
        let publish = !mutation.permit.isCancelled
        switch result {
        case let .minimized(windows, uncertainCount):
            DockDiagnostics.record("perform.externalMinimized", ["count": windows.count - uncertainCount,
                "uncertain": uncertainCount])
            if !windows.isEmpty {
                groups[mutation.owner.pid] = Group(owner: mutation.owner, epoch: mutation.epoch, windows: windows)
            }
            returnFailedAction(mutation, changedWindows: windows.count)
            if publish {
                // A timed-out write is retained for restoration safety, but
                // must not be presented as a confirmed successful minimization.
                status = uncertainCount > 0 ? tr("运行中")
                    : (windows.isEmpty ? tr("无法最小化任何已安全匹配的窗口")
                        : String(format: tr("已最小化 %ld 个窗口"), windows.count))
            }
        case let .restored(count, remaining):
            DockDiagnostics.record("perform.externalRestored", ["count": count, "remaining": remaining.count])
            if remaining.isEmpty { groups.removeValue(forKey: mutation.owner.pid) }
            else { groups[mutation.owner.pid] = Group(owner: mutation.owner, epoch: mutation.epoch, windows: remaining) }
            returnFailedAction(mutation, changedWindows: count)
            if publish {
                if count > 0 { NSRunningApplication(processIdentifier: mutation.owner.pid)?.activate(options: []) }
                status = String(format: tr("已恢复 %ld 个窗口"), count)
                    + (remaining.isEmpty ? "" : String(format: tr("；%ld 个窗口未能恢复"), remaining.count))
            }
        case let .playerVisibilityRequested(windows, hidden, error):
            // The worker already issued an AX request. Cancellation must not
            // discard an operation which can still finish in the other app.
            let owned = Group(owner: mutation.owner, epoch: mutation.epoch, windows: windows,
                              hiddenPlayer: true, visibilityPending: true)
            groups[mutation.owner.pid] = owned
            inFlight = mutation
            DockDiagnostics.record(hidden ? "perform.playerHide" : "perform.playerShow",
                ["axError": error.rawValue, "cancelled": !publish])
            if !hidden, publish, error == .success || error == .cannotComplete {
                NSRunningApplication(processIdentifier: mutation.owner.pid)?.activate(options: [])
            }
            settlePlayerVisibility(hidden: hidden, count: windows.count, mutation: mutation,
                                   began: ProcessInfo.processInfo.systemUptime, minimumWait: 0.05)
        case .permissionLost:
            returnFailedAction(mutation)
            if publish {
                status = tr("辅助功能权限已被撤销")
                setHealth(.permissionRequired, "请在系统设置中允许辅助功能；修复不会自动申请权限。")
            }
        case .cancelled:
            returnFailedAction(mutation)
        }
    }

    private func settlePlayerVisibility(hidden: Bool, count: Int, mutation: Mutation, began: Double,
                                        minimumWait: Double = 0) {
        guard inFlight?.id == mutation.id, tap != nil, runGeneration == mutation.generation,
              epoch == mutation.epoch else { return }
        guard valid(mutation.owner), let app = NSRunningApplication(processIdentifier: mutation.owner.pid) else {
            groups.removeValue(forKey: mutation.owner.pid)
            inFlight = nil
            scheduleHover()
            return
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        let confirmed = app.isHidden == hidden && elapsed >= minimumWait
        if !confirmed, elapsed < 1.0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
                self?.settlePlayerVisibility(hidden: hidden, count: count, mutation: mutation,
                                            began: began, minimumWait: minimumWait)
            }
            return
        }
        // Request acceptance is not completion. Keep ownership on a timeout so
        // a late hide or failed unhide can still be restored by the next click.
        // Hide itself activates the previous app, so cancellation may be set by
        // that notification; bookkeeping must still settle without stealing focus.
        if confirmed {
            if hidden { groups[mutation.owner.pid]?.visibilityPending = false }
            else { groups.removeValue(forKey: mutation.owner.pid) }
        }
        inFlight = nil
        scheduleHover()
        DockDiagnostics.record(hidden ? "perform.playerHidden" : "perform.playerShown",
            ["confirmed": confirmed, "elapsedMS": Int(elapsed * 1000), "cancelled": mutation.permit.isCancelled])
        if !mutation.permit.isCancelled {
            status = confirmed ? String(format: tr(hidden ? "已收起 %ld 个窗口" : "已恢复 %ld 个窗口"), count)
                : tr("运行中")
        }
    }

    nonisolated private static func executeExternal(_ action: ExternalAction, permit: DockWorkPermit) -> ExternalResult {
        guard !permit.isCancelled else { return .cancelled }
        guard AXIsProcessTrusted() else { return .permissionLost }
        if case let .restore(group) = action, group.hiddenPlayer {
            guard matchesProcess(group.owner), group.windows.count == 1,
                  let saved = group.windows.first,
                  let live = applicationWindows(group.owner.pid),
                  live.contains(where: { CFEqual($0, saved) }),
                  string(saved, kAXIdentifierAttribute) == "QQMianWindow",
                  bool(saved, kAXMinimizedAttribute) == false,
                  bool(saved, kAXModalAttribute) == false, bool(saved, "AXFullScreen") == false,
                  let children = attribute(saved, kAXChildrenAttribute) as? [AXUIElement],
                  !children.contains(where: { string($0, kAXRoleAttribute) == kAXSheetRole }) else { return .cancelled }
            // Hidden QQ normally exposes only its saved main window. A newly
            // opened login/dialog/ordinary window is not part of this cohort;
            // let the user's normal activation handle that changed layout.
            for element in live {
                guard !permit.isCancelled else { return .cancelled }
                if CFEqual(element, saved) { continue }
                let smallTooltip = string(element, kAXSubroleAttribute) == kAXDialogSubrole
                    && (string(element, kAXIdentifierAttribute)?.hasPrefix("_NS:") == true)
                    && bounds(element).map { $0.width <= 200 && $0.height <= 40 } == true
                    && bool(element, kAXModalAttribute) == false
                    && bool(element, "AXFullScreen") == false
                if smallTooltip { continue }
                // During a delayed hide, the original lyric surface may still
                // be visible. Requalify the complete current cohort before
                // sending its inverse request, rather than discarding ownership.
                if group.visibilityPending {
                    let current = currentWindows(group.owner.pid, permit: permit)
                    guard current.count == 1, current[0].hideLayeredPlayer,
                          CFEqual(current[0].element, saved) else { return .cancelled }
                    return requestPlayerVisibility(group.owner, windows: group.windows, hidden: false, permit: permit)
                }
                DockDiagnostics.record("restore.playerCohortChanged")
                return .cancelled
            }
            return requestPlayerVisibility(group.owner, windows: group.windows, hidden: false, permit: permit)
        }
        switch action {
        case let .minimize(owner, planned):
            guard matchesProcess(owner, requireActive: true) else { return .cancelled }
            let current = currentWindows(owner.pid, permit: permit)
            if planned.count == 1, current.count == 1,
               planned[0].hideLayeredPlayer, current[0].hideLayeredPlayer,
               planned[0].number == current[0].number,
               CFEqual(planned[0].element, current[0].element), !permit.isCancelled {
                return requestPlayerVisibility(owner, windows: [current[0].element], hidden: true, permit: permit)
            }
            var minimized: [AXUIElement] = []
            var uncertainCount = 0
            for window in planned {
                guard !permit.isCancelled, matchesProcess(owner, requireActive: true) else { break }
                guard current.contains(where: { $0.number == window.number && CFEqual($0.element, window.element) }) else { continue }
                // Recheck cancellation immediately before every remote mutation.
                guard !permit.isCancelled else { break }
                AXUIElementSetMessagingTimeout(window.element, 0.08)
                if DockClickPolicy.requestMinimization(readMinimized: { bool(window.element, kAXMinimizedAttribute) }, request: {
                    guard !permit.isCancelled, matchesProcess(owner, requireActive: true) else { return .rejected }
                    permit.markMutationAttempted()
                    let result = AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
                    if result == .success { return .accepted }
                    // cannotComplete can mean a timed-out request which the
                    // recipient still executes. Keep this exact eligible member
                    // tracked, but never claim its state is already confirmed.
                    if result == .cannotComplete {
                        uncertainCount += 1
                        return .uncertain
                    }
                    return .rejected
                }) {
                    minimized.append(window.element)
                }
            }
            return .minimized(minimized, uncertainCount: uncertainCount)
        case let .restore(group):
            guard matchesProcess(group.owner) else { return .cancelled }
            let began = ProcessInfo.processInfo.systemUptime
            let deadline = began + 2.0
            let application = AXUIElementCreateApplication(group.owner.pid)
            guard let live: [AXUIElement] = restoreRead(application, kAXWindowsAttribute,
                stage: "restore.listRead", deadline: deadline, permit: permit) else {
                DockDiagnostics.record("restore.listUnavailable", ["remaining": group.windows.count,
                    "elapsedMS": Int((ProcessInfo.processInfo.systemUptime - began) * 1000)])
                return .restored(0, group.windows)
            }
            var pending: [AXUIElement] = []
            var restored = 0
            var writes = 0, rejectedWrites = 0, unknownReads = 0, alreadyRestored = 0, closed = 0
            // Send each eligible request at most once. Read failures may be
            // retried within a common deadline; ambiguous writes never are.
            for (index, window) in group.windows.enumerated() {
                guard !permit.isCancelled, matchesProcess(group.owner),
                      ProcessInfo.processInfo.systemUptime < deadline else {
                    pending.append(contentsOf: group.windows[index...]); break
                }
                guard live.contains(where: { CFEqual($0, window) }) else { closed += 1; continue }
                guard let minimized: Bool = restoreRead(window, kAXMinimizedAttribute,
                    stage: "restore.stateBefore", deadline: deadline, permit: permit) else {
                    unknownReads += 1
                    pending.append(window)
                    continue
                }
                guard minimized else { alreadyRestored += 1; continue }
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard !permit.isCancelled, remaining >= 0.005 else {
                    pending.append(contentsOf: group.windows[index...]); break
                }
                AXUIElementSetMessagingTimeout(window, min(0.30, Float(remaining)))
                permit.markMutationAttempted()
                let writeBegan = ProcessInfo.processInfo.systemUptime
                let result = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                writes += 1
                if result != .success { rejectedWrites += 1 }
                DockDiagnostics.record("restore.write", ["axError": result.rawValue,
                    "elapsedMS": Int((ProcessInfo.processInfo.systemUptime - writeBegan) * 1000)])
                DockDiagnostics.record("restore.write.result.\(result.rawValue)")
                pending.append(window)
            }
            while !pending.isEmpty, !permit.isCancelled, matchesProcess(group.owner) {
                var unresolved: [AXUIElement] = []
                for window in pending {
                    if permit.isCancelled || ProcessInfo.processInfo.systemUptime >= deadline {
                        unresolved.append(window)
                    } else if let minimized: Bool = restoreRead(window, kAXMinimizedAttribute,
                        stage: "restore.stateAfter", deadline: deadline, permit: permit), !minimized {
                        restored += 1
                    } else { unresolved.append(window) }
                }
                pending = unresolved
                if pending.isEmpty || ProcessInfo.processInfo.systemUptime >= deadline { break }
                Thread.sleep(forTimeInterval: 0.025)
            }
            DockDiagnostics.record("restore.summary", ["writes": writes, "nonSuccessWrites": rejectedWrites,
                "unreadableBefore": unknownReads, "alreadyRestored": alreadyRestored, "closed": closed,
                "confirmed": restored, "remaining": pending.count, "cancelled": permit.isCancelled,
                "elapsedMS": Int((ProcessInfo.processInfo.systemUptime - began) * 1000)])
            return .restored(restored, pending)
        }
    }

    nonisolated private static func requestPlayerVisibility(_ owner: Identity, windows: [AXUIElement], hidden: Bool,
                                                          permit: DockWorkPermit) -> ExternalResult {
        guard !permit.isCancelled, matchesProcess(owner, requireActive: hidden) else { return .cancelled }
        let app = AXUIElementCreateApplication(owner.pid)
        guard AXUIElementSetMessagingTimeout(app, 0.08) == .success else { return .cancelled }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(app, kAXHiddenAttribute as CFString, &settable) == .success,
              settable.boolValue, let wasHidden = bool(app, kAXHiddenAttribute) else { return .cancelled }
        if hidden && wasHidden { return .cancelled }
        guard !permit.isCancelled, matchesProcess(owner, requireActive: hidden) else { return .cancelled }
        permit.markMutationAttempted()
        let result = AXUIElementSetAttributeValue(app, kAXHiddenAttribute as CFString,
                                                 hidden ? kCFBooleanTrue : kCFBooleanFalse)
        // Never replay after an attempted visibility write: a timeout/error can
        // still be followed by a delayed state change. Settle actual state and
        // retain the exact restore ownership instead of immediately undoing it.
        return .playerVisibilityRequested(windows, hidden: hidden, error: result)
    }

    nonisolated private static func restoreRead<Value>(_ element: AXUIElement, _ name: String,
        stage: String, deadline: Double, permit: DockWorkPermit) -> Value? {
        DockAXReadRetry.read(deadline: deadline, isCancelled: { permit.isCancelled }) { timeout, attempt in
            AXUIElementSetMessagingTimeout(element, timeout)
            var raw: CFTypeRef?
            let began = ProcessInfo.processInfo.systemUptime
            let error = AXUIElementCopyAttributeValue(element, name as CFString, &raw)
            let value = raw as? Value
            DockDiagnostics.record(stage, ["axError": error.rawValue, "attempt": attempt,
                "timeoutMS": Int(timeout * 1000), "typedValue": value != nil,
                "elapsedMS": Int((ProcessInfo.processInfo.systemUptime - began) * 1000)])
            DockDiagnostics.record("\(stage).result.\(error.rawValue)")
            return (error, value)
        }
    }

    nonisolated private static func matchesProcess(_ owner: Identity, requireActive: Bool = false) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: owner.pid) else { return false }
        return Identity(app) == owner && (!requireActive || app.isActive)
    }

    private func valid(_ identity: Identity) -> Bool {
        guard !excludedBundleIDs.contains(identity.bundleID), let app = NSRunningApplication(processIdentifier: identity.pid) else { return false }
        return Identity(app) == identity
    }

    private func refreshDockTargets() {
        guard tap != nil, !targetRefreshRunning else { return }
        // Keep the first snapshot ready before the user's first click; after
        // that, refresh only while the pointer is near a possible Dock edge.
        guard dockTargets.isEmpty || pointerPoint.map(isNearDockEdge) == true else { return }
        targetRefreshRunning = true
        let generation = runGeneration
        let applications = NSWorkspace.shared.runningApplications
        targetQueue.async { [weak self] in
            let targets = Self.readDockTargets(applications)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.targetRefreshRunning = false
                guard self.tap != nil, self.runGeneration == generation else { return }
                self.dockTargets = targets
                DockDiagnostics.record("targets.refreshed", ["count": targets.count])
            }
        }
    }

    nonisolated private static func readDockTargets(_ applications: [NSRunningApplication]) -> [DockTarget] {
        guard let dock = applications.first(where: { $0.bundleIdentifier == "com.apple.dock" }) else { return [] }
        let root = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.05)
        var pending: [(AXUIElement, Int)] = [(root, 0)]
        var targets: [DockTarget] = []
        // The Dock exposes one AXList containing its items. Bound traversal so
        // a future accessibility hierarchy cannot produce an endless walk.
        var visited = 0
        while let (element, depth) = pending.popLast(), visited < 160 {
            visited += 1
            AXUIElementSetMessagingTimeout(element, 0.05)
            if string(element, kAXRoleAttribute) == "AXDockItem",
               string(element, kAXSubroleAttribute) == "AXApplicationDockItem",
               let value = attribute(element, kAXURLAttribute), CFGetTypeID(value) == CFURLGetTypeID(),
               let frame = bounds(element) {
                let url = (value as! URL).standardizedFileURL
                let matches = applications.filter { $0.bundleURL?.standardizedFileURL == url && !$0.isTerminated }
                if matches.count == 1, let owner = Identity(matches[0]) {
                    targets.append(DockTarget(owner: owner, frame: frame))
                }
            } else if depth < 3, let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                pending.append(contentsOf: children.prefix(100).map { ($0, depth + 1) })
            }
        }
        return targets
    }

    nonisolated private static func applicationAtDockPoint(_ point: CGPoint, applications: [NSRunningApplication]) -> NSRunningApplication? {
        guard let dock = applications.first(where: { $0.bundleIdentifier == "com.apple.dock" }) else { return nil }
        // Hit-test the actual frontmost element, not Dock's hidden geometry
        // under an overlay, menu, or another application's window.
        let systemAX = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemAX, 0.08)
        var hit: AXUIElement?
        let hitResult = AXUIElementCopyElementAtPosition(systemAX, Float(point.x), Float(point.y), &hit)
        guard hitResult == .success, let element = hit else {
            DockDiagnostics.record("hit.failed", ["axError": hitResult.rawValue]); return nil
        }
        var hitPID: pid_t = 0
        guard AXUIElementGetPid(element, &hitPID) == .success, hitPID == dock.processIdentifier else {
            DockDiagnostics.record("hit.notDock"); return nil
        }
        DockDiagnostics.record("hit.dock")
        for _ in 0..<5 {
            guard let element = hit else { break }
            let role = string(element, kAXRoleAttribute)
            let subrole = string(element, kAXSubroleAttribute)
            DockDiagnostics.record("hit.element", ["role": role ?? "", "subrole": subrole ?? ""])
            if role == "AXDockItem",
               subrole == "AXApplicationDockItem",
               let value = attribute(element, kAXURLAttribute), CFGetTypeID(value) == CFURLGetTypeID() {
                let url = (value as! URL).standardizedFileURL
                let matches = applications.filter { $0.bundleURL?.standardizedFileURL == url && !$0.isTerminated }
                DockDiagnostics.record("hit.urlMatches", ["count": matches.count])
                return matches.count == 1 ? matches[0] : nil
            }
            guard let parent = attribute(element, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            hit = (parent as! AXUIElement)
        }
        return nil
    }

    nonisolated private static func applicationWindows(_ pid: pid_t) -> [AXUIElement]? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.08)
        return attribute(app, kAXWindowsAttribute) as? [AXUIElement]
    }

    nonisolated private static func currentWindows(_ pid: pid_t, permit: DockWorkPermit? = nil) -> [MatchedWindow] {
        guard permit?.isCancelled != true else { return [] }
        guard let allElements = applicationWindows(pid) else { DockDiagnostics.record("windows.axListFailed"); return [] }
        DockDiagnostics.record("windows.axList", ["count": allElements.count])
        // Compare against ALL standard AX windows, including minimized and other
        // Spaces. A same-title/same-frame duplicate anywhere makes a match unsafe.
        var axWindows: [Window] = []
        for element in allElements {
            guard permit?.isCancelled != true else { return [] }
            guard let role = string(element, kAXRoleAttribute) else {
                DockDiagnostics.record("windows.unreadableRole"); return []
            }
            guard role == kAXWindowRole else { continue }
            guard let subrole = string(element, kAXSubroleAttribute) else {
                DockDiagnostics.record("windows.unreadableSubrole"); return []
            }
            guard subrole == kAXStandardWindowSubrole else { continue }
            guard let bounds = bounds(element), let minimized = bool(element, kAXMinimizedAttribute) else {
                // An unidentifiable standard window could be a conflicting match.
                DockDiagnostics.record("windows.unidentifiableStandard")
                return []
            }
            // Even an untitled standard window participates in ambiguity checks.
            // Missing title never makes another same-frame window disappear.
            let title = string(element, kAXTitleAttribute) ?? ""
            axWindows.append(Window(element: element, title: title, bounds: bounds, minimized: minimized))
        }
        guard let listed = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let cgWindows: [(CGWindowID, String, CGRect)] = listed.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (info[kCGWindowIsOnscreen as String] as? Bool) == true,
                  (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0 > 0,
                  let frame = info[kCGWindowBounds as String] as? NSDictionary,
                  let rectangle = CGRect(dictionaryRepresentation: frame),
                  let number = info[kCGWindowNumber as String] as? NSNumber else { return nil }
            return (number.uint32Value, info[kCGWindowName as String] as? String ?? "", rectangle)
        }
        let allowGeometryFallback = DockClickPolicy.allowsGeometryFallback(
            bundleID: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier)
        DockDiagnostics.record("windows.candidates", ["axStandard": axWindows.count,
            "cgTitledOnscreen": cgWindows.filter { !$0.1.isEmpty }.count, "cgLayer0Onscreen": cgWindows.count])
        var result: [MatchedWindow] = []
        var windowNumbers: [CGWindowID?]?
        for (axIndex, window) in axWindows.enumerated() where !window.minimized {
            guard permit?.isCancelled != true else { return [] }
            guard DockClickPolicy.isOrdinaryWindow(fullScreen: bool(window.element, "AXFullScreen") == true,
                modal: bool(window.element, kAXModalAttribute) == true,
                hasSheet: (attribute(window.element, kAXChildrenAttribute) as? [AXUIElement] ?? []).contains { string($0, kAXRoleAttribute) == kAXSheetRole }) else { continue }
            var settable = DarwinBoolean(false)
            guard AXUIElementIsAttributeSettable(window.element, kAXMinimizedAttribute as CFString, &settable) == .success, settable.boolValue else { continue }
            let geometryIndex = DockClickPolicy.uniqueWindowIndex(title: window.title, bounds: window.bounds,
                    accessibility: axWindows.map { ($0.title, $0.bounds) },
                    onScreen: cgWindows.map { ($0.1, $0.2) },
                    allowGeometryFallback: allowGeometryFallback)
            var index = geometryIndex
            if index == nil, allowGeometryFallback {
                if windowNumbers == nil {
                    var numbers: [CGWindowID?] = []
                    for item in axWindows {
                        guard permit?.isCancelled != true else { return [] }
                        numbers.append(DockNativeWindowNumber.read(item.element))
                    }
                    windowNumbers = numbers
                }
                if let numbers = windowNumbers {
                    index = DockClickPolicy.identifiedWindowIndex(number: numbers[axIndex], bounds: window.bounds,
                        accessibilityNumbers: numbers, onScreen: cgWindows.map { ($0.0, $0.2) })
                }
                if index != nil { DockDiagnostics.record("windows.nativeIDMatched") }
            }
            guard let index else { continue }
            if geometryIndex != nil && (window.title.isEmpty || cgWindows[index].1.isEmpty || window.title != cgWindows[index].1) {
                DockDiagnostics.record("windows.geometryMatched")
            }
            result.append(MatchedWindow(element: window.element, number: cgWindows[index].0))
        }
        if result.count == 1,
           NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.tencent.QQMusicMac" {
            var surfaces: [LayeredPlayerWindow] = []
            for element in allElements {
                guard permit?.isCancelled != true else { return [] }
                guard string(element, kAXRoleAttribute) == kAXWindowRole,
                      let subrole = string(element, kAXSubroleAttribute), let frame = bounds(element),
                      let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] else {
                    surfaces = []; break
                }
                var settable = DarwinBoolean(false)
                let error = AXUIElementIsAttributeSettable(element, kAXMinimizedAttribute as CFString, &settable)
                surfaces.append(LayeredPlayerWindow(number: DockNativeWindowNumber.read(element),
                    subrole: subrole, identifier: string(element, kAXIdentifierAttribute) ?? "", frame: frame,
                    minimized: bool(element, kAXMinimizedAttribute), minimizable: error == .success ? settable.boolValue : nil,
                    fullScreen: bool(element, "AXFullScreen"), modal: bool(element, kAXModalAttribute),
                    hasSheet: children.contains { string($0, kAXRoleAttribute) == kAXSheetRole }))
            }
            if LayeredPlayerPolicy.canHide(bundleID: "com.tencent.QQMusicMac", mainNumber: result[0].number,
                windows: surfaces, onScreen: cgWindows.map { ($0.0, $0.2) }) {
                result[0].hideLayeredPlayer = true
                DockDiagnostics.record("windows.layeredPlayer")
            }
        }
        DockDiagnostics.record("windows.matched", ["count": result.count])
        return result
    }

    nonisolated private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
    }
    nonisolated private static func string(_ element: AXUIElement, _ name: String) -> String? { attribute(element, name) as? String }
    nonisolated private static func bool(_ element: AXUIElement, _ name: String) -> Bool? { attribute(element, name) as? Bool }
    nonisolated private static func bounds(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
              dimensions.width > 0, dimensions.height > 0 else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
}


/// Optional macOS AX window-number bridge. This symbol is not public API:
/// resolve it at runtime, accept only success/nonzero, and retain the existing
/// public matcher if unavailable. It only reads the ID; mutations use public
/// AXMinimized/AppKit APIs after ordinary-window/Space and cohort checks.
/// Keeping the exact ID avoids conflating QQ's separate same-frame surfaces.
enum DockNativeWindowNumber {
    private typealias Reader = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let reader: Reader? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: Reader.self)
    }()
    static func read(_ element: AXUIElement) -> CGWindowID? {
        guard let reader else { return nil }
        guard AXUIElementSetMessagingTimeout(element, 0.08) == .success else { return nil }
        var number = kCGNullWindowID
        guard reader(element, &number) == .success, number != kCGNullWindowID else { return nil }
        return number
    }
}

/// Small aggregate-only diagnostic snapshot. No titles, URLs, application IDs,
/// window positions or event history are persisted. Disk work never runs on the
/// event-tap thread; the single snapshot is bounded and replaced atomically.
private enum DockDiagnostics {
    private static let queue = DispatchQueue(label: "local.dan.real.dock-diagnostics", qos: .utility)
    private static var counts: [String: Int] = [:]
    private static var latest: [String: [String: Any]] = [:]
    private static var pendingWrite = false
    private static var paused = false
    static func setPaused(_ value: Bool) { queue.sync { paused = value } }
    static func exportCounts() -> [String: Int] {
        queue.sync { RuntimeDiagnosticPolicy.safeCounts(counts) }
    }
    static func record(_ stage: String, _ values: [String: Any] = [:]) {
        queue.async {
            guard !paused else { return }
            counts[stage, default: 0] += 1
            if !values.isEmpty { latest[stage] = values }
            guard !pendingWrite else { return }
            pendingWrite = true
            queue.asyncAfter(deadline: .now() + 1) {
                pendingWrite = false
                guard !paused else { return }
                let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/real", isDirectory: true)
                let snapshot: [String: Any] = ["schema": 1, "pid": ProcessInfo.processInfo.processIdentifier,
                    "updatedAt": ISO8601DateFormatter().string(from: Date()), "counts": counts, "latest": latest]
                guard let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys]) else { return }
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try? data.write(to: folder.appendingPathComponent("dock-diagnostics.json"), options: .atomic)
            }
        }
    }
}
