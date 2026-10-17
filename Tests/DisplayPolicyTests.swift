import AppKit

func runDisplayPolicyTests() -> [String] {
    var failures: [String] = []
    func check(_ condition: Bool, _ label: String) { if !condition { failures.append("Display policy: " + label) } }
    let primary = DisplayChoice(id: "primary-1", name: "Studio Display", frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
    let secondary = DisplayChoice(id: "serial-2", name: "Studio Display", frame: CGRect(x: -1000, y: 0, width: 1000, height: 800))
    let unique = DisplayChoice(id: "serial-3", name: "Projector", frame: CGRect(x: 0, y: 800, width: 1200, height: 900))
    let choices = [primary, secondary, unique]
    check(DisplayPolicy.selectID(choices: choices, selectedID: "serial-2", automatic: false, pointer: .zero) == "serial-2", "stable ID distinguishes identical names")
    check(DisplayPolicy.selectID(choices: choices, selectedID: "Studio Display", automatic: false, pointer: .zero) == "primary-1", "ambiguous legacy name falls back to primary")
    check(DisplayPolicy.selectID(choices: choices, selectedID: "Projector", automatic: false, pointer: .zero) == "serial-3", "unique legacy name remains compatible")
    check(DisplayPolicy.selectID(choices: choices, selectedID: "missing", automatic: false, pointer: .zero) == "primary-1", "disconnected selection falls back")
    check(DisplayPolicy.selectID(choices: choices, selectedID: "serial-3", automatic: true, pointer: CGPoint(x: -200, y: 100)) == "serial-2", "automatic selection follows pointer across negative screen coordinates")
    check(DisplayPolicy.selectID(choices: choices, selectedID: "serial-3", automatic: true, pointer: CGPoint(x: 3000, y: 3000)) == "serial-3", "out-of-bounds pointer retains explicit choice")
    check(DisplayPolicy.selectID(choices: [], selectedID: "", automatic: true, pointer: .zero) == nil, "headless selection is empty")

    let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let workArea = CGRect(x: 0, y: 25, width: 1440, height: 820)
    check(DisplayPolicy.classifyFullscreen(windowBounds: display, displayBounds: display, workAreaBounds: workArea) == .fullscreen, "full display differs from reserved desktop area")
    check(DisplayPolicy.classifyFullscreen(windowBounds: workArea, displayBounds: display, workAreaBounds: workArea) == .windowed, "ordinary maximization remains windowed")
    check(DisplayPolicy.classifyFullscreen(windowBounds: display, displayBounds: display, workAreaBounds: display) == .unknown, "autohidden chrome creates uncertainty rather than false fullscreen")
    check(DisplayPolicy.classifyFullscreen(windowBounds: display.insetBy(dx: -100, dy: -100), displayBounds: display, workAreaBounds: workArea) == .windowed, "oversized spanning window is not fullscreen")
    check(DisplayPolicy.classifyFullscreen(windowBounds: nil, displayBounds: display, workAreaBounds: workArea) == .unknown, "missing foreground window is unknown")
    check(DisplayPolicy.classifyFullscreen(windowBounds: display, displayBounds: display, workAreaBounds: workArea, metadataComplete: false) == .unknown, "incomplete window metadata fails open")
    check(DisplayPolicy.classifyFullscreen(windowBounds: display, displayBounds: display, workAreaBounds: .null) == .unknown, "invalid geometry fails open")
    let appKitFrame = CGRect(x: -1440, y: 100, width: 1440, height: 900)
    let visible = CGRect(x: -1440, y: 155, width: 1440, height: 820)
    let quartz = CGRect(x: -1440, y: -100, width: 1440, height: 900)
    check(DisplayPolicy.convertWorkArea(frame: appKitFrame, visibleFrame: visible, displayBounds: quartz)
            == CGRect(x: -1440, y: -75, width: 1440, height: 820), "AppKit bottom-origin work area maps to Quartz top-origin coordinates")
    return failures
}

#if DISPLAY_POLICY_STANDALONE
@main
struct DisplayPolicyRunner {
    static func main() {
        let failures = runDisplayPolicyTests()
        if failures.isEmpty { print("PASS: display selection and conservative fullscreen policies") }
        else { failures.forEach { print("FAIL: " + $0) }; exit(1) }
    }
}
#endif
