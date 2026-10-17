import AppKit
import CoreGraphics

struct DisplayIdentity: Equatable {
    let id: String
    /// False for displays without a unique public serial number. Such a fallback
    /// distinguishes connected screens but cannot promise stability on reconnect.
    let isPersistent: Bool
}

struct DisplayChoice {
    let id: String
    let name: String
    let frame: CGRect
}

enum DisplayFullscreenState: Equatable {
    /// Full-display geometry differs clearly from the ordinary work area.
    /// This includes borderless full-display apps; it is not a private Space flag.
    case fullscreen
    case windowed
    /// Missing metadata or maximized/full-screen geometry is indistinguishable.
    case unknown
}

enum DisplayPolicy {
    @MainActor
    static func identity(for screen: NSScreen) -> DisplayIdentity {
        guard let number = displayNumber(for: screen) else {
            return DisplayIdentity(id: "runtime:\(ObjectIdentifier(screen))", isPersistent: false)
        }
        let vendor = CGDisplayVendorNumber(number)
        let model = CGDisplayModelNumber(number)
        let serial = CGDisplaySerialNumber(number)
        let builtIn = CGDisplayIsBuiltin(number) != 0
        let duplicates = NSScreen.screens.compactMap(displayNumber).filter {
            CGDisplayVendorNumber($0) == vendor && CGDisplayModelNumber($0) == model
                && CGDisplaySerialNumber($0) == serial && (CGDisplayIsBuiltin($0) != 0) == builtIn
        }.count
        if duplicates == 1 && builtIn {
            return DisplayIdentity(id: "builtin:\(vendor):\(model)", isPersistent: true)
        }
        if duplicates == 1 && serial != 0 {
            return DisplayIdentity(id: "display:\(vendor):\(model):\(serial)", isPersistent: true)
        }
        return DisplayIdentity(id: "session:\(number):\(vendor):\(model)", isPersistent: false)
    }

    @MainActor
    static func identifier(for screen: NSScreen) -> String { identity(for: screen).id }

    /// Automatic selection follows the pointer and takes precedence over the
    /// explicit preference. Call again from a pointer/screen-change observer.
    @MainActor
    static func selectedScreens(allDisplays: Bool, selectedID: String, automatic: Bool) -> [NSScreen] {
        let screens = NSScreen.screens
        if allDisplays { return screens }
        let choices = screens.map { DisplayChoice(id: identifier(for: $0), name: $0.localizedName, frame: $0.frame) }
        guard let selected = selectID(choices: choices, selectedID: selectedID, automatic: automatic,
                                      pointer: NSEvent.mouseLocation),
              let index = choices.firstIndex(where: { $0.id == selected }) else { return [] }
        return [screens[index]]
    }

    /// The first choice is the primary/menu-bar display, as in NSScreen.screens.
    /// Legacy name preferences are accepted only when the name is unambiguous.
    static func selectID(choices: [DisplayChoice], selectedID: String, automatic: Bool, pointer: CGPoint) -> String? {
        if automatic, let pointed = choices.first(where: { $0.frame.contains(pointer) }) { return pointed.id }
        if let exact = choices.first(where: { $0.id == selectedID }) { return exact.id }
        let legacy = choices.filter { $0.name == selectedID }
        if legacy.count == 1 { return legacy[0].id }
        return choices.first?.id
    }

    @MainActor
    static func fullscreenState(on screen: NSScreen) -> DisplayFullscreenState {
        guard let number = displayNumber(for: screen),
              let app = NSWorkspace.shared.frontmostApplication,
              app.activationPolicy == .regular,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return .unknown }
        let displayBounds = CGDisplayBounds(number)
        let workArea = convertWorkArea(frame: screen.frame, visibleFrame: screen.visibleFrame, displayBounds: displayBounds)
        var candidates: [CGRect] = []
        var metadataComplete = true
        // Quartz lists windows front to back. Use only the first ordinary visible
        // window for this app on this display; a covered full-size window behind
        // a normal foreground window is insufficient evidence for hiding.
        for info in windows {
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true else { continue }
            guard let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
                  let dictionary = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else {
                metadataComplete = false
                continue
            }
            guard alpha > 0.95, bounds.intersects(displayBounds), bounds.width > 1, bounds.height > 1 else { continue }
            candidates.append(bounds)
            break
        }
        return classifyFullscreen(windowBounds: candidates.first, displayBounds: displayBounds,
                                  workAreaBounds: workArea, metadataComplete: metadataComplete)
    }

    @MainActor
    static func shouldHideForFullscreen(on screen: NSScreen) -> Bool {
        fullscreenState(on: screen) == .fullscreen
    }

    static func classifyFullscreen(windowBounds: CGRect?, displayBounds: CGRect,
                                   workAreaBounds: CGRect, metadataComplete: Bool = true) -> DisplayFullscreenState {
        guard metadataComplete, let window = windowBounds,
              valid(window), valid(displayBounds), valid(workAreaBounds) else { return .unknown }
        guard approximatelyEqual(window, displayBounds) else { return .windowed }
        // Auto-hidden menu/Dock can make a maximized window fill the same bounds.
        // Without a distinct reserved area, fail open instead of guessing.
        guard !approximatelyEqual(workAreaBounds, displayBounds, tolerance: 4),
              !approximatelyEqual(window, workAreaBounds) else { return .unknown }
        return .fullscreen
    }

    static func convertWorkArea(frame: CGRect, visibleFrame: CGRect, displayBounds: CGRect) -> CGRect {
        guard valid(frame), valid(visibleFrame), valid(displayBounds) else { return .null }
        let scaleX = displayBounds.width / frame.width
        let scaleY = displayBounds.height / frame.height
        return CGRect(x: displayBounds.minX + (visibleFrame.minX - frame.minX) * scaleX,
                      y: displayBounds.minY + (frame.maxY - visibleFrame.maxY) * scaleY,
                      width: visibleFrame.width * scaleX, height: visibleFrame.height * scaleY)
    }

    @MainActor
    private static func displayNumber(for screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && rect.minX.isFinite && rect.minY.isFinite
            && rect.width.isFinite && rect.height.isFinite && rect.width > 0 && rect.height > 0
    }

    private static func approximatelyEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 1) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.maxX - b.maxX) <= tolerance && abs(a.maxY - b.maxY) <= tolerance
    }
}
