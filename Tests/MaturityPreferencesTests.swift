import AppKit
import Foundation

@MainActor func runMaturityPreferencesTests() -> [String] {
    var failures: [String] = []
    func check(_ value: Bool, _ label: String) { if !value { failures.append("Maturity preferences: " + label) } }
    let suite = "local.dan.real.tests.maturity." + UUID().uuidString
    guard let defaults = UserDefaults(suiteName: suite) else { return ["Maturity preferences: isolated defaults unavailable"] }
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(["dockIcon": false, "menuIcon": false, "music": true, "calendar": true,
                  "shelf": true, "mirror": true, "battery": true], forKey: "flags")
    defaults.set("com.example.Old,\ncom.example.Other", forKey: "excludedApps")
    let p = Preferences(defaults: defaults)
    check(p.lyricsTextSize == "standard" && p.lyricsBackgroundOpacity == 0.65 && !p.enabled("lyricsBold"), "new controls retain compact default appearance")
    check(p.lyricsColorRGB == Preferences.defaultLyricsColorRGB, "default remains pink")
    check(!p.enabled("dockIcon") && !p.enabled("menuIcon") && p.enabled("calendar") && p.enabled("shelf") && p.enabled("mirror"), "existing visibility and module choices survive")
    check(p.flags["battery"] == nil && !p.enabled("trackPeek"), "retired features stay retired")
    check(p.excludedApps == "com.example.Old,\ncom.example.Other", "existing exclusion text is not silently rewritten")
    let a = LyricDisplayPolicy.trackKey(sourceBundleIdentifier: "qq", title: "Song", artist: "A")
    let b = LyricDisplayPolicy.trackKey(sourceBundleIdentifier: "netease", title: "Song", artist: "A")
    p.lyricsTextSize = "large"; p.lyricsBackgroundOpacity = 0.2; p.set("lyricsBold", true)
    p.setLyricOffset(0.2, for: a); p.setLyricOffset(-0.4, for: b)
    let restored = Preferences(defaults: defaults)
    check(restored.lyricsTextSize == "large" && restored.lyricsBackgroundOpacity == 0.2 && restored.enabled("lyricsBold"), "appearance survives reload")
    check(restored.lyricOffset(for: a) == 0.2 && restored.lyricOffset(for: b) == -0.4, "per-source timing survives reload independently")
    restored.setLyricOffset(0, for: a)
    check(restored.lyricOffsets[a] == nil && restored.lyricOffset(for: b) == -0.4, "reset removes only current song")
    restored.setLyricOffset(1, for: ""); restored.setLyricOffset(1, for: String(repeating: "x", count: 2049))
    check(restored.lyricOffsets.count == 1, "empty and oversized song keys cannot be saved")
    restored.lyricsTextSize = "unsupported"; restored.lyricsBackgroundOpacity = .nan
    check(restored.lyricsTextSize == "standard" && restored.lyricsBackgroundOpacity == 0.65, "invalid runtime appearance is normalized")
    defaults.set("unsupported", forKey: "lyricsTextSize")
    defaults.set(3.0, forKey: "lyricsBackgroundOpacity")
    defaults.set([a: 9.0, b: -0.39, "": 2.0, "bool": true, "text": "1.0", "zero": 0] as [String: Any], forKey: "lyricOffsetsV1")
    let malformed = Preferences(defaults: defaults)
    check(malformed.lyricsTextSize == "standard" && malformed.lyricsBackgroundOpacity == 0.9, "invalid stored appearance is bounded")
    check(malformed.lyricOffsets.count == 2 && malformed.lyricOffset(for: a) == 5 && malformed.lyricOffset(for: b) == -0.4, "malformed offset entries are ignored and valid entries quantized")
    check(RealLaunchPolicy.isDesignPreview(bundleIdentifier: "local.dan.real.preview.maturity")
          && !RealLaunchPolicy.isDesignPreview(bundleIdentifier: "local.dan.real"), "UI fixture identity cannot start daily backend")
    let copy = ["等待": ["en": "Waiting", "ja": "待機中", "ru": "Ожидание"]]
    check(StatusCopy.text("待機中", language: "ru", translations: copy) == "Ожидание",
          "stored localized service status follows a later language change")
    check(StatusCopy.text("Waiting", language: "zh-Hans", translations: copy) == "等待",
          "stored service status can return to Chinese")
    check(StatusCopy.text("OS error: private file", language: "ja", translations: copy) == "OS error: private file",
          "unrecognized system details remain unchanged")
    return failures
}
