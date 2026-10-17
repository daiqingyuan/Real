import Foundation
import CoreGraphics
import ApplicationServices

/// Returns failure descriptions; the application's --self-test entry point can
/// invoke this alongside other suites. No AX permissions or live windows needed.
func runDockPolicyTests() -> [String] {
    var failures: [String] = []
    func check(_ condition: Bool, _ name: String) { if !condition { failures.append(name) } }
    check(DockClickPolicy.accepts(duration: 0.15, travel: 1, modified: false, dragged: false, clickCount: 1), "ordinary click accepted")
    check(!DockClickPolicy.accepts(duration: 0.7, travel: 0, modified: false, dragged: false, clickCount: 1), "long press passes through")
    check(!DockClickPolicy.accepts(duration: 0.1, travel: 8, modified: false, dragged: false, clickCount: 1), "movement passes through")
    check(!DockClickPolicy.accepts(duration: 0.1, travel: 0, modified: false, dragged: true, clickCount: 1), "drag returning to origin passes through")
    check(!DockClickPolicy.accepts(duration: 0.1, travel: 0, modified: true, dragged: false, clickCount: 1), "modified click passes through")
    check(!DockClickPolicy.accepts(duration: -1, travel: 0, modified: false, dragged: false, clickCount: 1), "invalid timestamp passes through")
    check(!DockClickPolicy.accepts(duration: 0.1, travel: 0, modified: false, dragged: false, clickCount: 2), "second multi-click passes through")
    let capsLockOnly: CGEventFlags = [.maskAlphaShift]
    check(DockClickPolicy.accepts(duration: 0.1, travel: 0,
        modified: !capsLockOnly.intersection(DockClickPolicy.modifiers).isEmpty, dragged: false, clickCount: 1),
        "Caps Lock alone does not disable ordinary Dock clicks")
    for heldModifier in [CGEventFlags.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn] {
        let flags = capsLockOnly.union(heldModifier)
        check(!DockClickPolicy.accepts(duration: 0.1, travel: 0,
            modified: !flags.intersection(DockClickPolicy.modifiers).isEmpty, dragged: false, clickCount: 1),
            "held Dock modifier remains native with Caps Lock enabled: \(heldModifier.rawValue)")
    }
    check(DockClickPolicy.mayMinimize(targetPID: 10, frontmostPID: 10, excluded: false, windows: 2), "frontmost group minimizes")
    check(!DockClickPolicy.mayMinimize(targetPID: 10, frontmostPID: 11, excluded: false, windows: 2), "background app passes through")
    check(!DockClickPolicy.mayMinimize(targetPID: 10, frontmostPID: nil, excluded: false, windows: 2), "unknown frontmost app passes through")
    check(!DockClickPolicy.mayMinimize(targetPID: 10, frontmostPID: 10, excluded: true, windows: 2), "excluded app passes through")
    check(!DockClickPolicy.mayMinimize(targetPID: 10, frontmostPID: 10, excluded: false, windows: 0), "empty group passes through")
    check(DockClickPolicy.mayRestore(savedEpoch: 2, currentEpoch: 2, sameProcess: true, excluded: false), "same desktop group restores")
    check(!DockClickPolicy.mayRestore(savedEpoch: 2, currentEpoch: 3, sameProcess: true, excluded: false), "desktop change prevents restore")
    check(!DockClickPolicy.mayRestore(savedEpoch: 2, currentEpoch: 2, sameProcess: false, excluded: false), "PID reuse prevents restore")
    check(!DockClickPolicy.mayRestore(savedEpoch: 2, currentEpoch: 2, sameProcess: true, excluded: true), "new exclusion prevents restore")
    let frame = CGRect(x: 10, y: 30, width: 800, height: 600)
    let signature = ("Document", frame)
    check(DockClickPolicy.uniqueWindowIndex(title: "Document", bounds: frame, accessibility: [signature], onScreen: [signature]) == 0, "unique public API window match")
    check(DockClickPolicy.uniqueWindowIndex(title: "Document", bounds: frame, accessibility: [signature, signature], onScreen: [signature]) == nil, "duplicate AX window on another desktop prevents matching")
    check(DockClickPolicy.uniqueWindowIndex(title: "Document", bounds: frame, accessibility: [signature], onScreen: [signature, signature]) == nil, "duplicate Quartz identity prevents matching")
    check(DockClickPolicy.uniqueWindowIndex(title: "Document", bounds: frame, accessibility: [signature], onScreen: []) == nil, "offscreen or minimized window has no match")
    check(DockClickPolicy.uniqueWindowIndex(title: "", bounds: frame, accessibility: [("", frame)], onScreen: [("", frame)]) == nil, "missing title fails open")
    check(DockClickPolicy.uniqueWindowIndex(title: "Document", bounds: frame, accessibility: [signature], onScreen: [("Other", frame)]) == nil, "geometry alone does not establish identity")
    check(DockClickPolicy.uniqueWindowIndex(title: "Document", bounds: frame, accessibility: [signature], onScreen: [("Document", frame.offsetBy(dx: 4, dy: 0))]) == nil, "moved geometry invalidates a match")
    let chromeGeometry = DockClickPolicy.allowsGeometryFallback(bundleID: "com.google.Chrome")
    check(chromeGeometry, "identified Chrome may use unique-geometry fallback")
    check(DockClickPolicy.allowsGeometryFallback(bundleID: "com.netease.163music") &&
        DockClickPolicy.allowsGeometryFallback(bundleID: "example.newlyinstalled.app"),
        "new applications need no per-app compatibility whitelist")
    check(!DockClickPolicy.allowsGeometryFallback(bundleID: nil) &&
        !DockClickPolicy.allowsGeometryFallback(bundleID: "  "), "unknown app identity cannot use fallback")
    check(DockClickPolicy.uniqueWindowIndex(title: "Browser AX", bounds: frame,
        accessibility: [("Browser AX", frame)], onScreen: [("Different Quartz title", frame)],
        allowGeometryFallback: chromeGeometry) == 0, "Chrome title mismatch with mutually unique exact frame matches")
    for duplicateTitle in ["Other desktop", "Minimized window", ""] {
        check(DockClickPolicy.uniqueWindowIndex(title: "Browser AX", bounds: frame,
            accessibility: [("Browser AX", frame), (duplicateTitle, frame)],
            onScreen: [("Different Quartz title", frame)], allowGeometryFallback: chromeGeometry) == nil,
            "same-frame other-Space/minimized/untitled AX window vetoes Chrome fallback")
    }
    check(DockClickPolicy.uniqueWindowIndex(title: "Browser AX", bounds: frame,
        accessibility: [("Browser AX", frame)], onScreen: [("Different Quartz title", frame), ("", frame)],
        allowGeometryFallback: chromeGeometry) == nil, "untitled same-frame CG window vetoes Chrome fallback")
    check(DockClickPolicy.uniqueWindowIndex(title: "Browser AX", bounds: frame,
        accessibility: [("Browser AX", frame)], onScreen: [("Different Quartz title", frame.offsetBy(dx: 3, dy: 0))],
        allowGeometryFallback: chromeGeometry) == nil, "Chrome fallback never relaxes geometry agreement")
    check(DockClickPolicy.uniqueWindowIndex(title: "Browser AX", bounds: frame,
        accessibility: [("Browser AX", frame)], onScreen: [], allowGeometryFallback: chromeGeometry) == nil,
        "Chrome fallback cannot acquire offscreen or already minimized window")
    check(DockClickPolicy.uniqueWindowIndex(title: "Document", bounds: frame,
        accessibility: [signature, ("", frame)], onScreen: [signature]) == nil,
        "unknown AX title at same frame cannot bypass strict signature ambiguity")
    check(DockClickPolicy.uniqueWindowIndex(title: "Document", bounds: frame,
        accessibility: [signature], onScreen: [signature, ("", frame)]) == nil,
        "untitled CG window at same frame remains an ambiguity veto even with strict match")
    for names in [("", ""), ("", "WindowServer title"), ("Application title", "")] {
        let ax = (names.0, frame), cg = (names.1, frame)
        check(DockClickPolicy.uniqueWindowIndex(title: names.0, bounds: frame,
            accessibility: [ax], onScreen: [cg], allowGeometryFallback: true) == 0,
            "untitled or one-sided title matches by mutually unique geometry")
        for duplicate in ["", "Other Space", "Minimized window"] {
            check(DockClickPolicy.uniqueWindowIndex(title: names.0, bounds: frame,
                accessibility: [ax, (duplicate, frame)], onScreen: [cg], allowGeometryFallback: true) == nil,
                "untitled fallback rejects same-frame AX ambiguity across all Spaces")
            check(DockClickPolicy.uniqueWindowIndex(title: names.0, bounds: frame,
                accessibility: [ax], onScreen: [cg, (duplicate, frame)], allowGeometryFallback: true) == nil,
                "untitled fallback rejects same-frame Quartz ambiguity")
        }
    }
    check(DockClickPolicy.uniqueWindowIndex(title: "", bounds: frame,
        accessibility: [("", frame)], onScreen: [], allowGeometryFallback: true) == nil,
        "untitled offscreen or already minimized window cannot be acquired")
    check(DockClickPolicy.uniqueWindowIndex(title: "", bounds: frame,
        accessibility: [("", frame)], onScreen: [("", frame.offsetBy(dx: 4, dy: 0))],
        allowGeometryFallback: true) == nil, "untitled window still requires matching geometry")
    check(DockClickPolicy.uniqueWindowIndex(title: "Missing candidate", bounds: frame,
        accessibility: [("Different AX window", frame)], onScreen: [("", frame)],
        allowGeometryFallback: true) == nil, "geometry fallback cannot invent a missing AX candidate")
    let overlap = ("Overlapping document", frame)
    check(DockClickPolicy.uniqueWindowIndex(title: "Document", bounds: frame,
        accessibility: [signature, overlap], onScreen: [signature, overlap],
        allowGeometryFallback: true) == 0, "strict title matching still distinguishes overlapping titled windows")
    let neighbor = frame.offsetBy(dx: 2, dy: 0), midpoint = frame.offsetBy(dx: 1, dy: 0)
    for candidate in [frame, neighbor] {
        check(DockClickPolicy.uniqueWindowIndex(title: "", bounds: candidate,
            accessibility: [("", frame), ("", neighbor)], onScreen: [("", midpoint)],
            allowGeometryFallback: true) == nil, "untitled tolerance matching must be unique in reverse too")
        check(DockClickPolicy.uniqueWindowIndex(title: "Document", bounds: candidate,
            accessibility: [("Document", frame), ("Document", neighbor)], onScreen: [("Document", midpoint)],
            allowGeometryFallback: true) == nil, "strict tolerance matching cannot map two AX windows to one CG window")
    }
    check(DockClickPolicy.uniqueWindowIndex(title: "Document", bounds: frame,
        accessibility: [signature, ("", neighbor)], onScreen: [("Document", midpoint)],
        allowGeometryFallback: true) == nil, "unknown title near selected CG frame vetoes strict and geometry matches")
    check(DockClickPolicy.uniqueWindowIndex(title: "", bounds: frame,
        accessibility: [("", frame)], onScreen: [("", midpoint)], allowGeometryFallback: true) == 0,
        "one-point frame tolerance still accepts a genuinely unique untitled window")

    // QQ Music's lyric surface and its real main window have the same empty
    // title/frame. Only the main window's actual native ID may disambiguate.
    let qqFrame = CGRect(x: 116, y: 33, width: 1280, height: 868)
    let qqSurfaces: [(CGWindowID, CGRect)] = [(12468, qqFrame), (4949, qqFrame)]
    check(DockClickPolicy.uniqueWindowIndex(title: "", bounds: qqFrame,
        accessibility: [("", qqFrame)], onScreen: [("", qqFrame), ("", qqFrame)],
        allowGeometryFallback: true) == nil, "QQ duplicated surface fixture remains ambiguous without native identity")
    check(DockClickPolicy.identifiedWindowIndex(number: 4949, bounds: qqFrame,
        accessibilityNumbers: [4949], onScreen: qqSurfaces) == 1,
        "QQ main ID selects its own CG surface rather than lyric overlay")
    check(DockClickPolicy.identifiedWindowIndex(number: 4949, bounds: qqFrame,
        accessibilityNumbers: [4949], onScreen: Array(qqSurfaces.reversed())) == 0,
        "native identity is independent of Quartz stacking/list order")
    for number in [nil, 0, 9999] as [CGWindowID?] {
        check(DockClickPolicy.identifiedWindowIndex(number: number, bounds: qqFrame,
            accessibilityNumbers: [4949], onScreen: qqSurfaces) == nil,
            "missing/zero/unlisted native identity cannot acquire a window")
    }
    check(DockClickPolicy.identifiedWindowIndex(number: 4949, bounds: qqFrame,
        accessibilityNumbers: [4949], onScreen: [(12468, qqFrame)]) == nil,
        "same-frame overlay cannot prove an off-Space or minimized main window is visible")
    check(DockClickPolicy.identifiedWindowIndex(number: 4949, bounds: qqFrame,
        accessibilityNumbers: [4949, 4949], onScreen: qqSurfaces) == nil,
        "duplicate AX references to one ID remain an ambiguity")
    check(DockClickPolicy.identifiedWindowIndex(number: 4949, bounds: qqFrame,
        accessibilityNumbers: [4949], onScreen: qqSurfaces + [(4949, qqFrame)]) == nil,
        "duplicate Quartz IDs cannot pass identity verification")
    check(DockClickPolicy.identifiedWindowIndex(number: 4949, bounds: qqFrame,
        accessibilityNumbers: [4949], onScreen: [(4949, qqFrame.offsetBy(dx: 4, dy: 0))]) == nil,
        "even a native ID must agree with current frame")
    check(DockClickPolicy.identifiedWindowIndex(number: 4949, bounds: qqFrame,
        accessibilityNumbers: [4949], onScreen: [(4949, CGRect(x: 0, y: 0, width: 0, height: 0))]) == nil,
        "invalid CG geometry is rejected even with a native ID")
    check(DockClickPolicy.identifiedWindowIndex(number: 4949,
        bounds: CGRect(x: CGFloat.nan, y: 0, width: 1280, height: 868),
        accessibilityNumbers: [4949], onScreen: qqSurfaces) == nil,
        "nonfinite AX geometry cannot acquire an ID")
    check(DockClickPolicy.identifiedWindowIndex(number: 4949, bounds: qqFrame,
        accessibilityNumbers: [4949, 9999], onScreen: qqSurfaces) == 1,
        "different native IDs keep same-frame windows on other Spaces distinct")

    check(DockClickPolicy.identifiedWindowIndex(number: 4949, bounds: qqFrame,
        accessibilityNumbers: [4949, nil], onScreen: qqSurfaces) == 1,
        "an unreadable sibling ID does not invalidate independently proven visible candidate identity")
    check(DockClickPolicy.identifiedWindowIndex(number: nil, bounds: qqFrame,
        accessibilityNumbers: [4949, nil], onScreen: qqSurfaces) == nil,
        "an unreadable candidate itself cannot borrow a sibling's visible ID")

    check(DockClickPolicy.accepts(duration: 0.45, travel: 4, modified: false, dragged: false, clickCount: 1), "inclusive duration and travel boundary")
    check(!DockClickPolicy.accepts(duration: 0.450001, travel: 4, modified: false, dragged: false, clickCount: 1), "just beyond long press threshold")
    check(!DockClickPolicy.accepts(duration: 0.1, travel: -1, modified: false, dragged: false, clickCount: 1), "negative travel rejected")
    check(!DockClickPolicy.accepts(duration: .nan, travel: 0, modified: false, dragged: false, clickCount: 1), "NaN timing rejected")
    check(!DockClickPolicy.accepts(duration: 0.1, travel: .infinity, modified: false, dragged: false, clickCount: 1), "infinite travel rejected")
    check(!DockClickPolicy.accepts(duration: 0.01, travel: 0, modified: false, dragged: false, clickCount: 1, prepared: false), "fast click without completed AX preparation passes through")
    check(!DockClickPolicy.accepts(duration: 0.1, travel: 0, modified: false, dragged: false, clickCount: 1, sameDesktop: false), "desktop change between down and up passes through")
    check(DockClickPolicy.uniqueWindowIndex(title: "Document", bounds: .zero, accessibility: [("Document", .zero)], onScreen: [("Document", .zero)]) == nil, "zero-sized window rejected")
    check(DockClickPolicy.isOrdinaryWindow(fullScreen: false, modal: false, hasSheet: false), "ordinary window is eligible")
    check(!DockClickPolicy.isOrdinaryWindow(fullScreen: true, modal: false, hasSheet: false), "fullscreen window excluded")
    check(!DockClickPolicy.isOrdinaryWindow(fullScreen: false, modal: true, hasSheet: false), "modal window excluded")
    check(!DockClickPolicy.isOrdinaryWindow(fullScreen: false, modal: false, hasSheet: true), "document with attached sheet excluded")
    check(DockClickPolicy.savedGroupDecision(minimizedStates: [true, false]) == .restore, "restore only tracked group when at least one member remains minimized")
    check(DockClickPolicy.savedGroupDecision(minimizedStates: [nil, false]) == .retain, "transient AX failure cannot erase group")
    check(DockClickPolicy.savedGroupDecision(minimizedStates: [true, nil]) == .restore, "known member can restore while retaining unreadable member")
    check(DockClickPolicy.savedGroupDecision(minimizedStates: [false, false]) == .discard, "all manually restored members retire group")
    check(DockClickPolicy.savedGroupDecision(minimizedStates: []) == .discard, "closed group retires after successful empty AX response")

    check(DockClickPolicy.savedGroupPreparation(minimizedStates: nil) == .restore,
        "failed saved-group AX window-list read routes to exact restore, not native C")
    check(DockClickPolicy.savedGroupPreparation(minimizedStates: [nil, false]) == .restore,
        "unknown saved member retains restore intent during preparation")
    check(DockClickPolicy.savedGroupPreparation(minimizedStates: [true, nil]) == .restore,
        "known and unknown minimized members retain exact restore path")
    check(DockClickPolicy.savedGroupPreparation(minimizedStates: [false, false]) == .inspectActiveWindows,
        "known manually restored group can be retired before ordinary minimize")
    check(DockClickPolicy.savedGroupPreparation(minimizedStates: []) == .inspectActiveWindows,
        "confirmed closed group can be retired")
    check(DockClickPolicy.restoreAtPreparationDeadline(released: true, verifiedTarget: true, currentSavedGroup: true),
        "verified released saved-group click keeps exact restore on AX deadline")
    check(!DockClickPolicy.restoreAtPreparationDeadline(released: true, verifiedTarget: false, currentSavedGroup: true),
        "stale Dock frame alone never authorizes deadline restore")
    check(!DockClickPolicy.restoreAtPreparationDeadline(released: false, verifiedTarget: true, currentSavedGroup: true),
        "held click remains native at deadline")
    check(!DockClickPolicy.restoreAtPreparationDeadline(released: true, verifiedTarget: true, currentSavedGroup: false),
        "old desktop or process group cannot authorize deadline restore")

    // Fake asynchronous application: AX accepts the write before publishing the
    // state. Restoration ownership must survive that delay, without a second write.
    var publishedMinimized: Bool? = false
    var requests = 0
    let owned = DockClickPolicy.requestMinimization(readMinimized: { publishedMinimized }, request: {
        requests += 1
        return .accepted
    })
    check(owned && requests == 1 && publishedMinimized == false, "accepted asynchronous minimize is retained before state publication")
    publishedMinimized = true
    check(owned && DockClickPolicy.savedGroupDecision(minimizedStates: [publishedMinimized]) == .restore, "delayed minimization remains restorable")
    let manuallyMinimized = DockClickPolicy.requestMinimization(readMinimized: { true }, request: { requests += 1; return .accepted })
    check(!manuallyMinimized && requests == 1, "manually minimized window is never mutated or acquired")
    let unknownMinimized = DockClickPolicy.requestMinimization(readMinimized: { nil }, request: { requests += 1; return .accepted })
    check(!unknownMinimized && requests == 1, "unreadable minimized state cannot acquire ownership")
    let rejected = DockClickPolicy.requestMinimization(readMinimized: { false }, request: { requests += 1; return .rejected })
    check(!rejected && requests == 2, "rejected AX request is never added to group")
    let timedOut = DockClickPolicy.requestMinimization(readMinimized: { false }, request: {
        requests += 1
        return .uncertain
    })
    check(timedOut && requests == 3, "timed-out minimize retains exact member that may commit later")
    var hover = DockHoverState()
    let oldLease = hover.begin()!
    check(hover.begin() == nil, "hover worker cannot accumulate a second inspection")
    hover.invalidate()
    check(hover.begin() == nil, "cancelling hover does not free the occupied worker lease")
    check(!hover.finish(oldLease), "completion invalidated by move/Space/stop cannot publish cache")
    let newLease = hover.begin()!
    check(!hover.finish(oldLease) && hover.active == newLease.id, "late old completion cannot clear newer hover lease")
    check(hover.finish(newLease) && hover.active == nil, "current completion releases worker and can publish")
    check(DockHoverState.isFresh(age: 0.8, sameProcess: true, sameDesktop: true, sameRun: true), "fresh hover boundary accepted")
    check(!DockHoverState.isFresh(age: 0.801, sameProcess: true, sameDesktop: true, sameRun: true), "stale hover cache rejected")
    check(!DockHoverState.isFresh(age: 0, sameProcess: false, sameDesktop: true, sameRun: true), "fresh hit on another app cannot use cached action")
    check(!DockHoverState.isFresh(age: 0, sameProcess: true, sameDesktop: false, sameRun: true), "Space transition invalidates hover action")
    check(!DockHoverState.isFresh(age: 0, sameProcess: true, sameDesktop: true, sameRun: false), "restart invalidates old hover action")
    check(!DockHoverState.isFresh(age: .nan, sameProcess: true, sameDesktop: true, sameRun: true), "invalid hover time rejected")
    check(DockHoverState.suppressReopen(ownMinimizePending: true, sinceSuccessfulMinimize: nil), "own minimize ticket suppresses native reopen")
    check(DockHoverState.suppressReopen(ownMinimizePending: false, sinceSuccessfulMinimize: 0.5), "short successful minimize tail suppresses native reopen")
    check(!DockHoverState.suppressReopen(ownMinimizePending: false, sinceSuccessfulMinimize: 0.501), "later explicit reopen remains available")
    check(!DockHoverState.suppressReopen(ownMinimizePending: false, sinceSuccessfulMinimize: nil), "normal reopen remains available")
    let display = CGRect(x: -1200, y: 0, width: 1200, height: 800)
    check(DockHoverState.nearDockEdge(CGPoint(x: -600, y: 790), displays: [display]), "bottom Dock edge supports negative-coordinate displays")
    check(DockHoverState.nearDockEdge(CGPoint(x: -1190, y: 400), displays: [display]), "left Dock edge supported")
    check(DockHoverState.nearDockEdge(CGPoint(x: -10, y: 400), displays: [display]), "right Dock edge supported")
    check(!DockHoverState.nearDockEdge(CGPoint(x: -600, y: 10), displays: [display]), "top-center is not polled as Dock")
    check(!DockHoverState.nearDockEdge(CGPoint(x: -600, y: 400), displays: [display]), "screen center never triggers hover AX polling")
    check(!DockHoverState.nearDockEdge(CGPoint(x: 100, y: 400), displays: [display]), "offscreen point never triggers hover AX polling")
    // Regression: physical trackpad taps can deliver down/up with identical
    // timestamps, before the asynchronous AX hit test has returned.
    check(DockClickPolicy.accepts(duration: 0, travel: 0, modified: false, dragged: false, clickCount: 1), "zero-duration trackpad tap is a click")
    var earlyRelease = DockClickReadiness()
    earlyRelease.released = true
    check(earlyRelease.decision == .wait, "release before AX keeps click pending")
    earlyRelease.prepared = true
    check(earlyRelease.decision == .execute, "late AX completion executes released click")
    var earlyPreparation = DockClickReadiness()
    earlyPreparation.prepared = true
    check(earlyPreparation.decision == .wait, "AX before release cannot minimize early")
    earlyPreparation.released = true
    check(earlyPreparation.decision == .execute, "release completes prepared click")
    for released in [false, true] {
        var rejected = DockClickReadiness()
        rejected.released = released
        rejected.prepared = false
        check(rejected.decision == .returnToSystem, "rejected target returns both incomplete and complete click")
        for prepared in [nil, true, false] as [Bool?] {
            var cancelled = DockClickReadiness()
            cancelled.released = released
            cancelled.prepared = prepared
            cancelled.cancelled = true
            check(cancelled.decision == .returnToSystem, "deadline or drag wins over late AX completion")
        }
    }
    // A completed physical click can race a closed window or a failed AX write.
    // Once that happens the native Dock action must still be delivered exactly
    // as it would have been without Real; partial successful changes are owned.
    check(DockClickPolicy.shouldReturnFailedAction(changedWindows: 0, cancelled: false,
        sameDesktop: true, sameRun: true, restoring: false, mutationAttempted: false), "zero-effect intercepted action returns native click")
    check(!DockClickPolicy.shouldReturnFailedAction(changedWindows: 1, cancelled: false,
        sameDesktop: true, sameRun: true, restoring: false, mutationAttempted: true), "partial minimize never replays and undoes successful members")
    check(!DockClickPolicy.shouldReturnFailedAction(changedWindows: 0, cancelled: true,
        sameDesktop: true, sameRun: true, restoring: false, mutationAttempted: false), "a newer physical interaction prevents stale native replay")
    check(!DockClickPolicy.shouldReturnFailedAction(changedWindows: 0, cancelled: false,
        sameDesktop: false, sameRun: true, restoring: false, mutationAttempted: false), "failed old-desktop click cannot act on new desktop")
    check(!DockClickPolicy.shouldReturnFailedAction(changedWindows: 0, cancelled: false,
        sameDesktop: true, sameRun: false, restoring: false, mutationAttempted: false), "stopped event tap cannot replay a stale action")

    for attempted in [false, true] {
        check(!DockClickPolicy.shouldReturnFailedAction(changedWindows: 0, cancelled: false,
            sameDesktop: true, sameRun: true, restoring: true, mutationAttempted: attempted),
            "failed or unobserved restore never invokes native reopen of unrelated C")
    }
    check(!DockClickPolicy.shouldReturnFailedAction(changedWindows: 0, cancelled: false,
        sameDesktop: true, sameRun: true, restoring: false, mutationAttempted: true),
        "an attempted minimize with unknown delivery never gets a second native action")
    let requestPermit = DockWorkPermit()
    check(!requestPermit.hasAttemptedMutation, "new mutation has not sent remote writes")
    requestPermit.markMutationAttempted()
    requestPermit.cancel()
    check(requestPermit.hasAttemptedMutation && requestPermit.isCancelled,
        "cancelling a sent write cannot erase its possible future side effect")

    // Reproduce AppKit's asynchronous deminiaturize publication across multiple
    // windows. The initial read must not falsely finish at zero or drop B.
    let restoreRequested = DockRestoreProgress(minimizedStates: [true, true])
    check(restoreRequested.restored == 0 && restoreRequested.pending == 2 &&
        restoreRequested.shouldWait(elapsed: 0, cancelled: false), "own restore waits through initial animation")
    let firstRestored = DockRestoreProgress(minimizedStates: [false, true])
    check(firstRestored.restored == 1 && firstRestored.pending == 1 &&
        firstRestored.shouldWait(elapsed: 0.2, cancelled: false), "own restore retains second animating member")
    let allRestored = DockRestoreProgress(minimizedStates: [false, false])
    check(allRestored.restored == 2 && allRestored.pending == 0 &&
        !allRestored.shouldWait(elapsed: 0.3, cancelled: false), "own restore finishes after both members publish")
    let windowClosed = DockRestoreProgress(minimizedStates: [nil, true])
    check(windowClosed.restored == 0 && windowClosed.pending == 1,
        "closing a requested window is not a successful restore")
    check(!firstRestored.shouldWait(elapsed: 1.0, cancelled: false), "unresponsive own restore has bounded settlement")
    check(!firstRestored.shouldWait(elapsed: 0.2, cancelled: true), "new user input ends restore polling")
    check(!firstRestored.shouldWait(elapsed: .nan, cancelled: false), "invalid restore clock cannot poll forever")
    // Exercise actual retry control flow with an injected monotonic clock.
    // A false minimized state is a successful read, not a missing value.
    var readClock = 0.0, readAttempts = 0
    var retryTimeouts: [Float] = []
    let delayedRead: Bool? = DockAXReadRetry.read(deadline: 1, isCancelled: { false },
        now: { readClock }, pause: { readClock += $0 }) { timeout, attempt in
        readAttempts += 1
        retryTimeouts.append(timeout)
        readClock += attempt == 1 ? 0.08 : 0.01
        return attempt == 1 ? (.cannotComplete, nil) : (.success, false)
    }
    check(delayedRead == false && readAttempts == 2 && retryTimeouts == [0.08, 0.20],
        "transient AX read timeout retries once with longer bounded timeout")
    for failure in [AXError.apiDisabled, .invalidUIElement, .attributeUnsupported, .failure] {
        var attempts = 0
        let result: Bool? = DockAXReadRetry.read(deadline: 1, isCancelled: { false },
            now: { 0 }, pause: { _ in }) { _, _ in
            attempts += 1
            return (failure, nil)
        }
        check(result == nil && attempts == 1, "non-timeout AX read error never loops: \(failure.rawValue)")
    }
    readClock = 0; readAttempts = 0
    let persistentTimeout: Bool? = DockAXReadRetry.read(deadline: 1, isCancelled: { false },
        now: { readClock }, pause: { readClock += $0 }) { timeout, _ in
        readAttempts += 1
        readClock += Double(timeout)
        return (.cannotComplete, nil)
    }
    check(persistentTimeout == nil && readAttempts == 2 && readClock < 0.31,
        "persistent AX timeout terminates after two reads without repeating a write")
    readClock = 0; readAttempts = 0
    let shortBudget: Bool? = DockAXReadRetry.read(deadline: 0.1, isCancelled: { false },
        now: { readClock }, pause: { readClock += $0 }) { timeout, _ in
        readAttempts += 1
        readClock += Double(timeout)
        return (.cannotComplete, nil)
    }
    check(shortBudget == nil && readAttempts == 1 && readClock <= 0.1,
        "shared operation deadline prevents a new retry after exhausted read budget")
    var cancelledRead = false
    readAttempts = 0
    let cancelledResult: Bool? = DockAXReadRetry.read(deadline: 1, isCancelled: { cancelledRead },
        now: { 0 }, pause: { _ in }) { _, _ in
        readAttempts += 1
        cancelledRead = true
        return (.cannotComplete, nil)
    }
    check(cancelledResult == nil && readAttempts == 1, "user cancellation prevents a timeout retry")
    readAttempts = 0
    let malformedResult: Bool? = DockAXReadRetry.read(deadline: 1, isCancelled: { false },
        now: { 0 }, pause: { _ in }) { _, _ in
        readAttempts += 1
        return (.success, nil)
    }
    check(malformedResult == nil && readAttempts == 1, "successful AX reply with wrong value type never loops")
    return failures
}

#if DOCK_POLICY_STANDALONE
@main
struct DockPolicyStandaloneRunner {
    static func main() {
        var failures = runDockPolicyTests()
#if SYSTEM_KEY_POLICY_TESTS
        failures += runSystemKeyPolicyTests()
#endif
        if failures.isEmpty { print("PASS: Dock policy and any enabled key policy checks") }
        else { failures.forEach { print("FAIL: \($0)") }; exit(1) }
    }
}
#endif

#if SYSTEM_KEY_POLICY_TESTS
func runSystemKeyPolicyTests() -> [String] {
    var failures: [String] = []
    func check(_ condition: Bool, _ name: String) { if !condition { failures.append(name) } }
    var state = SystemKeyPressState()
    check(!state.release(0), "unmatched key-up passes through")
    check(!state.begin(0, repeated: true), "orphan key repeat passes through")
    check(state.begin(0, repeated: false), "fresh press can be considered")
    check(!state.begin(0, repeated: true), "unhandled press repeats stay native")
    check(!state.release(0), "unhandled press release stays native")
    check(state.begin(0, repeated: false), "new press after native release")
    state.record(0, handled: true)
    check(state.begin(0, repeated: true), "handled press can repeat")
    check(!state.release(1), "different key release is not consumed")
    check(state.release(0), "handled press consumes its own release")
    check(!state.release(0), "duplicate release is not consumed")
    _ = state.begin(7, repeated: false)
    state.record(7, handled: true)
    state.record(7, handled: false)
    check(!state.release(7), "failed or disabled repeat returns release to native owner")
    _ = state.begin(2, repeated: false)
    state.record(2, handled: true)
    state.reset()
    check(!state.release(2), "timeout or stop clears ownership")
    return failures
}
#endif
