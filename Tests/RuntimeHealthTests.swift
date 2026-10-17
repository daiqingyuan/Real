import Foundation

/// All clocks, retry state and diagnostic data belong to this test. Never
/// creates an event tap, reads TCC, changes settings or touches live windows.
func runRuntimeHealthTests() -> [String] {
    var failures: [String] = []
    func check(_ value: Bool, _ message: String) {
        if !value { failures.append("Runtime health: " + message) }
    }
    var clock: TimeInterval = 100
    var policy = RuntimeRecoveryPolicy(now: { clock })
    check(!policy.requested && policy.nextAttempt() == nil, "disabled policy never queues recovery")
    check(policy.requestStart(), "explicit enable starts a recovery generation")
    check(!policy.requestStart(), "reapplying enabled preferences does not reset a generation")
    let generation = policy.generation
    guard let first = policy.nextAttempt() else { return failures + ["Runtime health: missing first attempt"] }
    check(first.number == 1 && first.dueAt == 100.5 && policy.attempts == 1,
          "first recovery has a finite half-second delay")
    check(!policy.isDue(first), "early dispatch cannot run a recovery")
    clock = 100.5
    check(policy.isDue(first), "injected monotonic deadline is honored")
    check(!policy.requestStart() && policy.generation == generation && policy.attempts == 1,
          "normal start calls cannot replenish a retry budget")
    let second = policy.nextAttempt()!
    check(second.number == 2 && second.dueAt == 102.5 && !policy.isCurrent(first),
          "second attempt backs off and supersedes the old token")
    clock = 103
    let third = policy.nextAttempt()!
    check(third.number == 3 && third.dueAt == 108, "third attempt has five-second backoff")
    check(policy.nextAttempt() == nil && policy.attempts == 3, "failed episode cannot retry forever")
    check(!policy.requestStart() && policy.nextAttempt() == nil,
          "preference refresh cannot resurrect exhausted recovery")

    policy.stop()
    clock = 1_000
    check(!policy.requested && !policy.isCurrent(third) && !policy.isDue(third),
          "disable invalidates scheduled callbacks even after their deadline")
    policy.manualRepair()
    check(!policy.requested && policy.nextAttempt() == nil, "repair cannot enable a stopped feature")
    check(policy.requestStart(), "a later user enable starts a fresh bounded episode")
    let beforeManual = policy.nextAttempt()!
    policy.manualRepair()
    check(!policy.isCurrent(beforeManual) && policy.requested && policy.attempts == 0,
          "manual repair cancels old callbacks and replenishes only an enabled service")
    let afterManual = policy.nextAttempt()!
    check(afterManual.number == 1 && afterManual.generation != beforeManual.generation,
          "manual recovery has its own generation")

    policy.markHealthy()
    clock += 30
    policy.markHealthy()
    let unstable = policy.nextAttempt()!
    check(unstable.number == 2, "a short healthy interval does not erase repeated failures")
    policy.markHealthy()
    clock += 61
    policy.markHealthy()
    let stable = policy.nextAttempt()!
    check(stable.number == 1 && stable.generation != unstable.generation,
          "a full healthy minute permits a new bounded incident budget")
    policy.stop()
    check(!policy.isDue(stable), "stop, uninstall or preview cancellation defeats a pending recovery")

    var badTime = TimeInterval.nan
    var nonfinite = RuntimeRecoveryPolicy(now: { badTime })
    nonfinite.requestStart()
    check(nonfinite.nextAttempt() == nil, "nonfinite clocks cannot create unbounded timers")
    badTime = 20
    let valid = nonfinite.nextAttempt()!
    badTime = .infinity
    check(!nonfinite.isDue(valid), "nonfinite time cannot execute a queued attempt")
    badTime = 19
    check(!nonfinite.isDue(valid), "a backwards clock cannot execute early")

    let exported = RuntimeDiagnosticPolicy.safeCounts([
        "started": 1, "perform.playerHidden": 8, "restore.write.result.-25204": 2,
        "com.private.player": 1, "A private song title": 9,
        "hit.file:///Users/private/music": 10, "windows.歌曲": 2,
        "perform.negative": -1, String(repeating: "x", count: 100): 2
    ])
    check(exported == ["started": 1, "perform.playerHidden": 8, "restore.write.result.-25204": 2],
          "export accepts only numeric internal aggregates and rejects private text or arbitrary identifiers")
    var many: [String: Int] = [:]
    for value in 0..<300 { many["health.counter.\(value)"] = value }
    check(RuntimeDiagnosticPolicy.safeCounts(many).count == 256, "diagnostic export has a fixed entry bound")
    check(DockHealthState.running.titleKey != DockHealthState.listenerFailed.titleKey,
          "healthy and failed states have distinct explanations")
    return failures
}

#if RUNTIME_HEALTH_STANDALONE
@main struct RuntimeHealthTestsMain {
    static func main() {
        let failures = runRuntimeHealthTests()
        if failures.isEmpty { print("PASS: bounded runtime recovery and safe aggregate diagnostics") }
        else { failures.forEach { print("FAIL: " + $0) }; exit(1) }
    }
}
#endif
