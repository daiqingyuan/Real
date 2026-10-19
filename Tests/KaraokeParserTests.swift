import Foundation

func runKaraokeParserTests() -> [String] {
    var failures: [String] = []
    func expect(_ condition: @autoclosure () -> Bool, _ description: String) {
        if !condition() { failures.append(description) }
    }
    func line(_ source: String) -> LyricLine? {
        QQMusicQRCParser.parse(qrcContent: source).lines.first
    }
    func spans(_ line: LyricLine?) -> [String] {
        guard let line else { return [] }
        let text = line.text as NSString
        return line.words.map { text.substring(with: $0.range) }
    }

    let timed = line("[1000,3000]你(1000,300)好(1800,600)！(2500,200)")
    expect(timed?.text == "你好！", "QRC trailing timestamps belong to the text immediately before them")
    expect(timed?.words == [LyricWord(utf16Location: 0, utf16Length: 1, startTime: 1, duration: 0.3),
                           LyricWord(utf16Location: 1, utf16Length: 1, startTime: 1.8, duration: 0.6),
                           LyricWord(utf16Location: 2, utf16Length: 1, startTime: 2.5, duration: 0.2)],
        "QRC retains absolute word start times, durations and punctuation ranges")
    expect(timed?.words.dropFirst().first?.startTime == 1.8 && timed?.words.first?.duration == 0.3,
        "Provider pauses are preserved instead of spreading words evenly over a line")
    expect(timed?.time == 1 && timed?.endTime == 4, "Word timings retain the provider's line metadata")
    expect(timed?.timing == .wordAnnotated, "Provider-timed words infer explicit word annotation provenance")

    let family = "👨‍👩‍👧‍👦"
    let accented = "e\u{301}"
    let mixed = line("[1000,3000] \t\(family)(1000,500) 中\(accented)(1800,500)  hello, world!(2400,600)  \r\n")
    expect(mixed?.text == "\(family) 中\(accented)  hello, world!",
        "Edge trimming preserves internal English spacing, CJK, emoji and combining marks")
    expect(spans(mixed) == [family, " 中\(accented)", "  hello, world!"],
        "Word ranges use displayed UTF-16 offsets after trimming, without splitting graphemes")
    expect(mixed?.words.dropFirst().first?.utf16Location == family.utf16.count,
        "A multi-scalar emoji occupies its actual UTF-16 range rather than one character")
    expect(mixed?.words.last.map { NSMaxRange($0.range) } == mixed?.text.utf16.count,
        "Final word ranges exclude trimmed trailing whitespace")
    let edgeSegments = line("[1000,2000]  (1000,100)A(1200,200)  (1500,100)")
    expect(edgeSegments?.text == "A" && spans(edgeSegments) == ["A"],
        "Whitespace-only edge segments do not create empty displayed ranges")
    let parenthetical = line("[1000,3000](hello, world) & me(1000,1000)")
    expect(parenthetical?.text == "(hello, world) & me" && spans(parenthetical) == ["(hello, world) & me"],
        "Ordinary parenthetical lyric text and punctuation survive timing extraction")
    let punctuation = line("[1000,2000]A(1000,300) （(1300,0)中(1500,300)）(1800,0) (1800,0)B(2000,300)！(2300,0)")
    expect(punctuation?.text == "A （中） B！" && spans(punctuation) == ["A", " （", "中", "）", " ", "B", "！"],
        "Zero-duration provider punctuation and spaces preserve the sung-word timing around them")
    expect(punctuation?.words.map(\.duration) == [0.3, 0, 0.3, 0, 0, 0.3, 0],
        "Instantaneous punctuation retains exact source durations instead of receiving invented singing time")
    expect(punctuation?.words.map(\.startTime) == [1, 1.3, 1.5, 1.8, 1.8, 2, 2.3],
        "Instantaneous spans retain absolute source timestamps, including adjacent equal instants")
    let zeroEdgeSpaces = line("[1000,2000]  (1000,0)A(1200,200) \t(1500,0)")
    expect(zeroEdgeSpaces?.text == "A" && spans(zeroEdgeSpaces) == ["A"],
        "Invisible zero-duration edge whitespace is trimmed without invalidating readable sung words")

    if let timed {
        let translated = QQMusicQRCParser.applyTranslations([timed],
            translations: [LyricLine(id: 9, time: 1.2, text: "Hello!")]).first
        expect(translated?.words == timed.words && translated?.translation == "Hello!",
            "Applying a timestamp-matched translation preserves the complete timed word data")
        expect(translated?.id == timed.id && translated?.time == timed.time && translated?.endTime == timed.endTime,
            "Translation attachment preserves line identity and timing")
        let identical = QQMusicQRCParser.applyTranslations([timed],
            translations: [LyricLine(id: 0, time: 1, text: timed.text)]).first
        expect(identical?.translation == nil && identical?.words == timed.words,
            "Suppressing an identical translation still preserves timed words")
    } else {
        failures.append("Timed fixture was unexpectedly unavailable for translation checks")
    }

    let malformed: [(String, String, [String])] = [
        ("A(1000,0)B(1500,200)", "zero duration", ["B"]),
        ("A(1000,-200)B(1500,200)", "negative duration", ["B"]),
        ("A(-1000,200)B(1500,200)", "negative start", ["B"]),
        ("A(NaN,200)B(1500,200)", "nonfinite start", ["B"]),
        ("A(1000,Infinity)B(1500,200)", "nonfinite duration", ["B"]),
        ("A(1000,bad)B(1500,200)", "nonnumeric duration", ["B"]),
        ("A(bad,200)B(1500,200)", "nonnumeric start", ["B"]),
        ("A(1000.5,200)B(1500,200)", "fractional millisecond field", ["B"]),
        ("A(1000, 200)B(1500,200)", "malformed annotation whitespace", ["B"]),
        ("A(1500,200)B(1200,200)", "reversed word order", ["A"]),
        ("A(1000,700)B(1500,200)", "overlapping intervals", ["A"]),
        ("A(900,200)B(1500,200)", "word before the line", ["B"]),
        ("A(1000,200)B(2900,200)", "word past the line end", ["A"]),
        ("A(1000,9999999999999999999999999999999999999999)B(1500,200)", "unbounded duration", ["B"]),
        ("A(1000,200)B(9999999999999999999999999999999999999999,200)", "unbounded start", ["A"]),
        ("A(,200)B(1500,200)", "missing start", ["B"])
    ]
    for (source, description, expected) in malformed {
        let result = line("[1000,2000]" + source)
        expect(result?.text == "AB" && spans(result) == expected && result?.timing == .wordAnnotated,
            "Malformed \(description) leaves only its own span uncolored and preserves valid neighboring clocks")
    }
    for unsupported in ["A", "中", "7", "+", "🎵"] {
        let result = line("[1000,2000]\(unsupported)(1000,0)B(1500,200)")
        expect(result?.text == unsupported + "B" && spans(result) == ["B"],
            "Zero-duration sung text, numbers, symbols or emoji stay uncolored without discarding later good timing")
    }
    let zeroPunctuationBeforeLine = line("[1000,2000]（(900,0)A(1500,200)")
    expect(zeroPunctuationBeforeLine?.text == "（A" && spans(zeroPunctuationBeforeLine) == ["A"],
        "Out-of-line instantaneous punctuation cannot discard later in-line singing")
    let zeroPunctuationReversed = line("[1000,2000]A(1000,500)！(1200,0)B(1800,200)")
    expect(zeroPunctuationReversed?.text == "A！B" && spans(zeroPunctuationReversed) == ["A", "B"],
        "Reversed instantaneous punctuation is omitted without weakening nonoverlap for sung intervals")
    let zeroPunctuationPastLine = line("[1000,2000]A(1000,500)！(3100,0)")
    expect(zeroPunctuationPastLine?.text == "A！" && spans(zeroPunctuationPastLine) == ["A"],
        "Instantaneous punctuation past the line end leaves existing good words intact")
    let emptySegment = line("[1000,2000]A(1000,200)(1300,200)B(1600,200)")
    expect(emptySegment?.text == "AB" && spans(emptySegment) == ["A", "B"],
        "A timing marker without text cannot consume or invalidate readable neighboring ranges")
    let trailing = line("[1000,2000]A(1000,200) B")
    expect(trailing?.text == "A B" && spans(trailing) == ["A"] && trailing?.timing == .wordAnnotated,
        "Untimed trailing text stays readable outside timed ranges without receiving invented timing")
    let splitAccent = line("[1000,2000]e(1000,400)\u{301}(1500,300)")
    expect(splitAccent?.text == accented && splitAccent?.words.isEmpty == true,
        "Markers inside a combining grapheme preserve the grapheme and discard unusable timing")
    let splitEmoji = line("[1000,2000]👩(1000,400)\u{200D}🚀(1500,300)")
    expect(splitEmoji?.text == "👩‍🚀" && splitEmoji?.words.isEmpty == true,
        "Markers inside an emoji sequence never expose partial grapheme ranges")
    let splitWithGoodNeighbor = line("[1000,3000]e(2000,400)\u{301}(2400,300)B(1100,200)")
    expect(splitWithGoodNeighbor?.text == accented + "B" && spans(splitWithGoodNeighbor) == ["B"]
           && splitWithGoodNeighbor?.words.first?.startTime == 1.1,
        "Rejected grapheme fragments cannot advance the temporal watermark or discard a good neighboring word")
    let failedMiddle = line("[1000,3000]A(1000,300)X(3000,2000)B(1500,200)")
    expect(failedMiddle?.text == "AXB" && spans(failedMiddle) == ["A", "B"],
        "A rejected out-of-envelope span cannot consume the later valid word's source clock")
    let unknownIntro = line("[1000,3000]哦哦哦哦(1000,0)Hello(1600,500) world(2300,600)")
    expect(unknownIntro?.text == "哦哦哦哦Hello world" && spans(unknownIntro) == ["Hello", " world"]
           && unknownIntro?.words.first?.utf16Location == 4 && unknownIntro?.timing == .wordAnnotated,
        "Unclocked vocal text is preserved independently of the actual provider clocks for surrounding words")
    let allBad = line("[1000,3000]Intro(1000,0)body(NaN,400)tail")
    expect(allBad?.text == "Introbodytail" && allBad?.words.isEmpty == true && allBad?.timing == .wordAnnotated,
        "All-invalid QRC retains word provenance so it cannot become sentence-wide emphasis")
    if let allBad {
        let translated = QQMusicQRCParser.applyTranslations([allBad], translations: [LyricLine(id: 0, time: 1, text: "translation")]).first
        expect(translated?.timing == .wordAnnotated && translated?.words.isEmpty == true && translated?.translation == "translation",
            "Translation attachment preserves word provenance even when no span has a usable clock")
    }
    for overrun in [1, 2, 3] {
        let result = line("[1000,1000]A(1000,200)B(1800,\(200 + overrun))")
        let accepted = overrun <= 2
        expect(result?.text == "AB" && spans(result) == (accepted ? ["A", "B"] : ["A"]),
            "Only a one- or two-millisecond provider header-end rounding discrepancy is tolerated")
        expect(result?.endTime == (accepted ? Double(2000 + overrun) / 1000 : 2),
            "The line envelope expands only to an accepted final word end and never to a rejected clock")
        if accepted {
            expect(result?.words.last?.startTime == 1.8 && result?.words.last?.duration == Double(200 + overrun) / 1000,
                "Header tolerance retains exact source word start and duration without clipping or interpolation")
        }
    }
    let startsOutside = line("[1000,1000]A(1000,200)B(2001,1)")
    expect(spans(startsOutside) == ["A"] && startsOutside?.endTime == 2,
        "Header-end tolerance never admits a word whose start is already outside the original line")
    let repeated = QQMusicQRCParser.parse(qrcContent:
        "[1000,1000]Same(1000,500) text(1500,500)\n[4000,1000]Same(4000,500) text(4500,501)").lines
    expect(repeated.map(\.text) == ["Same text", "Same text"] && repeated.map { $0.words.count } == [2, 2]
           && repeated.map(\.endTime) == [2, 5.001],
        "An exact first chorus and a repeated chorus with one-millisecond header rounding both retain complete timing")
    let zeroLine = line("[1000,0]A(1000,0)")
    expect(zeroLine?.text == "A" && zeroLine?.endTime == 1 && zeroLine?.words.isEmpty == true,
        "A zero-duration line remains readable with no progressive timing")
    let beyondBound = line("[604800000,1000]A(604800000,1000)")
    expect(beyondBound?.text == "A" && beyondBound?.words.isEmpty == true,
        "Word times beyond the defensive seven-day bound preserve line-level fallback")

    let duplicate = QQMusicQRCParser.parse(qrcContent:
        "[2000,1000]Later(2000,500)\n[1000,500]First(1000,300)\n[1000,500]Second(1000,400)").lines
    expect(duplicate.map(\.text) == ["First", "Second", "Later"] && duplicate.map(\.id) == [0, 1, 2],
        "Repeated QRC line times keep stable ordering and unique identities")
    expect(duplicate.map { $0.words.first?.duration } == [0.3, 0.4, 0.5],
        "Sorting lines keeps each provider word interval attached to its own text")
    let plain = line("[ar:An artist]\n[1000,2000]  plain 中 English  \n")
    expect(plain?.text == "plain 中 English" && plain?.words.isEmpty == true && plain?.timing == .wordAnnotated,
        "QRC without usable tags preserves word provenance and readable text without sentence fallback")
    let lrc = QQMusicQRCParser.parse(qrcContent: "[00:01.00]line fallback", duration: 3).lines.first
    expect(lrc?.text == "line fallback" && lrc?.words.isEmpty == true && lrc?.endTime == 3 && lrc?.timing == .sentence,
        "Ordinary LRC fallback keeps its existing line timings and has no fabricated words")
    expect(LyricLine(id: 0, time: 0, text: "legacy initializer").words.isEmpty,
        "Existing line initializers remain source-compatible and default to line-only lyrics")
    expect(LyricLine(id: 0, time: 0, text: "legacy initializer").timing == .sentence
           && LyricLine(id: 0, time: 0, text: "unknown words", timing: .wordAnnotated).timing == .wordAnnotated,
        "An empty word array preserves explicit timing provenance and defaults ordinary legacy lines to sentence timing")
    let entity = line("[1000,2000]&#x1F3B5;(1000,200) &amp; 中(1500,400)")
    expect(entity?.text == "🎵 & 中" && spans(entity) == ["🎵", " & 中"],
        "XML entities are decoded before displayed UTF-16 ranges are calculated")
    return failures
}
