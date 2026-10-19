import Foundation

func runTimedLyricsEnrichmentTests() -> [String] {
    var failures: [String] = []
    func check(_ condition: Bool, _ message: String) {
        if !condition { failures.append("Timed lyric enrichment: " + message) }
    }
    let texts = ["First synthetic sunrise", "Another quiet morning", "These letters travel further", "Last synthetic evening"]
    func fixture(_ text: [String] = texts, offset: Double = 0.1) -> (original: [LyricLine], candidate: [LyricLine]) {
        let original = text.enumerated().map { index, text in
            LyricLine(id: index + 50, time: Double(index * 2 + 1) + offset, text: text,
                      translation: "Translation \(index)", endTime: Double(index * 2 + 3) + offset)
        }
        let candidate = text.enumerated().map { index, text in
            LyricLine(id: index, time: Double(index * 2 + 1), text: text, endTime: Double(index * 2 + 2),
                      words: [LyricWord(utf16Location: 0, utf16Length: text.utf16.count,
                                       startTime: Double(index * 2 + 1), duration: 1)])
        }
        return (original, candidate)
    }
    let normal = fixture()
    let enriched = TimedLyricsEnrichment.enrich(authoritative: normal.original, candidate: normal.candidate, duration: 10)
    check(enriched?.count == 4 && enriched?.allSatisfy({ $0.words.count == 1 }) == true, "a coherent recording transfers real word clocks")
    check(abs((enriched?.first?.words.first?.startTime ?? 0) - 1.1) < 0.000_001 && enriched?.first?.words.first?.duration == 1,
          "one global offset changes starts while preserving source durations")
    check(zip(enriched ?? [], normal.original).allSatisfy { lhs, rhs in
        lhs.id == rhs.id && lhs.time == rhs.time && lhs.endTime == rhs.endTime && lhs.text == rhs.text && lhs.translation == rhs.translation
    }, "authoritative text, translation, identity, and sentence timeline survive")

    let decorated = normal.original.enumerated().map { index, line in
        LyricLine(id: line.id, time: line.time, text: "  " + line.text.uppercased().replacingOccurrences(of: " ", with: "， ") + "!",
                  translation: line.translation, endTime: line.endTime)
    }
    let remapped = TimedLyricsEnrichment.enrich(authoritative: decorated, candidate: normal.candidate, duration: 10)
    check(remapped?.first?.words.first?.utf16Location == 2 && remapped?.first?.words.first?.utf16Length == decorated[0].text.utf16.count - 3,
          "punctuation, spaces, and case remap ranges without replacing displayed text")
    var partial = normal.candidate
    partial[1] = LyricLine(id: 1, time: 3, text: texts[1], endTime: 4, timing: .wordAnnotated)
    let unknown = TimedLyricsEnrichment.enrich(authoritative: normal.original, candidate: partial, duration: 10)
    check(unknown == nil, "fewer than four independent timed anchors cannot establish a whole-song clock")

    var drift = normal.candidate
    drift[2] = LyricLine(id: 2, time: 5.8, text: texts[2], endTime: 6.8,
                        words: [LyricWord(utf16Location: 0, utf16Length: texts[2].utf16.count, startTime: 5.8, duration: 1)])
    check(TimedLyricsEnrichment.enrich(authoritative: normal.original, candidate: drift, duration: 10) == nil,
          "local timing drift is rejected instead of repaired through per-line warping")
    let large = fixture(offset: 2.1)
    check(TimedLyricsEnrichment.enrich(authoritative: large.original, candidate: large.candidate, duration: 12) == nil,
          "large recording offsets cannot be mistaken for the same timeline")
    var reordered = normal.candidate
    reordered[1] = LyricLine(id: 1, time: 3, text: texts[2], endTime: 4,
                            words: [LyricWord(utf16Location: 0, utf16Length: texts[2].utf16.count, startTime: 3, duration: 1)])
    reordered[2] = LyricLine(id: 2, time: 5, text: texts[1], endTime: 6,
                            words: [LyricWord(utf16Location: 0, utf16Length: texts[1].utf16.count, startTime: 5, duration: 1)])
    check(TimedLyricsEnrichment.enrich(authoritative: normal.original, candidate: reordered, duration: 10) == nil,
          "a reordered verse cannot transfer timings even when every text appears")
    let unrelated = fixture(["Entirely unrelated content", "Nothing matches the original", "A completely different verse", "Another recording ends here"])
    check(TimedLyricsEnrichment.enrich(authoritative: normal.original, candidate: unrelated.candidate, duration: 10) == nil,
          "metadata similarity cannot substitute for matching lyric content")

    let manyTexts = (0..<12).map { "Synthetic numbered phrase \($0) extends" }
    let many = fixture(manyTexts)
    var differing = many.candidate
    differing[5] = LyricLine(id: 5, time: 11, text: "A single uncertain wording remains readable", endTime: 12,
                            words: [LyricWord(utf16Location: 0, utf16Length: "A single uncertain wording remains readable".utf16.count, startTime: 11, duration: 1)])
    let preserved = TimedLyricsEnrichment.enrich(authoritative: many.original, candidate: differing, duration: 26)
    check(preserved?.count == 12 && preserved?[5].text == manyTexts[5] && preserved?[5].words.isEmpty == true
          && preserved?[5].timing == .wordAnnotated && preserved?[6].words.count == 1,
          "small interior wording differences remain white while independently verified neighboring words continue")
    var credits = many.candidate
    credits.insert(LyricLine(id: -1, time: 0, text: "Different synthetic production metadata", endTime: 0.5,
                            words: [LyricWord(utf16Location: 0, utf16Length: "Different synthetic production metadata".utf16.count, startTime: 0, duration: 0.5)]), at: 0)
    credits.append(LyricLine(id: 99, time: 25, text: "Unmatched synthetic end credits", endTime: 26, timing: .wordAnnotated))
    check(TimedLyricsEnrichment.enrich(authoritative: many.original, candidate: credits, duration: 26) != nil,
          "edge production metadata is excluded by position outside sung anchors, without keyword lists")
    var extraVerse = credits
    extraVerse[0] = LyricLine(id: -1, time: 0, text: "Different synthetic production metadata", endTime: 1.5,
                             words: [LyricWord(utf16Location: 0, utf16Length: "Different synthetic production metadata".utf16.count, startTime: 0, duration: 1.5)])
    check(TimedLyricsEnrichment.enrich(authoritative: many.original, candidate: extraVerse, duration: 26) == nil,
          "substantial sung material outside matching anchors cannot be discarded as credits")
    var repeatSwap = many.candidate
    repeatSwap[4] = LyricLine(id: 4, time: 9, text: manyTexts[5], endTime: 10,
                             words: [LyricWord(utf16Location: 0, utf16Length: manyTexts[5].utf16.count, startTime: 9, duration: 1)])
    repeatSwap[5] = LyricLine(id: 5, time: 11, text: manyTexts[4], endTime: 12,
                             words: [LyricWord(utf16Location: 0, utf16Length: manyTexts[4].utf16.count, startTime: 11, duration: 1)])
    check(TimedLyricsEnrichment.enrich(authoritative: many.original, candidate: repeatSwap, duration: 26) == nil,
          "even a high-coverage body rejects reordered rows rather than dropping them")
    var partialMany = many.candidate
    let missingPrefix = "Synthetic ".utf16.count
    partialMany[3] = LyricLine(id: 3, time: 7, text: manyTexts[3], endTime: 8,
                              words: [LyricWord(utf16Location: missingPrefix, utf16Length: manyTexts[3].utf16.count - missingPrefix,
                                               startTime: 7.4, duration: 0.6)])
    partialMany[6] = LyricLine(id: 6, time: 13, text: manyTexts[6], endTime: 14, timing: .wordAnnotated)
    let partialWords = TimedLyricsEnrichment.enrich(authoritative: many.original, candidate: partialMany, duration: 26)
    check(partialWords?[3].words.first?.utf16Location == missingPrefix
          && partialWords?[6].words.isEmpty == true && partialWords?[6].timing == .wordAnnotated,
          "untimed lead-ins and all-unknown rows remain white without filling gaps or inventing durations")
    let unicodeTexts = ["你好 👩🏽‍💻 café synthetic", "第二句话 עִברִית text", "Third élan 👨‍👩‍👧‍👦 example", "最后一行 synthetic evening"]
    let unicodeFixture = fixture(unicodeTexts)
    let unicodeOutput = TimedLyricsEnrichment.enrich(authoritative: unicodeFixture.original, candidate: unicodeFixture.candidate, duration: 10)
    check(unicodeOutput?.allSatisfy({ $0.words.first?.utf16Length == $0.text.utf16.count }) == true,
          "Chinese, bidirectional text, combining marks, and emoji remain complete UTF-16 grapheme ranges")
    var brokenGrapheme = unicodeFixture.candidate
    let emojiStart = (unicodeTexts[0] as NSString).range(of: "👩🏽‍💻").location
    brokenGrapheme[0] = LyricLine(id: 0, time: 1, text: unicodeTexts[0], endTime: 2,
                                words: [LyricWord(utf16Location: emojiStart, utf16Length: 1, startTime: 1, duration: 1)])
    check(TimedLyricsEnrichment.enrich(authoritative: unicodeFixture.original, candidate: brokenGrapheme, duration: 10) == nil,
          "a range that splits a surrogate/grapheme is discarded before it can establish an anchor")
    var malformedEnvelope = normal.candidate
    malformedEnvelope[3] = LyricLine(id: 3, time: 7, text: texts[3], endTime: 17,
                                   words: [LyricWord(utf16Location: 0, utf16Length: texts[3].utf16.count, startTime: 7, duration: 1)])
    let envelope = TimedLyricsEnrichment.enrich(authoritative: normal.original, candidate: malformedEnvelope, duration: 10)
    check(envelope?.last?.words.first?.duration == 1 && envelope?.last?.endTime == normal.original.last?.endTime,
          "an oversized final provider header cannot change a valid word clock or the authoritative envelope")
    malformedEnvelope[3] = LyricLine(id: 3, time: 7, text: texts[3], endTime: 17,
                                   words: [LyricWord(utf16Location: 0, utf16Length: texts[3].utf16.count, startTime: 7, duration: 5)])
    let beyondTrack = TimedLyricsEnrichment.enrich(authoritative: normal.original, candidate: malformedEnvelope, duration: 10)
    check(beyondTrack?.last?.words.isEmpty != false,
          "candidate header leniency never permits a transferred word to extend beyond the real recording")
    var outOfOrder = normal.candidate
    outOfOrder[3] = LyricLine(id: 3, time: 0.5, text: texts[3], endTime: 8, words: normal.candidate[3].words)
    check(TimedLyricsEnrichment.enrich(authoritative: normal.original, candidate: outOfOrder, duration: 10) == nil,
          "out-of-order provider rows are rejected before alignment")
    let repeated = fixture(Array(repeating: "Repeated identical synthetic phrase", count: 12))
    check(TimedLyricsEnrichment.enrich(authoritative: repeated.original, candidate: repeated.candidate, duration: 26) == nil,
          "one repeated phrase cannot establish recording identity")
    for invalid in [Double.nan, Double.infinity, -1, 0] {
        check(TimedLyricsEnrichment.enrich(authoritative: normal.original, candidate: normal.candidate, duration: invalid) == nil,
              "invalid recording duration is rejected")
    }
    check(TimedLyricsEnrichment.enrich(authoritative: enriched ?? [], candidate: normal.candidate, duration: 10) == nil,
          "existing authoritative word timings are never replaced")
    return failures
}
