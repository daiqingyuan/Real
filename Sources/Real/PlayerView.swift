import AppKit
import CoreImage
import SwiftUI

struct PlayerView: View {
    @ObservedObject var spectrum: AudioSpectrumService
    @ObservedObject var player: QQPlaybackService
    @ObservedObject var media: MediaService
    @ObservedObject var youtube: YouTubeMusicService
    @ObservedObject var lyrics: LyricsService
    @ObservedObject var system: SystemStatusService
    @ObservedObject var preferences: Preferences
    var demo: Bool
    var useDesktopPlayer = false
    var interactionEnabled = true
    var popoverChanged: (Bool) -> Void = { _ in }

    @State private var showLyrics = false
    @State private var volumeSlot: Int?
    @State private var isSeeking = false
    @State private var seekPosition = 0.0
    @State private var coverColor = Color.white
    @State private var lyricFollow = LyricFollowState()

    private var useDesktop: Bool { useDesktopPlayer || ["qq", "netease"].contains(preferences.mediaSource) }
    private var useYouTube: Bool { preferences.mediaSource == "ytm" }
    private var title: String { demo ? tr("午后播放列表") : (useDesktop ? player.title : useYouTube ? youtube.title : media.title) }
    private var artist: String { demo ? "Real" : (useDesktop ? player.artist : useYouTube ? youtube.artist : media.artist) }
    private var album: String { demo ? "" : (useDesktop ? player.album : useYouTube ? youtube.album : media.album) }
    private var artwork: NSImage? { demo ? nil : (useDesktop ? player.artwork : useYouTube ? youtube.artwork : media.artwork) }
    private var playing: Bool { !demo && (useDesktop ? player.isPlaying : useYouTube ? youtube.isPlaying : media.isPlaying) }
    private var position: Double { demo ? 0 : (useDesktop ? player.position : useYouTube ? youtube.position : media.position) }
    private var duration: Double { demo ? 0 : (useDesktop ? player.duration : useYouTube ? youtube.duration : media.duration) }
    private var sourceName: String { demo ? tr("预览") : (useDesktop ? player.sourceName : useYouTube ? youtube.sourceName : media.sourceName) }
    private var error: String? { demo ? nil : (useDesktop ? player.errorMessage : useYouTube ? youtube.errorMessage : media.errorMessage) }
    private var available: Bool { !demo && interactionEnabled && preferences.enabled("music") && !title.isEmpty && (!useYouTube || youtube.isEnabled) }
    private var accent: Color { preferences.enabled("coverTint") ? coverColor : .white }
    private var sourceBundleIdentifier: String? { useDesktop ? player.sourceBundleIdentifier : useYouTube ? "ytmdesktop" : media.sourceBundleIdentifier }
    private var trackKey: String { LyricDisplayPolicy.trackKey(sourceBundleIdentifier: sourceBundleIdentifier, title: title, artist: artist) }
    private var hasReliableTiming: Bool { position.isFinite && position >= 0 && (!useDesktop || player.hasTiming) }
    private var lyricPosition: Double { LyricDisplayPolicy.displayTime(playbackTime: position, offset: preferences.lyricOffset(for: trackKey)) }
    private var currentLineID: Int? { hasReliableTiming && lyrics.trackKey == trackKey ? lyrics.displayLyricLine(at: lyricPosition)?.id : nil }
    private var lyricFontSize: CGFloat { LyricDisplayPolicy.fontSize(for: preferences.lyricsTextSize) }
    private var lyricWeight: Font.Weight { preferences.enabled("lyricsBold") ? .bold : .medium }
    private var lyricSummary: String {
        if demo { return tr("歌词将在播放时显示") }
        guard hasReliableTiming else { return tr("等待可靠的播放进度") }
        guard lyrics.trackKey == trackKey else { return tr("正在加载歌词…") }
        return lyrics.lines.isEmpty ? tr(lyrics.availability.messageKey) : lyrics.currentLine(at: lyricPosition)
    }
    private var controls: [String] {
        let defaults = ["previous", "play", "next", "mute", "volume"]
        return (0..<5).map { index in
            let value = preferences.controllerSlots.indices.contains(index) ? preferences.controllerSlots[index] : defaults[index]
            return defaults.contains(value) ? value : defaults[index]
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .center, spacing: 18) {
                cover
                VStack(alignment: .leading, spacing: 4) {
                    ScrollingLyric(text: title.isEmpty ? tr("没有正在播放的音乐") : title, fontSize: 14, weight: .semibold, centerShortText: false).frame(height: 18)
                    ScrollingLyric(text: artist.isEmpty ? tr("打开音乐播放器开始播放") : artist, fontSize: 12, centerShortText: false)
                        .frame(height: 16).foregroundStyle(accent.opacity(0.85))
                    if preferences.enabled("lyrics") {
                        ScrollingLyric(text: lyricSummary, fontSize: lyricFontSize, weight: lyricWeight, centerShortText: false)
                            .frame(height: ceil(lyricFontSize * 1.4)).foregroundStyle(preferences.lyricsColor)
                    }
                    seekBar.padding(.top, 3)
                    HStack(spacing: 3) {
                        ForEach(0..<5, id: \.self) { index in control(controls[index], index: index).frame(maxWidth: .infinity) }
                    }.buttonStyle(.plain).font(.system(size: 13)).padding(.top, 1)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if !demo, spectrum.isRunning { SpectrumView(service: spectrum, colored: preferences.enabled("spectrum")).frame(height: 22) }
            if showLyrics, preferences.enabled("lyrics"), !demo { lyricScroll }
            if let error { Text(error).font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
        }
        .onAppear { updateCoverColor(); lyricFollow.selectTrack(trackKey) }
        .onChange(of: volumeSlot != nil) { _, open in popoverChanged(open) }
        .onDisappear { volumeSlot = nil; popoverChanged(false) }
        .onChange(of: artwork) { _, _ in updateCoverColor() }
        .onChange(of: trackKey) { _, key in isSeeking = false; lyricFollow.selectTrack(key) }

    }

    private var cover: some View {
        VStack(spacing: 7) {
            Group {
                if let artwork { Image(nsImage: artwork).resizable().scaledToFill() }
                else { RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.08)).overlay(Image(systemName: "music.note").font(.system(size: 28)).foregroundStyle(.white.opacity(0.45))) }
            }.frame(width: 110, height: 110).clipShape(RoundedRectangle(cornerRadius: 12))
                .background {
                    if preferences.enabled("coverBlur"), let artwork {
                        Image(nsImage: artwork).resizable().scaledToFill().frame(width: 100, height: 100).blur(radius: 25).opacity(playing ? 0.3 : 0.1)
                    }
                }
            if preferences.enabled("lyrics") {
                Button {
                    guard !demo else { return }
                    withAnimation(.easeInOut(duration: 0.2)) { showLyrics.toggle() }
                } label: { Label(tr(showLyrics ? "收起歌词" : "展开歌词"), systemImage: "text.alignleft") }
                    .font(.system(size: 9)).buttonStyle(.plain).foregroundStyle(.white.opacity(0.45)).disabled(demo || title.isEmpty)
            } else { Text(sourceName).font(.system(size: 9)).foregroundStyle(.white.opacity(0.4)) }
        }.frame(width: 110)
    }

    private var seekBar: some View {
        VStack(spacing: 2) {
            ThinSeekSlider(value: Binding(get: { isSeeking ? seekPosition : min(duration, position) }, set: { seekPosition = $0 }),
                maximum: max(1, duration), tint: NSColor(accent), enabled: available && duration > 0 && (!useDesktop || player.canSeek)) { editing in
                    if editing { seekPosition = min(duration, position); isSeeking = true }
                    else { isSeeking = false; seek(to: seekPosition) }
                }.frame(height: 12).accessibilityLabel(tr("播放进度"))
            HStack { Text(timeText(isSeeking ? seekPosition : position)); Spacer(); Text(timeText(duration)) }
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.4))
        }
    }

    @ViewBuilder private func control(_ name: String, index: Int) -> some View {
        switch name {
        case "previous":
            Button { guard available else { return }; if useDesktop { player.previous() } else if useYouTube { youtube.previous() } else { media.previous() } }
                label: { Image(systemName: "backward.fill").frame(width: 32, height: 30) }
                .disabled(!available || (useDesktop && !player.canPrevious)).help(tr("上一首")).accessibilityLabel(tr("上一首"))
        case "next":
            Button { guard available else { return }; if useDesktop { player.next() } else if useYouTube { youtube.next() } else { media.next() } }
                label: { Image(systemName: "forward.fill").frame(width: 32, height: 30) }
                .disabled(!available || (useDesktop && !player.canNext)).help(tr("下一首")).accessibilityLabel(tr("下一首"))
        case "mute":
            Button { guard !demo, interactionEnabled, system.canToggleMute else { return }; system.toggleMute() }
                label: { Image(systemName: !demo && system.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill").frame(width: 32, height: 30) }
                .disabled(demo || !interactionEnabled || !system.canToggleMute).help(tr("静音")).accessibilityLabel(tr("静音"))
        case "volume":
            Button { guard !demo, interactionEnabled, system.canSetVolume else { return }; volumeSlot = volumeSlot == index ? nil : index }
                label: { Image(systemName: "slider.horizontal.3").frame(width: 32, height: 30) }
                .disabled(demo || !interactionEnabled || !system.canSetVolume).help(tr("音量")).accessibilityLabel(tr("音量"))
                .popover(isPresented: Binding(get: { volumeSlot == index }, set: { if !$0 && volumeSlot == index { volumeSlot = nil } })) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(tr("系统音量")).font(.caption)
                        Slider(value: Binding(get: { demo ? 0.5 : system.volume }, set: { if !demo && system.canSetVolume { system.setVolume($0) } }), in: 0...1)
                            .disabled(demo || !interactionEnabled || !system.canSetVolume).accessibilityLabel(tr("系统音量"))
                    }.padding(16).frame(width: 200)
                }
        default:
            Button { guard available else { return }; if useDesktop { player.playPause() } else if useYouTube { youtube.playPause() } else { media.playPause() } }
                label: { Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 20, weight: .medium)).frame(width: 32, height: 30) }
                .disabled(!available || (useDesktop && !player.canPlayPause)).help(tr("播放与暂停")).accessibilityLabel(tr(playing ? "暂停" : "播放"))
        }
    }

    private var lyricScroll: some View {
        ScrollViewReader { reader in
            VStack(alignment: .leading, spacing: 8) {
                Text(lyrics.trackKey == trackKey ? lyrics.displayMessage(hasReliableTiming: hasReliableTiming) : tr("正在加载歌词…"))
                    .font(.caption2).foregroundStyle(.white.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
                if !lyricFollow.following || lyrics.lines.isEmpty {
                    HStack(spacing: 12) {
                        if !lyricFollow.following {
                            Button(tr("回到当前句")) {
                                lyricFollow.resumeFollowing()
                                if let id = currentLineID { withAnimation(.easeInOut(duration: 0.2)) { reader.scrollTo(id, anchor: .center) } }
                            }
                        }
                        if lyrics.lines.isEmpty {
                            Button(tr("重试歌词")) { lyrics.retryCurrentTrack(expectedTrackKey: trackKey) }
                                .disabled(!lyrics.canRetry(expectedTrackKey: trackKey))
                            if lyrics.availability == .loading { ProgressView().controlSize(.mini) }
                        }
                        Spacer(minLength: 0)
                    }.font(.caption2).buttonStyle(.plain).foregroundStyle(preferences.lyricsColor)
                }
                if lyrics.trackKey == trackKey, !lyrics.lines.isEmpty {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(lyrics.lines) { line in
                                Button { guard available else { return }; seek(to: line.time) } label: {
                                    Text(line.text.isEmpty ? " " : line.text)
                                        .font(.system(size: lyricFontSize, weight: preferences.enabled("lyricsBold") ? .bold : line.id == currentLineID ? .semibold : .regular))
                                        .foregroundStyle(line.id == currentLineID ? preferences.lyricsColor : .white.opacity(0.55))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                }.buttonStyle(.plain).disabled(!available || (useDesktop && !player.canSeek)).id(line.id)
                                if !lyrics.isEnglish, let translation = line.translation, !translation.isEmpty {
                                    Text(translation).font(.system(size: max(9, lyricFontSize - 3), weight: preferences.enabled("lyricsBold") ? .semibold : .regular)).foregroundStyle(.white.opacity(0.45))
                                }
                            }
                        }.padding(.vertical, 8)
                    }.frame(height: 130)
                        .background(LyricScrollInteractionObserver { lyricFollow.userScrolled() })
                        .accessibilityLabel(tr("歌词列表"))
                        .onAppear { scrollToCurrentLine(reader) }
                }
            }
            .onChange(of: currentLineID) { _, _ in scrollToCurrentLine(reader) }
            .onChange(of: lyrics.lines) { _, _ in scrollToCurrentLine(reader) }
        }
    }

    private func scrollToCurrentLine(_ reader: ScrollViewProxy) {
        guard lyricFollow.following, let id = currentLineID else { return }
        withAnimation(.easeInOut(duration: 0.22)) { reader.scrollTo(id, anchor: .center) }
    }

    private func seek(to value: Double) {
        guard available else { return }
        if useDesktop { player.seek(to: value) } else if useYouTube { youtube.seek(to: value) } else { media.seek(to: value) }
    }

    private func timeText(_ value: Double) -> String {
        let seconds = value.isFinite ? Int(min(86_400, max(0, value))) : 0
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func updateCoverColor() {
        guard let artwork, let image = artwork.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let filter = CIFilter(name: "CIAreaAverage") else { coverColor = .white; return }
        let input = CIImage(cgImage: image)
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: input.extent), forKey: kCIInputExtentKey)
        guard let output = filter.outputImage else { coverColor = .white; return }
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: NSNull()]).render(output, toBitmap: &pixel, rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        // Mix the genuine cover average toward white so small lyric text stays readable.
        coverColor = Color(red: 0.45 + Double(pixel[0]) / 255 * 0.55,
                           green: 0.45 + Double(pixel[1]) / 255 * 0.55,
                           blue: 0.45 + Double(pixel[2]) / 255 * 0.55)
    }
}

/// SwiftUI's programmatic scrolls do not emit scroll-wheel events. This passive
/// observer catches a real mouse wheel and trackpad only within this lyric list
/// and its own window, then returns the original event unchanged.
private struct LyricScrollInteractionObserver: NSViewRepresentable {
    let onScroll: () -> Void
    func makeNSView(context: Context) -> LyricScrollObserverView {
        let view = LyricScrollObserverView()
        view.onScroll = onScroll
        return view
    }
    func updateNSView(_ nsView: LyricScrollObserverView, context: Context) { nsView.onScroll = onScroll }
    static func dismantleNSView(_ nsView: LyricScrollObserverView, coordinator: ()) { nsView.stopObserving() }
}

private final class LyricScrollObserverView: NSView {
    var onScroll: (() -> Void)?
    private var monitor: Any?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let window = self.window, event.window === window,
                  window.isVisible, !self.isHiddenOrHasHiddenAncestor,
                  self.bounds.contains(self.convert(event.locationInWindow, from: nil)),
                  event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 else { return event }
            self.onScroll?()
            return event
        }
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { stopObserving() }
        super.viewWillMove(toWindow: newWindow)
    }
    func stopObserving() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
