import AppKit
import Combine
import SwiftUI
import ServiceManagement

@MainActor final class AppModel: ObservableObject {
    let preferences = Preferences.shared
    let permissions = PermissionCoordinator()
    let dock = DockEngine()
    let media = MediaService()
    let youtube = YouTubeMusicService()
    let qq = QQPlaybackService()
    let netease = QQPlaybackService(player: .netease)
    let lyrics = LyricsService()
    let calendar = CalendarService()
    let shelf = ShelfService(storageURL: RealLaunchPolicy.isDesignPreview(bundleIdentifier: Bundle.main.bundleIdentifier)
        ? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "local.dan.real.preview", isDirectory: true)
            .appendingPathComponent("shelf-bookmarks.json") : nil)
    let system = SystemStatusService()
    let mirror = MirrorService()
    let spectrum = AudioSpectrumService()
    @Published var page = "island"
    @Published var selectedModule = "music"
    @Published var islandTab = "music" { didSet { if oldValue != islandTab { refreshHosts?() } } }
    @Published var errorMessage = ""
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var hud: (String, Double)?
    @Published var introVisible = false
    @Published var mediaRecentlyActive = false
    @Published var liveQQPreview = false
    @Published private(set) var lastRuntimeCheck: Date?
    private var idleDismiss: Task<Void, Never>?
    @Published private(set) var selectedMedia: MediaSelection = .native
    private var mediaActivity = MediaActivityTracker()
    var usingQQ: Bool { liveQQPreview || selectedMedia == .qq }
    var usingDesktopPlayer: Bool { liveQQPreview || selectedMedia == .qq || selectedMedia == .netease }
    var desktopPlayer: QQPlaybackService { !liveQQPreview && selectedMedia == .netease ? netease : qq }
    var currentLyricTrackKey: String {
        if usingDesktopPlayer {
            return LyricDisplayPolicy.trackKey(sourceBundleIdentifier: desktopPlayer.sourceBundleIdentifier,
                                               title: desktopPlayer.title, artist: desktopPlayer.artist)
        }
        if preferences.mediaSource == "ytm" {
            return LyricDisplayPolicy.trackKey(sourceBundleIdentifier: "ytmdesktop", title: youtube.title, artist: youtube.artist)
        }
        return LyricDisplayPolicy.trackKey(sourceBundleIdentifier: media.sourceBundleIdentifier, title: media.title, artist: media.artist)
    }
    var showFloatingLyrics: Bool { !previewOnly && usingDesktopPlayer && desktopPlayer.isPlaying && preferences.enabled("music") && preferences.enabled("lyrics") && !desktopPlayer.title.isEmpty && hud == nil }
    var showUninstall: (() -> Void)?
    var showSettings: (() -> Void)?
    var refreshHosts: (() -> Void)?
    var permissionStateChanged: (() -> Void)?
    private var subscriptions = Set<AnyCancellable>()
    private var hudDismiss: Task<Void, Never>?
    var isUninstalling = false
    private(set) var previewOnly = true

    init() {
        if preferences.enabled("rememberTab"), let saved = UserDefaults.standard.string(forKey: "islandTab"), ["music", "calendar", "shelf", "mirror"].contains(saved) { islandTab = saved }
        calendar.includeCompleted = preferences.enabled("completed")
        permissions.onPermissionsChanged = { [weak self] in
            guard let self, !self.previewOnly else { return }
            if !self.permissions.granted.contains(.accessibility) || !self.permissions.granted.contains(.screenRecording) {
                self.dock.stop()
            }
            self.applyPreferences()
            self.permissionStateChanged?()
        }
        // Publishers emit before their stored properties change. Schedule one
        // refresh on the main actor after the metadata transaction finishes.
        // LyricsService debounces network work itself and clears stale lines now.
        media.$title.combineLatest(media.$artist, media.$duration, media.$sourceName)
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 && $0.2 == $1.2 && $0.3 == $1.3 }
            .sink { [weak self] _ in self?.scheduleMediaRefresh() }.store(in: &subscriptions)
        media.$album.removeDuplicates().sink { [weak self] _ in self?.scheduleMediaRefresh() }.store(in: &subscriptions)
        qq.$title.combineLatest(qq.$artist, qq.$duration, qq.$album)
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 && $0.2 == $1.2 && $0.3 == $1.3 }
            .sink { [weak self] _ in self?.scheduleMediaRefresh() }.store(in: &subscriptions)
        netease.$title.combineLatest(netease.$artist, netease.$duration, netease.$album)
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 && $0.2 == $1.2 && $0.3 == $1.3 }
            .sink { [weak self] _ in self?.scheduleMediaRefresh() }.store(in: &subscriptions)
        youtube.$title.combineLatest(youtube.$artist, youtube.$duration)
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 && $0.2 == $1.2 }
            .sink { [weak self] _ in self?.scheduleMediaRefresh() }.store(in: &subscriptions)
        media.$isPlaying.combineLatest(qq.$isPlaying, youtube.$isPlaying, netease.$isPlaying)
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 && $0.2 == $1.2 && $0.3 == $1.3 }
            .sink { [weak self] _ in self?.scheduleMediaRefresh() }.store(in: &subscriptions)
    }
    private var mediaRefresh: Task<Void, Never>?
    private func scheduleMediaRefresh() {
        guard !isUninstalling, mediaRefresh == nil else { return }
        mediaRefresh = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            self.mediaRefresh = nil
            self.refreshMediaActivity()
            self.objectWillChange.send()
            self.refreshHosts?()
        }
    }
    func toggleQQPreview() {
        liveQQPreview.toggle()
        if liveQQPreview { qq.start(); refreshMediaActivity() }
        else if previewOnly { qq.stop(); lyrics.load(title: "", artist: "", duration: 0) }
    }
    func start(preview: Bool) {
        guard !isUninstalling else { return }
        previewOnly = preview
        permissions.configure(active: !preview, dock: preferences.enabled("dockEnabled"), hud: preferences.enabled("hud"))
        guard !preview else { dock.stop(); return }
        liveQQPreview = false
        system.start()
        applyPreferences()
    }
    private func refreshMediaActivity() {
        selectedMedia = mediaActivity.select(mode: preferences.mediaSource, previous: selectedMedia, states: [
            MediaSourceState(source: .qq, available: !qq.title.isEmpty, playing: qq.isPlaying),
            MediaSourceState(source: .netease, available: !netease.title.isEmpty, playing: netease.isPlaying),
            MediaSourceState(source: .native, available: !media.title.isEmpty, playing: media.isPlaying)
        ])
        refreshSelectedLyrics()
        idleDismiss?.cancel()
        let playing = usingDesktopPlayer ? desktopPlayer.isPlaying : preferences.mediaSource == "ytm" ? youtube.isPlaying : media.isPlaying
        if playing { mediaRecentlyActive = true; return }
        guard mediaRecentlyActive, preferences.musicIdleTimeout > 0 else { return }
        let delay = min(600, max(1, preferences.musicIdleTimeout))
        idleDismiss = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }; self?.mediaRecentlyActive = false
        }
    }
    private func refreshSelectedLyrics() {
        guard preferences.enabled("music"), preferences.enabled("lyrics"), (!previewOnly || liveQQPreview) else {
            lyrics.load(title: "", artist: "", duration: 0); return
        }
        if usingDesktopPlayer {
            let player = desktopPlayer
            lyrics.load(sourceBundleIdentifier: player.sourceBundleIdentifier, title: player.title,
                        artist: player.artist, duration: player.duration, album: player.album)
        }
        else if preferences.mediaSource == "ytm" { lyrics.load(sourceBundleIdentifier: "ytmdesktop", title: youtube.title, artist: youtube.artist, duration: youtube.duration) }
        else { lyrics.load(sourceBundleIdentifier: media.sourceBundleIdentifier, title: media.title, artist: media.artist, duration: media.duration, album: media.album) }
    }
    func applyPreferences() {
        guard !isUninstalling else { return }
        permissions.configure(active: !previewOnly, dock: preferences.enabled("dockEnabled"), hud: preferences.enabled("hud"))
        refreshMediaActivity()
        if !preferences.enabled(islandTab) {
            islandTab = ["music", "calendar", "shelf", "mirror"].first { preferences.enabled($0) } ?? "empty"
        }
        if !preferences.enabled("music") { spectrum.stop(); if liveQQPreview { liveQQPreview = false; if previewOnly { qq.stop() } } }
        guard !previewOnly else { return }
        if preferences.enabled("music") { media.start(); qq.start(); netease.start() }
        else { media.stop(); qq.stop(); netease.stop(); youtube.stop() }
        if preferences.enabled("calendar") { calendar.start() } else { calendar.stop() }
        dock.excludedBundleIDs = Set(preferences.excludedApps.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init))
        if preferences.enabled("dockEnabled") { dock.start() } else { dock.stop() }
        if !preferences.enabled("mirror") { mirror.stop() }
        refreshHosts?()
    }
    func stop() { permissions.stopPolling(); mediaRefresh?.cancel(); mediaRefresh = nil; dock.stop(); media.stop(); qq.stop(); netease.stop(); youtube.stop(); calendar.stop(); system.stop(); mirror.stop(); spectrum.stop(); hudDismiss?.cancel(); idleDismiss?.cancel() }
    func refreshLoginStatus() {
        loginEnabled = SMAppService.mainApp.status == .enabled
    }
    func setLogin(_ enabled: Bool) {
        defer { refreshLoginStatus() }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            refreshLoginStatus()
            if enabled && !loginEnabled { errorMessage = tr("请在系统设置中允许登录项") }
        } catch { errorMessage = error.localizedDescription }
    }
    func showHUD(_ kind: String, value: Double) {
        hudDismiss?.cancel()
        withAnimation(.easeOut(duration: 0.18)) { hud = (kind, value) }
        refreshHosts?()
        hudDismiss = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.18)) { self?.hud = nil }
            self?.refreshHosts?()
        }
    }
    func openPrivacy(_ section: String) {
        if let permission = RealPermission.allCases.first(where: { $0.privacySection == section }) {
            if permissions.requested.contains(permission) { permissions.showSystemSettings(for: permission) }
            else { permissions.requestPermission(permission) }
            return
        }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + section) else { return }
        NSWorkspace.shared.open(url)
    }
    func checkRuntime() {
        guard !previewOnly, !isUninstalling else { return }
        permissions.refresh()
        dock.checkHealth()
        refreshLoginStatus()
        lastRuntimeCheck = Date()
    }
    func repairRuntime() {
        guard !previewOnly, !isUninstalling else { return }
        permissions.refresh()
        if preferences.enabled("dockEnabled") { dock.repairIfNeeded() }
        // Reconnect only a reader which reports an error. A healthy reader and
        // a deliberately paused player are left alone; no transport is sent.
        if preferences.enabled("music") {
            if media.errorMessage != nil { media.stop(); media.start() }
            if qq.errorMessage != nil { qq.stop(); qq.start() }
            if netease.errorMessage != nil { netease.stop(); netease.start() }
        }
        refreshLoginStatus()
        lastRuntimeCheck = Date()
    }
    func diagnosticText() -> String {
        let lastCheck = lastRuntimeCheck.map { ISO8601DateFormatter().string(from: $0) } ?? "not checked manually"
        return "\(AppVersion.diagnosticLabel)\n" +
            "bundle: \(Bundle.main.bundleIdentifier ?? "unknown")\n" +
            "system: \(ProcessInfo.processInfo.operatingSystemVersionString)\n" +
            "preview: \(previewOnly)\n" +
            "accessibility: \(AXIsProcessTrusted())\n" +
            "inputMonitoring: \(CGPreflightListenEventAccess())\n" +
            "screenRecording: \(CGPreflightScreenCaptureAccess())\n" +
            "lastRuntimeCheck: \(lastCheck)\n" +
            "loginEnabled: \(loginEnabled)\n" +
            "selectedMedia: \(selectedMedia.rawValue)\n" +
            "musicEnabled: \(preferences.enabled("music")), lyricsEnabled: \(preferences.enabled("lyrics"))\n" +
            "qqTiming: \(qq.hasTiming), playing: \(qq.isPlaying), lyricLines: \(lyrics.lines.count)\n" +
            "neteaseTiming: \(netease.hasTiming), playing: \(netease.isPlaying)\n" +
            "wordTimedLyricLines: \(lyrics.lines.filter { !$0.words.isEmpty }.count), lyricWordSpans: \(lyrics.lines.reduce(0) { $0 + $1.words.count })\n" +
            "mediaReaderError: \(media.errorMessage != nil)\n" +
            "qqReaderError: \(qq.errorMessage != nil), neteaseReaderError: \(netease.errorMessage != nil)\n" +
            "excludedApplicationCount: \(ApplicationExclusions.identifiers(in: preferences.excludedApps).count)\n" +
            "lyricTextSize: \(preferences.lyricsTextSize), lyricBackground: \(preferences.lyricsBackgroundOpacity)\n" +
            "savedLyricAdjustmentCount: \(preferences.lyricOffsets.count)\n\n" + dock.diagnosticSnapshot()
    }
    func exportDiagnostics() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Real-diagnostics.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = diagnosticText()
        do { try text.write(to: url, atomically: true, encoding: .utf8) }
        catch { errorMessage = error.localizedDescription }
    }
}
