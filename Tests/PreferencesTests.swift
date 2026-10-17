import Foundation
import SwiftUI

/// Uses a disposable suite; never instantiates Preferences.shared or writes the
/// application's settings domain. Returns descriptions of failed assertions.
@MainActor
func runPreferencesTests() -> [String] {
    let suite = "local.dan.real.tests.preferences.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else {
        return ["Preferences: could not create isolated settings suite"]
    }
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }

    var failures: [String] = []
    func check(_ condition: Bool, _ description: String) {
        if !condition { failures.append("Preferences: " + description) }
    }

    let initial = Preferences(defaults: defaults)
    check(initial.language == "system", "fresh language follows system")
    check(initial.selectedDisplay.isEmpty, "fresh display uses main display")
    check(initial.excludedApps.isEmpty, "fresh app exclusions are empty")
    check(abs(initial.hoverDelay - 0.3) < 0.0001, "fresh hover delay is 0.3 seconds")
    check(initial.islandHeight == 0, "fresh island height is automatic")
    check(initial.mediaSource == "auto", "fresh media source is automatic")
    check(initial.controllerSlots == ["previous", "play", "next", "mute", "volume"], "fresh control slots preserve their default order")
    check(initial.enabled("dockEnabled"), "Dock behavior is enabled by default")
    check(initial.enabled("music"), "music is enabled by default")
    check(initial.enabled("dockIcon") && !initial.enabled("menuIcon"), "fresh presence defaults are respected")
    check(!initial.enabled("mirror"), "camera module starts disabled")
    check(!initial.enabled("completed"), "completed reminders start hidden")
    check(!initial.enabled("shelfRemove"), "automatic shelf removal starts disabled")
    check(!initial.enabled("unknownFeature"), "unknown feature lookup defaults to disabled")

    check(initial.lyricsColorRGB == 0xFFA6BF, "lyrics default to the original pink")
    initial.setLyricsColor(Color(.sRGB, red: 0, green: 0.5, blue: 1, opacity: 1))
    check(Preferences(defaults: defaults).lyricsColorRGB == 0x0080FF, "custom lyric color survives relaunch")
    initial.resetLyricsColor()
    check(Preferences(defaults: defaults).lyricsColorRGB == 0xFFA6BF, "pink reset persists")
    defaults.set(-1, forKey: "lyricsColorRGB")
    check(Preferences(defaults: defaults).lyricsColorRGB == 0xFFA6BF, "invalid stored color safely falls back to pink")
    defaults.removeObject(forKey: "lyricsColorRGB")

    initial.set("music", false)
    initial.set("mirror", true)
    initial.binding("dockIcon").wrappedValue = false
    initial.language = "ja"
    initial.selectedDisplay = "Test Display 42"
    initial.excludedApps = "example.first, example.second"
    initial.hoverDelay = 0.85
    initial.islandHeight = 42
    initial.mediaSource = "ytm"
    initial.youtubeURL = "http://localhost:9876/api/v1"
    initial.controllerSlots = ["volume", "previous", "play", "next", "mute"]
    let restored = Preferences(defaults: defaults)
    check(!restored.enabled("music") && restored.enabled("mirror"), "changed flags survive a new preferences instance")
    check(!restored.enabled("dockIcon"), "binding writes persist")
    check(restored.language == "ja" && restored.effectiveLanguage == "ja", "language persists and resolves")
    check(restored.selectedDisplay == "Test Display 42", "selected display persists")
    check(restored.excludedApps == "example.first, example.second", "excluded application identifiers persist exactly")
    check(abs(restored.hoverDelay - 0.85) < 0.0001, "hover delay persists")
    check(restored.islandHeight == 42, "island height persists")
    check(restored.mediaSource == "ytm", "media source persists")
    check(restored.youtubeURL == "http://localhost:9876/api/v1", "companion server address persists")
    check(restored.controllerSlots == ["volume", "previous", "play", "next", "mute"], "control slot order persists")

    // Simulate an older version's partial flags dictionary plus a future flag.
    // Loading must fill missing defaults without discarding explicit choices.
    defaults.set(["music": false, "dockEnabled": false, "futureFeature": true], forKey: "flags")
    defaults.set("leave this alone", forKey: "unrelatedFutureSetting")
    let migrated = Preferences(defaults: defaults)
    check(!migrated.enabled("music") && !migrated.enabled("dockEnabled"), "partial saved flags retain known false values")
    check(migrated.enabled("lyrics") && migrated.enabled("allDisplays"), "missing flags receive current defaults")
    check(migrated.enabled("futureFeature"), "unknown saved flags survive loading")
    migrated.set("anotherFutureFeature", true)
    let reloaded = Preferences(defaults: defaults)
    check(!reloaded.enabled("music") && !reloaded.enabled("dockEnabled"), "adding unknown flags does not reset known flags")
    check(reloaded.enabled("futureFeature") && reloaded.enabled("anotherFutureFeature"), "both future flags survive saving")
    check(defaults.string(forKey: "unrelatedFutureSetting") == "leave this alone", "saving flags preserves unrelated keys")
    check(reloaded.excludedApps == "example.first, example.second" && reloaded.language == "ja", "flag migration preserves scalar settings")

    for (input, expected) in [("zh-Hans", "zh-Hans"), ("zh-Hant-TW", "zh-Hans"),
                              ("en-GB", "en"), ("ja-JP", "ja"), ("ru-RU", "ru"), ("fr-FR", "en")] {
        reloaded.language = input
        check(reloaded.effectiveLanguage == expected, "language mapping \(input) → \(expected)")
    }
    reloaded.language = "system"
    check(["zh-Hans", "en", "ja", "ru"].contains(reloaded.effectiveLanguage), "system language resolves to a supported language")
    reloaded.set("dockIcon", false)
    reloaded.set("menuIcon", true)
    let presence = Preferences(defaults: defaults)
    check(!presence.enabled("dockIcon") && presence.enabled("menuIcon"), "independent Dock/menu visibility choices survive relaunch")

    check(RealLaunchPolicy.conflicts(candidatePID: 2, currentPID: 1, bundleIdentifier: "theboringteam.boringnotch"), "renamed legacy app is identified by bundle ID")
    check(RealLaunchPolicy.conflicts(candidatePID: 2, currentPID: 1, bundleIdentifier: "local.dan.real"), "another preview/final app is detected")
    check(!RealLaunchPolicy.conflicts(candidatePID: 1, currentPID: 1, bundleIdentifier: "local.dan.real"), "current process does not conflict with itself")
    check(!RealLaunchPolicy.conflicts(candidatePID: 2, currentPID: 1, bundleIdentifier: "example.unrelated.real"), "unrelated app with Real-like name does not block startup")
    check(!RealLaunchPolicy.conflicts(candidatePID: 2, currentPID: 1, bundleIdentifier: nil), "unknown bundle is not guessed from filename")
    check(RealLaunchPolicy.shouldShowSettings(isLoginEvent: false, arguments: ["real"]), "explicit launch opens settings")
    check(!RealLaunchPolicy.shouldShowSettings(isLoginEvent: true, arguments: ["real"]), "login event starts silently")
    check(!RealLaunchPolicy.shouldShowSettings(isLoginEvent: false, arguments: ["real", "--background"]), "background launch does not activate existing app or show settings")
    check(!RealLaunchPolicy.shouldShowSettings(isLoginEvent: true, arguments: ["real", "--preview"]), "login launch stays quiet even in preview")

    let statusTable = ["频谱未启用": ["en": "Spectrum disabled", "ja": "スペクトラムは無効です"],
                       "系统音频捕获失败：": ["en": "System audio capture failed: "]]
    check(StatusCopy.text("频谱未启用", language: "en", translations: statusTable) == "Spectrum disabled", "spectrum status key translates")
    check(StatusCopy.text("频谱未启用", language: "ja", translations: statusTable) == "スペクトラムは無効です", "status can switch languages without service restart")
    check(StatusCopy.text("频谱未启用", language: "zh-Hans", translations: statusTable) == "频谱未启用", "Chinese status stays unchanged")
    check(StatusCopy.text("频谱未启用", language: "ru", translations: statusTable) == "Spectrum disabled", "missing status locale falls back to English")
    check(StatusCopy.text("系统音频捕获失败：OS error 42", language: "en", translations: statusTable) == "System audio capture failed: OS error 42", "dynamic error detail is preserved while prefix translates")
    check(StatusCopy.text("OS permission denied", language: "ja", translations: statusTable) == "OS permission denied", "unknown OS errors are not rewritten")
    check(StatusCopy.text("", language: "en", translations: statusTable).isEmpty, "empty status stays empty")
    return failures
}

#if PREFERENCES_STANDALONE
@main
struct PreferencesStandaloneRunner {
    @MainActor static func main() {
        let failures = runPreferencesTests()
        if failures.isEmpty { print("PASS: isolated preferences defaults, persistence, migration, and language checks") }
        else { failures.forEach { print("FAIL: " + $0) }; exit(1) }
    }
}
#endif
