import AppKit
import CoreText
import SwiftUI

/// One shaped line is drawn twice. The second pass changes only its clipping
/// region, so kerning, ligatures, centering and scrolling cannot diverge.
final class KaraokeTextLayout {
    let text: String
    let line: CTLine
    let width: CGFloat
    let ascent: CGFloat
    let descent: CGFloat

    init(text: String, font: NSFont) {
        self.text = text
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
        ]
        line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        var asc: CGFloat = 0, desc: CGFloat = 0
        width = CGFloat(CTLineGetTypographicBounds(line, &asc, &desc, nil))
        ascent = asc; descent = desc
    }

    func highlightRects(words: [LyricWord], time: Double, height: CGFloat) -> [CGRect] {
        guard time.isFinite, height.isFinite, height > 0 else { return [] }
        let count = (text as NSString).length
        let runs = shapedRuns
        return words.flatMap { word -> [CGRect] in
            guard word.utf16Location >= 0, word.utf16Length > 0,
                  word.utf16Location <= count, word.utf16Length <= count - word.utf16Location,
                  word.startTime.isFinite, word.duration.isFinite, word.duration >= 0,
                  time >= word.startTime else { return [] }
            let progress = word.duration == 0 ? 1 : min(1, max(0, (time - word.startTime) / word.duration))
            guard progress > 0 else { return [] }
            let wordEnd = word.utf16Location + word.utf16Length
            let spans = runs.compactMap { run -> (left: CGFloat, right: CGFloat, rtl: Bool)? in
                let lower = max(word.utf16Location, run.range.lowerBound)
                let upper = min(wordEnd, run.range.upperBound)
                guard lower < upper,
                      let start = caretOffset(at: lower, in: run),
                      let end = caretOffset(at: upper, in: run) else { return nil }
                let left = min(start, end), right = max(start, end)
                return right > left ? (left, right, run.rightToLeft) : nil
            }
            // One timed provider token can contain several directional/font
            // runs. Consume their widths in logical string order, then fill
            // each run in its own direction without reshaping any glyph.
            var remaining = spans.reduce(CGFloat.zero) { $0 + $1.right - $1.left } * progress
            guard remaining.isFinite else { return [] }
            return spans.compactMap { span in
                let filled = min(span.right - span.left, remaining)
                remaining -= filled
                guard filled > 0 else { return nil }
                return CGRect(x: span.rtl ? span.right - filled : span.left,
                              y: 0, width: filled, height: height)
            }
        }
    }

    private lazy var shapedRuns = visualRuns(textLength: (text as NSString).length)

    private struct VisualRun {
        let range: Range<Int>
        let left: CGFloat
        let right: CGFloat
        let rightToLeft: Bool
    }

    private func visualRuns(textLength: Int) -> [VisualRun] {
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
        return runs.compactMap { run in
            let range = CTRunGetStringRange(run)
            let count = CTRunGetGlyphCount(run)
            guard range.location >= 0, range.length > 0, range.location <= textLength,
                  range.length <= textLength - range.location, count > 0 else { return nil }
            var positions = [CGPoint](repeating: .zero, count: count)
            var advances = [CGSize](repeating: .zero, count: count)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            CTRunGetAdvances(run, CFRange(location: 0, length: 0), &advances)
            var left = CGFloat.infinity, right = -CGFloat.infinity
            for index in 0..<count {
                let start = positions[index].x, end = start + advances[index].width
                guard start.isFinite, end.isFinite else { return nil }
                left = min(left, start, end); right = max(right, start, end)
            }
            guard right > left else { return nil }
            return VisualRun(range: range.location..<(range.location + range.length), left: left, right: right,
                             rightToLeft: CTRunGetStatus(run).contains(.rightToLeft))
        }.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    private func caretOffset(at index: Int, in run: VisualRun) -> CGFloat? {
        // Bidi boundaries have two valid caret positions. The primary position
        // can belong to the adjoining run at BOTH ends of a word, making its
        // apparent width zero. Run edges resolve that ambiguity explicitly.
        if index == run.range.lowerBound { return run.rightToLeft ? run.right : run.left }
        if index == run.range.upperBound { return run.rightToLeft ? run.left : run.right }
        var secondary: CGFloat = 0
        let primary = CTLineGetOffsetForStringIndex(line, index, &secondary)
        let tolerance: CGFloat = 0.001
        for offset in [primary, secondary] where offset.isFinite
            && offset >= run.left - tolerance && offset <= run.right + tolerance {
            return min(run.right, max(run.left, offset))
        }
        return nil
    }

    static func horizontalOffset(textWidth: CGFloat, viewportWidth: CGFloat, elapsed: Double,
                                 centerShortText: Bool, reduceMotion: Bool) -> CGFloat {
        let distance = max(0, textWidth - viewportWidth)
        guard distance > 0 else { return centerShortText ? max(0, (viewportWidth - textWidth) / 2) : 0 }
        guard !reduceMotion, elapsed.isFinite else { return 0 }
        let travel = Double(distance) / 24
        let cycle = 3 + travel * 2
        let phase = max(0, elapsed).truncatingRemainder(dividingBy: cycle)
        return -CGFloat(min(Double(distance), max(0, phase < 1.5 + travel ? (phase - 1.5) * 24 : (cycle - phase) * 24)))
    }

    func draw(in context: CGContext, size: CGSize, lyric: LyricLine, time: Double,
              elapsed: Double, highlight: NSColor, centerShortText: Bool, reduceMotion: Bool) {
        guard size.width > 0, size.height > 0 else { return }
        let x = Self.horizontalOffset(textWidth: width, viewportWidth: size.width, elapsed: elapsed,
                                      centerShortText: centerShortText, reduceMotion: reduceMotion)
        let baseline = (size.height - ascent - descent) / 2 + descent
        context.saveGState()
        context.clip(to: CGRect(origin: .zero, size: size))
        context.translateBy(x: x, y: 0)
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: 0, y: baseline)
        context.setFillColor(NSColor.white.cgColor)
        CTLineDraw(line, context)
        let rects: [CGRect]
        if lyric.timing == .sentence {
            // Only genuine sentence-timed lyrics use whole-line emphasis.
            // Missing/malformed word annotations never become a fake sentence
            // clock: their unknown glyphs remain white.
            rects = time.isFinite && time >= lyric.time ? [CGRect(x: 0, y: 0, width: max(width, 1), height: size.height)] : []
        } else { rects = highlightRects(words: lyric.words, time: time, height: size.height) }
        if !rects.isEmpty {
            context.clip(to: rects)
            context.textPosition = CGPoint(x: 0, y: baseline)
            context.setBlendMode(.sourceAtop)
            context.setFillColor(highlight.cgColor)
            CTLineDraw(line, context)
        }
        context.restoreGState()
    }
}

struct KaraokeLyricText: NSViewRepresentable {
    let lyric: LyricLine
    let time: Double
    var fontSize: CGFloat = 13
    var weight: Font.Weight = .medium
    var highlight: Color
    var centerShortText = true
    var playbackClock: (() -> Double?)? = nil
    var lineAtTime: ((Double) -> LyricLine?)? = nil
    var playing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> KaraokeLyricNativeView { KaraokeLyricNativeView() }
    func updateNSView(_ view: KaraokeLyricNativeView, context: Context) {
        let nativeWeight: NSFont.Weight = weight == .bold ? .bold : weight == .semibold ? .semibold : weight == .regular ? .regular : .medium
        view.update(lyric: lyric, time: time, font: .systemFont(ofSize: fontSize, weight: nativeWeight),
                    highlight: NSColor(highlight), centerShortText: centerShortText, reduceMotion: reduceMotion,
                    playbackClock: playbackClock, lineAtTime: lineAtTime, playing: playing)
    }
    static func dismantleNSView(_ view: KaraokeLyricNativeView, coordinator: ()) { view.stopAnimating() }
}

final class KaraokeLyricNativeView: NSView {
    private var layout: KaraokeTextLayout?
    private var font: NSFont?
    private var fallbackLyric = LyricLine(id: 0, time: .infinity, text: "")
    private var displayedLyric = LyricLine(id: 0, time: .infinity, text: "")
    private var staticTime = Double.nan
    private var renderTime = Double.nan
    private var began = ProcessInfo.processInfo.systemUptime
    private var highlight = NSColor.systemPink
    private var centerShortText = true
    private var reduceMotion = false
    private var playbackClock: (() -> Double?)?
    private var lineAtTime: ((Double) -> LyricLine?)?
    private var playing = false
    private var timer: Timer?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    func update(lyric: LyricLine, time: Double, font: NSFont, highlight: NSColor,
                centerShortText: Bool, reduceMotion: Bool, playbackClock: (() -> Double?)? = nil,
                lineAtTime: ((Double) -> LyricLine?)? = nil, playing: Bool = false) {
        if self.font != font { layout = nil; self.font = font }
        fallbackLyric = lyric; staticTime = time; self.highlight = highlight
        self.centerShortText = centerShortText; self.reduceMotion = reduceMotion
        self.playbackClock = playbackClock; self.lineAtTime = lineAtTime; self.playing = playing
        refreshPlaybackFrame()
        configureAnimation()
    }

    /// Rendering stays inside this small native view. Source/UI observations
    /// retain their existing cadence; a word frame never relayouts SwiftUI.
    func refreshPlaybackFrame() {
        let nextTime: Double
        if let playbackClock { nextTime = playbackClock() ?? .nan }
        else { nextTime = staticTime }
        let nextLyric = nextTime.isFinite && nextTime >= 0 ? (lineAtTime?(nextTime) ?? fallbackLyric) : fallbackLyric
        if layout?.text != nextLyric.text || layout == nil {
            guard let font else { return }
            layout = KaraokeTextLayout(text: nextLyric.text, font: font)
            began = ProcessInfo.processInfo.systemUptime
        } else if displayedLyric.id != nextLyric.id || displayedLyric.time != nextLyric.time {
            began = ProcessInfo.processInfo.systemUptime
        }
        if displayedLyric.text != nextLyric.text {
            setAccessibilityElement(true)
            setAccessibilityRole(.staticText)
            setAccessibilityLabel(nextLyric.text)
        }
        displayedLyric = nextLyric; renderTime = nextTime
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureAnimation()
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { stopAnimating() }
        super.viewWillMove(toWindow: newWindow)
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        configureAnimation()
    }
    private func configureAnimation() {
        let scrolls = !reduceMotion && (layout?.width ?? 0) > bounds.width
        guard window != nil, playing || scrolls else { stopAnimating(); return }
        guard timer == nil else { return }
        let value = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.window?.isVisible == true, !self.isHiddenOrHasHiddenAncestor else { return }
                self.refreshPlaybackFrame()
            }
        }
        value.tolerance = 0.002
        RunLoop.main.add(value, forMode: .common)
        timer = value
    }
    func stopAnimating() { timer?.invalidate(); timer = nil }
    deinit { timer?.invalidate() }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, let layout else { return }
        layout.draw(in: context, size: bounds.size, lyric: displayedLyric, time: renderTime,
                    elapsed: ProcessInfo.processInfo.systemUptime - began, highlight: highlight,
                    centerShortText: centerShortText, reduceMotion: reduceMotion)
    }
}
