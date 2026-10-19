import AppKit
import CoreText

func runKaraokeRenderingTests() -> [String] {
    var failures: [String] = []
    func check(_ value: Bool, _ label: String) { if !value { failures.append("Karaoke rendering: " + label) } }
    let text = "Hello 世界 🎵"
    let layout = KaraokeTextLayout(text: text, font: .systemFont(ofSize: 18, weight: .medium))
    let words = [LyricWord(utf16Location: 0, utf16Length: 5, startTime: 10, duration: 1),
                 LyricWord(utf16Location: 6, utf16Length: 2, startTime: 12, duration: 2),
                 LyricWord(utf16Location: 9, utf16Length: 2, startTime: 15, duration: 0)]
    let line = LyricLine(id: 0, time: 9, text: text, words: words)
    check(layout.highlightRects(words: words, time: 9.99, height: 30).isEmpty, "all unread glyphs remain white")
    let half = layout.highlightRects(words: words, time: 10.5, height: 30)
    let first = layout.highlightRects(words: words, time: 11, height: 30)
    check(half.count == 1 && first.count == 1 && abs(half[0].width * 2 - first[0].width) < 0.001, "fill follows the real word duration")
    check(layout.highlightRects(words: words, time: 11.8, height: 30) == first, "instrumental gap does not sweep the next word")
    check(layout.highlightRects(words: words, time: 15, height: 30).count == 3, "zero-duration token completes at its exact timestamp")
    check(layout.highlightRects(words: words, time: .nan, height: 30).isEmpty, "invalid playback clock never fills text")
    let invalid = [LyricWord(utf16Location: Int.max, utf16Length: 1, startTime: 0, duration: 1),
                   LyricWord(utf16Location: -1, utf16Length: 2, startTime: 0, duration: 1),
                   LyricWord(utf16Location: 0, utf16Length: Int.max, startTime: 0, duration: 1),
                   LyricWord(utf16Location: 0, utf16Length: 2, startTime: .nan, duration: 1)]
    check(layout.highlightRects(words: invalid, time: 10, height: 30).isEmpty, "malformed ranges cannot overflow or escape layout")

    let bidi = KaraokeTextLayout(text: "ABC אבג DEF", font: .systemFont(ofSize: 18, weight: .medium))
    let hebrew = [LyricWord(utf16Location: 4, utf16Length: 3, startTime: 0, duration: 1)]
    let hebrewHalf = bidi.highlightRects(words: hebrew, time: 0.5, height: 30)
    let hebrewFull = bidi.highlightRects(words: hebrew, time: 1, height: 30)
    var hebrewSecondary: CGFloat = 0
    let hebrewPrimary = CTLineGetOffsetForStringIndex(bidi.line, 4, &hebrewSecondary)
    let hebrewLeft = min(hebrewPrimary, hebrewSecondary), hebrewRight = max(hebrewPrimary, hebrewSecondary)
    check(hebrewFull.count == 1 && abs(hebrewFull[0].minX - hebrewLeft) < 0.001
          && abs(hebrewFull[0].maxX - hebrewRight) < 0.001,
          "mixed-line Hebrew word covers its full RTL run despite ambiguous primary boundary carets")
    check(hebrewHalf.count == 1 && hebrewFull.count == 1
          && abs(hebrewHalf[0].width * 2 - hebrewFull[0].width) < 0.001
          && abs(hebrewHalf[0].maxX - hebrewFull[0].maxX) < 0.001,
          "RTL half fill advances from the logical start at the right edge")
    let interiorHebrew = [LyricWord(utf16Location: 5, utf16Length: 1, startTime: 0, duration: 1)]
    let interiorFull = bidi.highlightRects(words: interiorHebrew, time: 1, height: 30)
    let interiorStart = CTLineGetOffsetForStringIndex(bidi.line, 5, nil)
    let interiorEnd = CTLineGetOffsetForStringIndex(bidi.line, 6, nil)
    check(interiorFull.count == 1 && abs(interiorFull[0].minX - min(interiorStart, interiorEnd)) < 0.001
          && abs(interiorFull[0].maxX - max(interiorStart, interiorEnd)) < 0.001,
          "partial RTL token uses its own internal caret positions")
    let rtlLine = KaraokeTextLayout(text: "אבג ABC דהו", font: .systemFont(ofSize: 18, weight: .medium))
    let latin = [LyricWord(utf16Location: 4, utf16Length: 3, startTime: 0, duration: 1)]
    let latinHalf = rtlLine.highlightRects(words: latin, time: 0.5, height: 30)
    let latinFull = rtlLine.highlightRects(words: latin, time: 1, height: 30)
    check(latinHalf.count == 1 && latinFull.count == 1
          && abs(latinHalf[0].width * 2 - latinFull[0].width) < 0.001
          && abs(latinHalf[0].minX - latinFull[0].minX) < 0.001,
          "embedded Latin in an RTL sentence fills left to right within its own run")
    let arabic = KaraokeTextLayout(text: "Hello العربية world", font: .systemFont(ofSize: 18, weight: .medium))
    let arabicWord = [LyricWord(utf16Location: 6, utf16Length: 7, startTime: 0, duration: 1)]
    let arabicHalf = arabic.highlightRects(words: arabicWord, time: 0.5, height: 30)
    let arabicFull = arabic.highlightRects(words: arabicWord, time: 1, height: 30)
    check(arabicHalf.count == 1 && arabicFull.count == 1
          && abs(arabicHalf[0].width * 2 - arabicFull[0].width) < 0.001
          && abs(arabicHalf[0].maxX - arabicFull[0].maxX) < 0.001,
          "joined Arabic text fills its existing shaped RTL glyphs without disappearing")
    let wholeMixedWord = [LyricWord(utf16Location: 0, utf16Length: 11, startTime: 0, duration: 1)]
    let mixedHalf = bidi.highlightRects(words: wholeMixedWord, time: 0.5, height: 30)
    let mixedFull = bidi.highlightRects(words: wholeMixedWord, time: 1, height: 30)
    check(mixedHalf.count == 2 && abs(mixedHalf.reduce(0) { $0 + $1.width } - bidi.width / 2) < 0.001
          && abs(mixedHalf[0].minX) < 0.001 && abs(mixedHalf[0].maxX - hebrewLeft) < 0.001
          && abs(mixedHalf[1].maxX - hebrewRight) < 0.001,
          "a token spanning mixed directions consumes run widths in logical order")
    check(mixedFull.count == 3 && abs(mixedFull.reduce(0) { $0 + $1.width } - bidi.width) < 0.001,
          "a completed token spanning several runs covers the full shared line exactly once")
    let spaceAfterRTL = [LyricWord(utf16Location: 7, utf16Length: 1, startTime: 0, duration: 1)]
    let spaceRects = bidi.highlightRects(words: spaceAfterRTL, time: 1, height: 30)
    let afterSpace = CTLineGetOffsetForStringIndex(bidi.line, 8, nil)
    check(spaceRects.count == 1 && abs(spaceRects[0].minX - hebrewRight) < 0.001
          && abs(spaceRects[0].maxX - afterSpace) < 0.001,
          "space after an RTL run does not accidentally fill the preceding word")
    check(KaraokeTextLayout.horizontalOffset(textWidth: 100, viewportWidth: 300, elapsed: 0,
                                            centerShortText: true, reduceMotion: false) == 100, "short line stays precisely centered")
    check(KaraokeTextLayout.horizontalOffset(textWidth: 100, viewportWidth: 300, elapsed: 0,
                                            centerShortText: false, reduceMotion: false) == 0, "player summary remains left aligned")
    check(KaraokeTextLayout.horizontalOffset(textWidth: 300, viewportWidth: 100, elapsed: 0,
                                            centerShortText: true, reduceMotion: false) == 0, "long line has the original opening pause")
    check(KaraokeTextLayout.horizontalOffset(textWidth: 300, viewportWidth: 100, elapsed: 5,
                                            centerShortText: true, reduceMotion: true) == 0, "reduce motion stops scrolling only")
    check(KaraokeTextLayout.horizontalOffset(textWidth: 300, viewportWidth: 100, elapsed: 2.5,
                                            centerShortText: true, reduceMotion: false) == -24, "white and fill use one 24-point-per-second scroll offset")

    func render(time: Double, color: NSColor, viewport: Int = 250, elapsed: Double = 0) -> [UInt8]? {
        guard let context = CGContext(data: nil, width: viewport, height: 32, bitsPerComponent: 8,
                                      bytesPerRow: viewport * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let pointer = context.data else { return nil }
        layout.draw(in: context, size: CGSize(width: viewport, height: 32), lyric: line, time: time,
                    elapsed: elapsed, highlight: color, centerShortText: true, reduceMotion: false)
        return Array(UnsafeBufferPointer(start: pointer.assumingMemoryBound(to: UInt8.self), count: viewport * 32 * 4))
    }
    if let before = render(time: 9, color: .systemPink), let after = render(time: 14, color: .systemPink),
       let blue = render(time: 14, color: .systemBlue) {
        let alphas = stride(from: 3, to: before.count, by: 4)
        check(alphas.allSatisfy { abs(Int(before[$0]) - Int(after[$0])) <= 1 }, "changing color preserves the shaped glyph coverage and exact position")
        check(before != after, "time changes actual drawn pixels")
        check(blue != after && blue != before, "selected color controls actual highlight pixels")
        let emojiStart = (250 - layout.width) / 2 + CTLineGetOffsetForStringIndex(layout.line, 9, nil) - 2
        var neutral = true
        for index in stride(from: 0, to: before.count, by: 4) {
            // Color emoji intentionally retain their native colors.
            if before[index + 3] <= 100 || CGFloat(index / 4 % 250) >= emojiStart { continue }
            let red = Int(before[index]), green = Int(before[index + 1]), blue = Int(before[index + 2])
            if abs(red - green) > 1 || abs(green - blue) > 1 { neutral = false }
        }
        check(neutral, "unread ordinary text is neutral white")
    } else { failures.append("Karaoke rendering: bitmap context unavailable") }
    if let clippedBefore = render(time: 9, color: .systemPink, viewport: 55, elapsed: 3),
       let clippedAfter = render(time: 14, color: .systemPink, viewport: 55, elapsed: 3) {
        check(stride(from: 3, to: clippedBefore.count, by: 4).allSatisfy {
            abs(Int(clippedBefore[$0]) - Int(clippedAfter[$0])) <= 1
        }, "narrow scrolling viewport preserves alignment of both color passes")
    }

    let partialText = "哦哦哦哦 A ? B 未知"
    let partialLayout = KaraokeTextLayout(text: partialText, font: .systemFont(ofSize: 18, weight: .medium))
    let partial = LyricLine(id: 30, time: 10, text: partialText, endTime: 18, words: [
        LyricWord(utf16Location: 5, utf16Length: 1, startTime: 12, duration: 1),
        LyricWord(utf16Location: 9, utf16Length: 1, startTime: 15, duration: 1)
    ], timing: .wordAnnotated)
    let unknown = LyricLine(id: 31, time: 10, text: partialText, endTime: 18, timing: .wordAnnotated)
    let sentence = LyricLine(id: 32, time: 10, text: partialText, endTime: 18)
    let fixtureWidth = 320, fixtureHeight = 36
    let selectedPink = NSColor(srgbRed: 1, green: 0, blue: 0.5, alpha: 1)
    func renderFixture(_ lyric: LyricLine, at time: Double) -> [UInt8]? {
        guard let context = CGContext(data: nil, width: fixtureWidth, height: fixtureHeight, bitsPerComponent: 8,
                                      bytesPerRow: fixtureWidth * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let pointer = context.data else { return nil }
        partialLayout.draw(in: context, size: CGSize(width: fixtureWidth, height: fixtureHeight), lyric: lyric,
                           time: time, elapsed: 0, highlight: selectedPink, centerShortText: false, reduceMotion: true)
        return Array(UnsafeBufferPointer(start: pointer.assumingMemoryBound(to: UInt8.self),
                                        count: fixtureWidth * fixtureHeight * 4))
    }
    func xOffset(_ index: Int) -> CGFloat { CTLineGetOffsetForStringIndex(partialLayout.line, index, nil) }
    func sameRegion(_ lhs: [UInt8], _ rhs: [UInt8], from lower: CGFloat, to upper: CGFloat) -> Bool {
        let start = max(0, Int(ceil(lower))), end = min(fixtureWidth, Int(floor(upper)))
        guard start < end else { return false }
        for y in 0..<fixtureHeight {
            for x in start..<end {
                let index = (y * fixtureWidth + x) * 4
                if lhs[index..<(index + 4)] != rhs[index..<(index + 4)] { return false }
            }
        }
        return true
    }
    func pinkPixels(_ pixels: [UInt8], from lower: CGFloat, to upper: CGFloat) -> Int {
        let start = max(0, Int(ceil(lower))), end = min(fixtureWidth, Int(floor(upper)))
        guard start < end else { return 0 }
        var count = 0
        for y in 0..<fixtureHeight {
            for x in start..<end {
                let index = (y * fixtureWidth + x) * 4
                if pixels[index + 3] > 100 && Int(pixels[index]) > Int(pixels[index + 1]) + 24 { count += 1 }
            }
        }
        return count
    }
    if let white = renderFixture(unknown, at: .nan), let emptyLate = renderFixture(unknown, at: 100),
       let beforeKnown = renderFixture(partial, at: 11.5), let firstKnown = renderFixture(partial, at: 13.1),
       let gap = renderFixture(partial, at: 14.9), let complete = renderFixture(partial, at: 16),
       let completeLate = renderFixture(partial, at: 100), let earlier = renderFixture(partial, at: 12.25),
       let sentenceStart = renderFixture(sentence, at: 10), let sentenceBefore = renderFixture(sentence, at: 9.9) {
        check(emptyLate == white, "QRC provenance with no usable word spans remains white even long after line start")
        check(beforeKnown == white, "untimed vocal lead-in cannot trigger a sentence-wide pink flash")
        check(firstKnown == gap, "a provider rest holds only completed known spans without sweeping unknown text")
        check(complete == completeLate, "holding a partial QRC line after its end does not fill unknown spans")
        check(earlier != firstKnown && renderFixture(partial, at: 11.5) == white,
              "backward seek reverses actual word fill and restores pre-word white text")
        check(pinkPixels(firstKnown, from: xOffset(5), to: xOffset(6)) > 0,
              "the valid word following an untimed vocal prefix actually renders selected pink pixels")
        check(sameRegion(firstKnown, white, from: xOffset(9), to: xOffset(10)),
              "a future valid word remains white during an earlier word's completed fill")
        check(pinkPixels(complete, from: xOffset(9), to: xOffset(10)) > 0,
              "a valid word after an unknown middle token still receives its own source-timed pink fill")
        let unknownRegions = [(CGFloat.zero, xOffset(4) - 1),
                              (xOffset(7) + 1, xOffset(8) - 1),
                              (xOffset(11) + 1, partialLayout.width - 1)]
        for (lower, upper) in unknownRegions {
            check(sameRegion(firstKnown, white, from: lower, to: upper)
                  && sameRegion(complete, white, from: lower, to: upper),
                  "untimed prefix, malformed middle token and untimed suffix stay pixel-identical to neutral white")
            check(pinkPixels(sentenceStart, from: lower, to: upper) > 0,
                  "true sentence-only LRC retains whole-line pink emphasis at the exact line start")
        }
        check(sentenceBefore == white && sentenceStart != white,
              "sentence provenance preserves its existing before/at-start highlighting boundary")
    } else { failures.append("Karaoke rendering: bitmap context unavailable for partial timing checks") }
    return failures
}
