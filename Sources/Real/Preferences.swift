import AppKit
import Foundation
import SwiftUI

extension Notification.Name {
    static let realPreferencesChanged = Notification.Name("local.dan.real.preferencesChanged")
}

/// Launch decisions are independent of app filenames and existing preferences.
enum RealLaunchPolicy {
    static let currentBundleIdentifier = "local.dan.real"
    static let legacyBundleIdentifiers: Set<String> = ["theboringteam.boringnotch"]
    static func isDesignPreview(bundleIdentifier: String?) -> Bool {
        bundleIdentifier?.hasPrefix("local.dan.real.preview.") == true
    }
    static func conflicts(candidatePID: Int32, currentPID: Int32, bundleIdentifier: String?) -> Bool {
        candidatePID != currentPID && bundleIdentifier.map {
            $0 == currentBundleIdentifier || legacyBundleIdentifiers.contains($0)
        } == true
    }
    static func shouldShowSettings(isLoginEvent: Bool, arguments: [String]) -> Bool {
        !isLoginEvent && !arguments.contains("--background")
    }
}

/// Translates raw status keys while preserving OS-provided error detail.
/// The explicit table/language inputs keep this usable in isolated tests.
enum StatusCopy {
    static func text(_ raw: String, language: String, translations: [String: [String: String]]) -> String {
        func translated(_ key: String) -> String {
            language == "zh-Hans" ? key : translations[key]?[language] ?? translations[key]?["en"] ?? key
        }
        if translations[raw] != nil { return translated(raw) }
        // Older services may have stored an already-localized status. Resolve
        // exact catalog messages again when the user changes language, without
        // restarting a service or attempting to translate OS error details.
        if let key = translations.keys.sorted().first(where: { translations[$0]?.values.contains(raw) == true }) {
            return language == "zh-Hans" ? key : translated(key)
        }
        let prefix = "系统音频捕获失败："
        if raw.hasPrefix(prefix) { return translated(prefix) + raw.dropFirst(prefix.count) }
        return raw
    }
}

@MainActor final class Preferences: ObservableObject {
    static let shared = Preferences()
    static let defaultLyricsColorRGB = 0xFFA6BF
    @Published private(set) var lyricsColorRGB: Int {
        didSet { defaults.set(lyricsColorRGB, forKey: "lyricsColorRGB"); notify() }
    }
    var lyricsColor: Color {
        Color(.sRGB, red: Double((lyricsColorRGB >> 16) & 255) / 255,
              green: Double((lyricsColorRGB >> 8) & 255) / 255,
              blue: Double(lyricsColorRGB & 255) / 255, opacity: 1)
    }
    func setLyricsColor(_ color: Color) {
        guard let value = NSColor(color).usingColorSpace(.sRGB) else { return }
        let channels = [value.redComponent, value.greenComponent, value.blueComponent]
        guard channels.allSatisfy({ $0.isFinite }) else { return }
        let rgb = channels.map { Int((min(1, max(0, $0)) * 255).rounded()) }
        lyricsColorRGB = (rgb[0] << 16) | (rgb[1] << 8) | rgb[2]
    }
    func resetLyricsColor() { lyricsColorRGB = Self.defaultLyricsColorRGB }

    private let defaults: UserDefaults
    @Published var language: String { didSet { defaults.set(language, forKey: "language"); notify() } }
    @Published var selectedDisplay: String { didSet { defaults.set(selectedDisplay, forKey: "display"); notify() } }
    @Published var excludedApps: String { didSet { defaults.set(excludedApps, forKey: "excludedApps"); notify() } }
    @Published var musicIdleTimeout: Double { didSet { defaults.set(musicIdleTimeout, forKey: "musicIdleTimeout"); notify() } }
    @Published var hoverDelay: Double { didSet { defaults.set(hoverDelay, forKey: "hoverDelay") } }
    @Published var islandHeight: Double { didSet { defaults.set(islandHeight, forKey: "islandHeight"); notify() } }
    @Published var mediaSource: String { didSet { defaults.set(mediaSource, forKey: "mediaSource"); notify() } }
    @Published var youtubeURL: String { didSet { defaults.set(youtubeURL, forKey: "youtubeURL") } }
    @Published var controllerSlots: [String] { didSet { defaults.set(controllerSlots, forKey: "controllerSlots") } }
    @Published private var storedLyricsTextSize: String
    var lyricsTextSize: String {
        get { storedLyricsTextSize }
        set {
            let value = ["small", "standard", "large"].contains(newValue) ? newValue : "standard"
            guard value != storedLyricsTextSize else { return }
            storedLyricsTextSize = value
            defaults.set(value, forKey: "lyricsTextSize"); notify()
        }
    }
    @Published private var storedLyricsBackgroundOpacity: Double
    var lyricsBackgroundOpacity: Double {
        get { storedLyricsBackgroundOpacity }
        set {
            let value = Self.validLyricsBackground(newValue)
            guard value != storedLyricsBackgroundOpacity else { return }
            storedLyricsBackgroundOpacity = value
            defaults.set(value, forKey: "lyricsBackgroundOpacity"); notify()
        }
    }
    @Published private(set) var lyricOffsets: [String: Double] {
        didSet { defaults.set(lyricOffsets, forKey: "lyricOffsetsV1"); notify() }
    }
    @Published var flags: [String: Bool] { didSet { defaults.set(flags, forKey: "flags"); notify() } }

    static let defaultsFlags: [String: Bool] = [
        "dockEnabled": true, "dockIcon": true, "menuIcon": false,
        "music": true, "lyrics": true, "lyricsBold": false, "coverTint": true,
        "spectrum": true, "coverBlur": true, "hideFullscreen": false,
        "calendar": true, "reminders": true, "allDay": true, "completed": false,
        "fullTitles": true, "calendarScroll": true,
        "shelf": true, "shelfOnDrag": true, "shelfCopy": true, "shelfRemove": false,
        "shelfPriority": true, "shelfLargeTarget": true,
        "hud": true, "volumeHUD": true, "brightnessHUD": true, "hudPercent": true,
        "mirror": false, "mirrorRound": true, "idleFace": false,
        "hover": true, "haptics": true, "rememberTab": true, "showTabs": true,
        "islandSettings": true, "shadow": true, "allDisplays": true,
        "automaticDisplay": true, "hideLocked": true, "intro": true
    ]

    init(defaults: UserDefaults = UserDefaults.standard) {
        self.defaults = defaults
        let savedColor = defaults.object(forKey: "lyricsColorRGB") as? Int
        lyricsColorRGB = savedColor.flatMap { (0...0xFFFFFF).contains($0) ? $0 : nil } ?? Self.defaultLyricsColorRGB
        language = defaults.string(forKey: "language") ?? "system"
        selectedDisplay = defaults.string(forKey: "display") ?? ""
        excludedApps = defaults.string(forKey: "excludedApps") ?? ""
        musicIdleTimeout = defaults.object(forKey: "musicIdleTimeout") as? Double ?? 30
        hoverDelay = defaults.object(forKey: "hoverDelay") as? Double ?? 0.3
        islandHeight = defaults.object(forKey: "islandHeight") as? Double ?? 0
        mediaSource = defaults.string(forKey: "mediaSource") ?? "auto"
        youtubeURL = defaults.string(forKey: "youtubeURL") ?? "http://localhost:9863/api/v1"
        controllerSlots = defaults.stringArray(forKey: "controllerSlots") ?? ["previous", "play", "next", "mute", "volume"]
        let savedTextSize = defaults.string(forKey: "lyricsTextSize") ?? "standard"
        storedLyricsTextSize = ["small", "standard", "large"].contains(savedTextSize) ? savedTextSize : "standard"
        storedLyricsBackgroundOpacity = Self.validLyricsBackground(defaults.object(forKey: "lyricsBackgroundOpacity") as? Double ?? 0.65)
        var offsets: [String: Double] = [:]
        for (key, raw) in defaults.dictionary(forKey: "lyricOffsetsV1") ?? [:] {
            guard !key.isEmpty, key.count <= 2048, let number = raw as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { continue }
            let value = LyricDisplayPolicy.clampedOffset(number.doubleValue)
            if value != 0 { offsets[key] = value }
        }
        lyricOffsets = offsets
        let saved = defaults.dictionary(forKey: "flags") as? [String: Bool] ?? [:]
        let retired: Set<String> = ["battery", "batteryPercent", "chargeNotice", "trackPeek"]
        flags = Self.defaultsFlags.merging(saved.filter { !retired.contains($0.key) }) { _, saved in saved }
    }
    func enabled(_ key: String) -> Bool { flags[key] ?? false }
    func lyricOffset(for trackKey: String) -> Double {
        guard !trackKey.isEmpty else { return 0 }
        return LyricDisplayPolicy.clampedOffset(lyricOffsets[trackKey] ?? 0)
    }
    func setLyricOffset(_ value: Double, for trackKey: String) {
        guard !trackKey.isEmpty, trackKey.count <= 2048 else { return }
        let adjusted = LyricDisplayPolicy.clampedOffset(value)
        guard lyricOffset(for: trackKey) != adjusted else { return }
        if adjusted == 0 { lyricOffsets.removeValue(forKey: trackKey) }
        else { lyricOffsets[trackKey] = adjusted }
    }
    private static func validLyricsBackground(_ value: Double) -> Double {
        value.isFinite ? min(0.9, max(0, value)) : 0.65
    }
    func set(_ key: String, _ value: Bool) { flags[key] = value }
    func binding(_ key: String) -> Binding<Bool> {
        Binding(get: { self.enabled(key) }, set: { self.set(key, $0) })
    }
    var effectiveLanguage: String {
        let value = language == "system" ? (Locale.preferredLanguages.first ?? "en") : language
        if value.hasPrefix("zh") { return "zh-Hans" }
        if value.hasPrefix("ja") { return "ja" }
        if value.hasPrefix("ru") { return "ru" }
        return "en"
    }
    var locale: Locale { Locale(identifier: effectiveLanguage) }
    private func notify() { NotificationCenter.default.post(name: .realPreferencesChanged, object: self) }
}

@MainActor enum Copy {
    static let translations: [String: [String: String]] = {
        guard let url = Bundle.main.url(forResource: "Translations", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let result = try? JSONDecoder().decode([String: [String: String]].self, from: data) else { return [:] }
        return result
    }()
    static func text(_ key: String) -> String {
        let language = Preferences.shared.effectiveLanguage
        return language == "zh-Hans" ? key : translations[key]?[language] ?? translations[key]?["en"] ?? key
    }
}

@MainActor func tr(_ key: String) -> String { Copy.text(key) }
