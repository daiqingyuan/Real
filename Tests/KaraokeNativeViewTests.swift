import AppKit
import Foundation

@MainActor
func runKaraokeNativeViewTests() -> [String] {
    var failures: [String] = []
    func check(_ condition: Bool, _ message: String) {
        if !condition { failures.append("Karaoke native view: " + message) }
    }
    let frame = NSRect(x: 0, y: 0, width: 320, height: 40)
    let font = NSFont.systemFont(ofSize: 18, weight: .medium)
    let fallback = LyricLine(id: -1, time: .infinity, text: "Track · Artist")
    let first = LyricLine(id: 1, time: 10, text: "First", words: [
        LyricWord(utf16Location: 0, utf16Length: 5, startTime: 10, duration: 0.1)
    ])
    let second = LyricLine(id: 2, time: 10.12, text: "Next", words: [
        LyricWord(utf16Location: 0, utf16Length: 4, startTime: 10.12, duration: 0.5)
    ])
    var lines = [first, second]
    var clock: Double? = 10.05
    var clockReads = 0
    var selectedTimes: [Double] = []
    let playbackClock: () -> Double? = { clockReads += 1; return clock }
    let lineAtTime: (Double) -> LyricLine? = { time in
        selectedTimes.append(time)
        return LyricDisplayPolicy.line(in: lines, at: time)
    }
    let view = KaraokeLyricNativeView(frame: frame)
    defer { view.stopAnimating() }

    func update(font nextFont: NSFont = font, color: NSColor = .systemPink, playing: Bool = true) {
        // The deliberately unrelated static time catches accidental fallback to
        // the parent's slower published position during a style update.
        view.update(lyric: fallback, time: -100, font: nextFont, highlight: color,
                    centerShortText: false, reduceMotion: true,
                    playbackClock: playbackClock, lineAtTime: lineAtTime, playing: playing)
    }
    func pixels(of target: KaraokeLyricNativeView) -> [UInt8]? {
        let width = Int(frame.width), height = Int(frame.height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                        | CGBitmapInfo.byteOrder32Big.rawValue),
              let data = context.data else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        target.draw(target.bounds)
        NSGraphicsContext.restoreGraphicsState()
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self),
                                        count: width * height * 4))
    }
    func expectedPixels(line: LyricLine, time: Double, font nextFont: NSFont = font,
                        color: NSColor = .systemPink) -> [UInt8]? {
        let expected = KaraokeLyricNativeView(frame: frame)
        expected.update(lyric: line, time: time, font: nextFont, highlight: color,
                        centerShortText: false, reduceMotion: true)
        defer { expected.stopAnimating() }
        return pixels(of: expected)
    }
    func matches(_ actual: [UInt8]?, _ expected: [UInt8]?) -> Bool {
        guard let actual, let expected else { return false }
        return actual == expected
    }

    update()
    check(view.accessibilityLabel() == "First", "initial injected clock selects a lyric instead of metadata")
    check(clockReads == 1 && selectedTimes.count == 1, "parent update reads the render clock once")
    check(matches(pixels(of: view), expectedPixels(line: first, time: 10.05)),
          "initial frame uses the injected word position instead of the static parent time")

    clock = 10.13
    view.refreshPlaybackFrame()
    check(view.accessibilityLabel() == "Next", "native frame advances to the next line between 0.2-second parent updates")
    check(clockReads == 2 && selectedTimes.last == 10.13, "each native frame independently reads clock and selects its line")
    check(matches(pixels(of: view), expectedPixels(line: second, time: 10.13)),
          "line transition also renders the new line's precise word timing")

    clock = 10.03
    view.refreshPlaybackFrame()
    check(view.accessibilityLabel() == "First", "backward seek immediately reselects the earlier line")
    check(matches(pixels(of: view), expectedPixels(line: first, time: 10.03)),
          "backward seek removes completed fill instead of retaining a later frame's color")

    clock = 10.04
    update(playing: false)
    let frozen = pixels(of: view)
    for _ in 0..<4 { view.refreshPlaybackFrame() }
    check(view.accessibilityLabel() == "First" && matches(pixels(of: view), frozen),
          "paused clock keeps the exact lyric and pixel fill through repeated native frames")

    let selectionsBeforeInvalidClock = selectedTimes.count
    clock = nil
    view.refreshPlaybackFrame()
    check(view.accessibilityLabel() == fallback.text, "missing trusted clock replaces the lyric with metadata")
    check(selectedTimes.count == selectionsBeforeInvalidClock, "missing clock cannot invoke lyric selection with a stale finite position")
    check(matches(pixels(of: view), expectedPixels(line: fallback, time: .nan)),
          "invalid-clock metadata is neutral text without fabricated word fill")
    for invalid in [Double.nan, Double.infinity, -Double.infinity, -1] {
        clock = invalid
        view.refreshPlaybackFrame()
        check(view.accessibilityLabel() == fallback.text, "nonfinite or negative playback clock selects metadata safely")
        check(selectedTimes.count == selectionsBeforeInvalidClock, "invalid clock never reaches the lyric selector")
    }
    clock = 9.99
    view.refreshPlaybackFrame()
    check(view.accessibilityLabel() == fallback.text, "time before the first lyric keeps metadata visible")

    let repeatedFirst = LyricLine(id: 10, time: 20, text: "Repeat", words: [
        LyricWord(utf16Location: 0, utf16Length: 6, startTime: 20, duration: 1)
    ])
    let repeatedSecond = LyricLine(id: 11, time: 22, text: "Repeat", words: [
        LyricWord(utf16Location: 0, utf16Length: 6, startTime: 22, duration: 1)
    ])
    lines = [repeatedFirst, repeatedSecond]
    clock = 20.9
    view.refreshPlaybackFrame()
    check(matches(pixels(of: view), expectedPixels(line: repeatedFirst, time: 20.9)),
          "current source lines are read through the retained selector closure")
    clock = 22.1
    view.refreshPlaybackFrame()
    let repeatedPixels = pixels(of: view)
    check(view.accessibilityLabel() == "Repeat"
          && matches(repeatedPixels, expectedPixels(line: repeatedSecond, time: 22.1)),
          "identical text with a new line ID receives its new singing event's timing")
    if let repeatedPixels, let obsolete = expectedPixels(line: repeatedFirst, time: 22.1) {
        check(repeatedPixels != obsolete, "identical text cannot retain the previous event's completed fill")
    } else { failures.append("Karaoke native view: bitmap context unavailable for repeated-line check") }

    let unicodeText = "你e\u{301} 👩‍🚀 אבג"
    let unicode = LyricLine(id: 20, time: 30, text: unicodeText, words: [
        LyricWord(utf16Location: 0, utf16Length: unicodeText.utf16.count, startTime: 30, duration: 2)
    ])
    lines = [unicode]
    clock = 30.5
    view.refreshPlaybackFrame()
    check(view.accessibilityLabel() == unicodeText, "mixed Unicode, combining marks, emoji and RTL preserve exact source text")
    check(matches(pixels(of: view), expectedPixels(line: unicode, time: 30.5)),
          "native frame preserves UTF-16 timing ranges and the shared shaped Unicode line")

    let largerFont = NSFont.systemFont(ofSize: 22, weight: .bold)
    clock = 30.7
    update(font: largerFont, color: .systemBlue)
    check(view.accessibilityLabel() == unicodeText
          && matches(pixels(of: view), expectedPixels(line: unicode, time: 30.7,
                                                    font: largerFont, color: .systemBlue)),
          "font and selected-color changes retain live playback selection and timing")
    clock = 31
    update(font: largerFont, color: .systemPink)
    check(matches(pixels(of: view), expectedPixels(line: unicode, time: 31,
                                                font: largerFont, color: .systemPink)),
          "color-only update uses the current injected clock without resetting fill to parent time")

    check(view.hitTest(.zero) == nil && view.hitTest(NSPoint(x: 50, y: 20)) == nil,
          "native lyric view remains transparent to parent controls and pointer interaction")
    check(!view.isOpaque, "native lyric view preserves transparent compositing")
    view.stopAnimating()
    view.stopAnimating()
    clock = 30.8
    view.refreshPlaybackFrame()
    check(matches(pixels(of: view), expectedPixels(line: unicode, time: 30.8,
                                                font: largerFont, color: .systemPink)),
          "stopping animation is idempotent and does not discard the retained source clock")

    let partialText = "哦哦哦哦 A ? B 未知"
    let partial = LyricLine(id: 40, time: 40, text: partialText, words: [
        LyricWord(utf16Location: 5, utf16Length: 1, startTime: 42, duration: 1),
        LyricWord(utf16Location: 9, utf16Length: 1, startTime: 45, duration: 1)
    ], timing: .wordAnnotated)
    let allUnknown = LyricLine(id: partial.id, time: partial.time, text: partialText, timing: .wordAnnotated)
    let sentence = LyricLine(id: partial.id, time: partial.time, text: partialText)
    let replayCache = ["partial": [partial], "unknown": [allUnknown], "sentence": [sentence]]
    lines = replayCache["partial"]!
    clock = 43.2
    update(playing: false)
    let partialPause = pixels(of: view)
    for _ in 0..<3 { view.refreshPlaybackFrame() }
    check(matches(pixels(of: view), partialPause)
          && matches(partialPause, expectedPixels(line: partial, time: 43.2)),
          "paused partial QRC freezes valid fill while keeping untimed ad-lib and unknown ranges neutral")

    lines = replayCache["unknown"]!
    view.refreshPlaybackFrame()
    let unknownPixels = pixels(of: view)
    check(view.accessibilityLabel() == partialText
          && matches(unknownPixels, expectedPixels(line: allUnknown, time: .nan)),
          "cached QRC with identical text/ID and no valid spans keeps explicit word provenance and renders white")
    lines = replayCache["sentence"]!
    view.refreshPlaybackFrame()
    let sentencePixels = pixels(of: view)
    check(matches(sentencePixels, expectedPixels(line: sentence, time: 43.2)),
          "cached true LRC with identical text/ID still receives sentence-level highlighting")
    if let unknownPixels, let sentencePixels {
        check(unknownPixels != sentencePixels, "source replay cannot infer sentence provenance from an empty word array")
    } else { failures.append("Karaoke native view: bitmap context unavailable for provenance replay") }
    lines = replayCache["partial"]!
    view.refreshPlaybackFrame()
    check(matches(pixels(of: view), partialPause),
          "returning to cached partial word timing restores its exact known spans without stale sentence fill")

    let repeatedPartial = LyricLine(id: 41, time: 44, text: partialText, words: [
        LyricWord(utf16Location: 5, utf16Length: 1, startTime: 46, duration: 1),
        LyricWord(utf16Location: 9, utf16Length: 1, startTime: 48, duration: 1)
    ], timing: .wordAnnotated)
    lines = [partial, repeatedPartial]
    clock = 44.1
    view.refreshPlaybackFrame()
    check(matches(pixels(of: view), expectedPixels(line: allUnknown, time: .nan)),
          "repeated partial line with identical text and a new ID starts white before its own first timed word")
    clock = 46.5
    view.refreshPlaybackFrame()
    check(matches(pixels(of: view), expectedPixels(line: repeatedPartial, time: 46.5)),
          "repeated partial line selects its own later word event without coloring the unknown prefix")
    clock = 40.5
    view.refreshPlaybackFrame()
    check(matches(pixels(of: view), expectedPixels(line: allUnknown, time: .nan)),
          "backward seek out of completed partial words restores a white untimed vocal lead-in")
    clock = nil
    view.refreshPlaybackFrame()
    check(view.accessibilityLabel() == fallback.text,
          "a missing clock after partial-word playback still falls back to track metadata")
    return failures
}
