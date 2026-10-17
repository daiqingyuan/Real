import CoreGraphics

/// A complete AX window snapshot for deciding whether app hiding is limited to
/// QQ Music's verified main-window/lyric-surface cohort.
struct LayeredPlayerWindow {
    let number: CGWindowID?
    let subrole: String
    let identifier: String
    let frame: CGRect
    let minimized: Bool?
    let minimizable: Bool?
    let fullScreen: Bool?
    let modal: Bool?
    let hasSheet: Bool
}

enum LayeredPlayerPolicy {
    /// The caller supplies the complete AX window list and this PID's current
    /// on-screen Quartz surfaces. Unknown windows or state retain normal Dock
    /// handling; only this observed QQ layout may use whole-app hiding.
    static func canHide(bundleID: String?, mainNumber: CGWindowID,
                        windows: [LayeredPlayerWindow],
                        onScreen: [(CGWindowID, CGRect)]) -> Bool {
        guard bundleID == "com.tencent.QQMusicMac", mainNumber != kCGNullWindowID else { return false }
        var main: LayeredPlayerWindow?
        var overlay: LayeredPlayerWindow?
        var byNumber: [CGWindowID: LayeredPlayerWindow] = [:]
        for window in windows {
            guard validFrame(window.frame), let number = window.number,
                  number != kCGNullWindowID, byNumber[number] == nil,
                  window.minimized == false, window.fullScreen == false,
                  window.modal == false, !window.hasSheet else { return false }
            byNumber[number] = window
            switch window.subrole {
            case "AXStandardWindow":
                guard main == nil, number == mainNumber,
                      window.identifier == "QQMianWindow", window.minimizable == true else { return false }
                main = window
            case "AXUnknown":
                guard overlay == nil, window.minimizable == false else { return false }
                overlay = window
            case "AXDialog":
                // QQ exposes a native tooltip while hovering its controls.
                // A dialog is ignorable only when every tooltip constraint is
                // known, including its bounded positive geometry and native ID.
                guard window.identifier.hasPrefix("_NS:"),
                      window.frame.width <= 200, window.frame.height <= 40,
                      window.minimizable == false else { return false }
            default:
                return false
            }
        }
        guard let main, let overlay, let overlayNumber = overlay.number,
              overlayNumber != mainNumber, sameGeometry(main.frame, overlay.frame) else { return false }

        var visibleFrames: [CGWindowID: CGRect] = [:]
        for (number, frame) in onScreen {
            guard number != kCGNullWindowID, validFrame(frame),
                  visibleFrames[number] == nil, let window = byNumber[number],
                  sameGeometry(window.frame, frame) else { return false }
            visibleFrames[number] = frame
        }
        guard let mainFrame = visibleFrames[mainNumber],
              let overlayFrame = visibleFrames[overlayNumber] else { return false }
        // Pairwise agreement prevents tolerance chaining from admitting distinct
        // surfaces separated by more than one point across the two API views.
        let cohortFrames = [main.frame, overlay.frame, mainFrame, overlayFrame]
        for first in cohortFrames.indices {
            for second in cohortFrames.indices where second > first {
                guard sameGeometry(cohortFrames[first], cohortFrames[second]) else { return false }
            }
        }
        return true
    }

    private static func validFrame(_ frame: CGRect) -> Bool {
        frame.width > 0 && frame.height > 0
            && [frame.minX, frame.minY, frame.width, frame.height].allSatisfy { $0.isFinite }
    }

    private static func sameGeometry(_ first: CGRect, _ second: CGRect) -> Bool {
        validFrame(first) && validFrame(second)
            && abs(first.minX - second.minX) <= 1 && abs(first.minY - second.minY) <= 1
            && abs(first.width - second.width) <= 1 && abs(first.height - second.height) <= 1
    }
}
