import Foundation

enum DockHealthState: String, Codable {
    case stopped, running, permissionRequired, listenerFailed, recovering

    var titleKey: String {
        switch self {
        case .stopped: return "程序坞功能已关闭"
        case .running: return "程序坞后台运行正常"
        case .permissionRequired: return "程序坞功能需要权限"
        case .listenerFailed: return "程序坞监听需要修复"
        case .recovering: return "正在恢复程序坞监听"
        }
    }
}

/// A finite retry budget, with no timers or side effects. A new explicit enable,
/// a manual repair, or a full minute of healthy operation starts a new budget.
/// Generation tokens make queued repairs harmless after stop/disable/uninstall.
struct RuntimeRecoveryPolicy {
    struct Attempt: Equatable {
        let generation: UInt64
        let number: Int
        let dueAt: TimeInterval
    }

    private let now: () -> TimeInterval
    private(set) var requested = false
    private(set) var attempts = 0
    private(set) var generation: UInt64 = 0
    private var healthySince: TimeInterval?
    static let delays: [TimeInterval] = [0.5, 2, 5]

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }
    @discardableResult mutating func requestStart() -> Bool {
        guard !requested else { return false }
        requested = true; resetBudget(); return true
    }
    mutating func stop() {
        requested = false; resetBudget()
    }
    mutating func manualRepair() {
        guard requested else { return }
        resetBudget()
    }
    mutating func markHealthy() {
        if healthySince == nil { healthySince = now() }
    }
    mutating func nextAttempt() -> Attempt? {
        guard requested else { return nil }
        let time = now()
        guard time.isFinite else { return nil }
        if let since = healthySince, time >= since, time - since >= 60 { resetBudget() }
        healthySince = nil
        guard attempts < Self.delays.count else { return nil }
        let delay = Self.delays[attempts]
        attempts += 1
        return Attempt(generation: generation, number: attempts, dueAt: time + delay)
    }
    func isCurrent(_ attempt: Attempt) -> Bool {
        requested && generation == attempt.generation && attempts == attempt.number
    }
    func isDue(_ attempt: Attempt) -> Bool {
        let time = now()
        return isCurrent(attempt) && time.isFinite && time >= attempt.dueAt
    }
    private mutating func resetBudget() {
        generation &+= 1; attempts = 0; healthySince = nil
    }
}

/// Export counters only, never the diagnostic engine's latest event values.
/// All names originate in the application; reject arbitrary text defensively.
enum RuntimeDiagnosticPolicy {
    static func safeCounts(_ counts: [String: Int]) -> [String: Int] {
        let roots: Set<String> = ["started", "replay", "buffer", "intercept", "prepare", "perform", "restore", "hover", "windows", "targets", "hit", "down", "up", "tap", "health", "action"]
        let permitted = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let entries = counts.filter { key, value in
            value >= 0 && key.count <= 80 && !key.isEmpty
                && key.unicodeScalars.allSatisfy(permitted.contains)
                && roots.contains(String(key.split(separator: ".").first ?? ""))
        }.sorted { $0.key < $1.key }.prefix(256)
        return Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0.value) })
    }
}
