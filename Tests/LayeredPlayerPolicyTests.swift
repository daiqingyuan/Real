import Foundation
import CoreGraphics

func runLayeredPlayerPolicyTests() -> [String] {
    var failures: [String] = []
    func check(_ condition: Bool, _ name: String) { if !condition { failures.append(name) } }
    let frame = CGRect(x: 116, y: 33, width: 1280, height: 868)
    let tooltipFrame = CGRect(x: 122, y: 39, width: 66, height: 20)
    func window(number: CGWindowID? = 4949, subrole: String = "AXStandardWindow",
                identifier: String = "QQMianWindow", bounds: CGRect? = nil,
                minimized: Bool? = false, minimizable: Bool? = true,
                fullScreen: Bool? = false, modal: Bool? = false,
                hasSheet: Bool = false) -> LayeredPlayerWindow {
        LayeredPlayerWindow(number: number, subrole: subrole, identifier: identifier,
            frame: bounds ?? frame, minimized: minimized, minimizable: minimizable,
            fullScreen: fullScreen, modal: modal, hasSheet: hasSheet)
    }
    func lyric(number: CGWindowID? = 12468, bounds: CGRect? = nil,
               minimized: Bool? = false, minimizable: Bool? = false,
               fullScreen: Bool? = false, modal: Bool? = false,
               hasSheet: Bool = false) -> LayeredPlayerWindow {
        window(number: number, subrole: "AXUnknown", identifier: "", bounds: bounds,
            minimized: minimized, minimizable: minimizable, fullScreen: fullScreen,
            modal: modal, hasSheet: hasSheet)
    }
    func tooltip(number: CGWindowID? = 12657, identifier: String = "_NS:8",
                 bounds: CGRect? = nil, minimized: Bool? = false,
                 minimizable: Bool? = false, fullScreen: Bool? = false,
                 modal: Bool? = false, hasSheet: Bool = false) -> LayeredPlayerWindow {
        window(number: number, subrole: "AXDialog", identifier: identifier,
            bounds: bounds ?? tooltipFrame, minimized: minimized, minimizable: minimizable,
            fullScreen: fullScreen, modal: modal, hasSheet: hasSheet)
    }
    let main = window(), overlay = lyric(), tip = tooltip()
    let pair = [main, overlay]
    let visible: [(CGWindowID, CGRect)] = [(4949, frame), (12468, frame)]
    func allowed(_ windows: [LayeredPlayerWindow], _ onScreen: [(CGWindowID, CGRect)]? = nil,
                 bundleID: String? = "com.tencent.QQMusicMac", mainNumber: CGWindowID = 4949) -> Bool {
        LayeredPlayerPolicy.canHide(bundleID: bundleID, mainNumber: mainNumber,
            windows: windows, onScreen: onScreen ?? visible)
    }

    check(allowed(pair), "QQ's observed main and lyric surfaces may hide together")
    check(allowed(Array(pair.reversed()), Array(visible.reversed())), "AX and Quartz ordering do not define cohort identity")
    check(allowed(pair + [tip], visible + [(12657, tooltipFrame)]), "observed tiny native tooltip does not force lyric-page minimization")
    check(allowed(pair + [tip]), "a known harmless tooltip need not be visible")
    for bundle: String? in [nil, "", "com.netease.163music", "com.tencent.QQ", "com.tencent.QQMusicMac "] {
        check(!allowed(pair, bundleID: bundle), "whole-app hide is restricted to the exact verified QQ bundle")
    }
    for selected: CGWindowID in [0, 12468, 9999] {
        check(!allowed(pair, mainNumber: selected), "only the observed ordinary main window can select the hide cohort")
    }
    check(!allowed([]) && !allowed([main]) && !allowed([overlay]), "both ordinary main and lyric overlay are required")
    check(!allowed([window(identifier: "QQMainWindow"), overlay]), "unobserved spelling or page identity cannot enable app hide")

    let unsafeMain: [LayeredPlayerWindow] = [
        window(number: nil), window(number: 0), window(number: 12468),
        window(minimized: true), window(minimized: nil),
        window(minimizable: false), window(minimizable: nil),
        window(fullScreen: true), window(fullScreen: nil),
        window(modal: true), window(modal: nil), window(hasSheet: true),
        window(subrole: "AXDialog"), window(subrole: "AXUnknown")
    ]
    for candidate in unsafeMain {
        check(!allowed([candidate, overlay]), "unknown identity/state or ineligible main window rejects app hide")
    }
    let unsafeOverlay: [LayeredPlayerWindow] = [
        lyric(number: nil), lyric(number: 0), lyric(number: 4949),
        lyric(minimized: true), lyric(minimized: nil),
        lyric(minimizable: true), lyric(minimizable: nil),
        lyric(fullScreen: true), lyric(fullScreen: nil),
        lyric(modal: true), lyric(modal: nil), lyric(hasSheet: true),
        lyric(bounds: frame.offsetBy(dx: 2, dy: 0)),
        lyric(bounds: CGRect(x: frame.minX, y: frame.minY, width: frame.width + 2, height: frame.height))
    ]
    for candidate in unsafeOverlay {
        check(!allowed([main, candidate]), "unknown identity/state or distinct lyric geometry rejects app hide")
    }
    let invalidFrames = [CGRect.zero,
        CGRect(x: 0, y: 0, width: 0, height: 20),
        CGRect(x: CGFloat.nan, y: 0, width: 100, height: 20),
        CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 20)]
    for invalid in invalidFrames {
        check(!allowed([window(bounds: invalid), overlay]), "invalid main geometry cannot qualify")
        check(!allowed([main, lyric(bounds: invalid)]), "invalid lyric geometry cannot qualify")
        check(!allowed(pair + [tooltip(bounds: invalid)]), "invalid tooltip geometry cannot be ignored")
        check(!allowed(pair, [(4949, invalid), (12468, frame)]), "invalid visible geometry cannot qualify")
    }
    for extra in [
        window(number: 9000, identifier: "Other document", bounds: frame.offsetBy(dx: 400, dy: 0)),
        window(number: 9000, identifier: "Other Space", bounds: frame),
        window(number: 9000, identifier: "Manual minimize", minimized: true),
        lyric(number: 9000),
        window(number: 9000, subrole: "AXFloatingWindow", identifier: "Other panel", minimizable: false),
        window(number: 9000, subrole: "AXDialog", identifier: "Preferences", minimizable: false)
    ] {
        check(!allowed(pair + [extra]), "every extra regular, hidden-Space, minimized, dialog, or unknown window prevents whole-app hide")
    }

    let unsafeTooltips: [LayeredPlayerWindow] = [
        tooltip(number: nil), tooltip(number: 0), tooltip(number: 4949), tooltip(number: 12468),
        tooltip(identifier: "NS:8"), tooltip(identifier: ""),
        tooltip(bounds: CGRect(x: 122, y: 39, width: 201, height: 20)),
        tooltip(bounds: CGRect(x: 122, y: 39, width: 66, height: 41)),
        tooltip(minimized: true), tooltip(minimized: nil),
        tooltip(minimizable: true), tooltip(minimizable: nil),
        tooltip(fullScreen: true), tooltip(fullScreen: nil),
        tooltip(modal: true), tooltip(modal: nil), tooltip(hasSheet: true)
    ]
    for candidate in unsafeTooltips {
        check(!allowed(pair + [candidate]), "only a fully known small nonmodal native tooltip may be ignored")
    }
    let maximumTooltip = CGRect(x: 122, y: 39, width: 200, height: 40)
    check(allowed(pair + [tooltip(bounds: maximumTooltip)], visible + [(12657, maximumTooltip)]),
        "tooltip size limits are inclusive")
    check(!allowed(pair + [tip, tip]), "duplicate tooltip IDs remain an ambiguity")
    check(!allowed(pair, []), "hidden surfaces cannot authorize a new hide action")
    check(!allowed(pair, [(4949, frame)]) && !allowed(pair, [(12468, frame)]),
        "off-Space or absent main/lyric surfaces cannot join the cohort")
    check(!allowed(pair, visible + [(4949, frame)]), "duplicate Quartz identities fail closed")
    check(!allowed(pair, visible + [(0, frame)]), "zero Quartz identities fail closed")
    check(!allowed(pair, visible + [(9000, frame)]), "a visible surface absent from the AX list prevents whole-app hide")
    check(!allowed(pair, [(4949, frame.offsetBy(dx: 2, dy: 0)), (12468, frame)]),
        "native IDs still require agreement with current Quartz frames")
    check(!allowed(pair + [tip], visible + [(12657, tooltipFrame.offsetBy(dx: 2, dy: 0))]),
        "visible tooltip identity must also agree with its AX frame")

    let adjacent = frame.offsetBy(dx: 1, dy: 0)
    check(allowed([main, lyric(bounds: adjacent)], [(4949, frame), (12468, adjacent)]),
        "one-point main/lyric frame agreement is inclusive")
    check(allowed(pair, [(4949, adjacent), (12468, adjacent)]),
        "one-point public/native snapshot rounding is accepted")
    check(!allowed([main, lyric(bounds: adjacent)], [(4949, frame.offsetBy(dx: -1, dy: 0)), (12468, adjacent)]),
        "tolerance chaining cannot merge native surfaces separated by more than one point")
    return failures
}

#if LAYERED_PLAYER_POLICY_STANDALONE
@main
struct LayeredPlayerPolicyStandaloneRunner {
    static func main() {
        let failures = runLayeredPlayerPolicyTests()
        if failures.isEmpty { print("PASS: Layered player hide eligibility") }
        else { failures.forEach { print("FAIL: \($0)") }; exit(1) }
    }
}
#endif
