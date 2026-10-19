import Foundation

/// Adds an independently supplied word clock only after the two lyric bodies
/// agree in text, order, and time. Callers must first verify recording metadata.
/// A sentence timeline is never stretched to manufacture word timestamps.
enum TimedLyricsEnrichment {
    private struct Unit {
        let scalar: Unicode.Scalar
        let range: NSRange
    }
    private struct Row {
        let index: Int
        let key: String
        let units: [Unit]
    }
    private struct Match { let authoritative: Int; let candidate: Int }

    static func enrich(authoritative: [LyricLine], candidate: [LyricLine], duration: Double) -> [LyricLine]? {
        guard duration.isFinite, duration > 0, duration <= 604_800,
              !authoritative.contains(where: { !$0.words.isEmpty }),
              validTimeline(authoritative, duration: duration), validTimeline(candidate, duration: duration, candidateEnvelope: true),
              let originalRows = rows(authoritative), let timedRows = rows(candidate),
              originalRows.count >= 4, timedRows.count >= 4 else { return nil }
        let words = candidate.map(validWords)
        let allMatches = orderedMatches(originalRows, timedRows)
        let anchors = allMatches.filter { match in
            words[timedRows[match.candidate].index].contains { word in
                word.duration > 0 && meaningful(candidate[timedRows[match.candidate].index].text, range: word.range)
            }
        }
        guard anchors.count >= 4, let first = anchors.first, let last = anchors.last else { return nil }
        let originalWindow = first.authoritative...last.authoritative
        let timedWindow = first.candidate...last.candidate
        let bodyMatches = allMatches.filter { originalWindow.contains($0.authoritative) && timedWindow.contains($0.candidate) }
        let originalBody = originalRows[originalWindow]
        let timedBody = timedRows[timedWindow]
        let matchedOriginal = Set(bodyMatches.map(\.authoritative))
        let matchedTimed = Set(bodyMatches.map(\.candidate))
        let originalKeys = Set(originalBody.map(\.key))
        let timedKeys = Set(timedBody.map(\.key))
        // A skipped row that exists on the other side is an ordering/repetition
        // ambiguity, not a harmless spelling difference. Never guess its clock.
        guard originalWindow.allSatisfy({ matchedOriginal.contains($0) || !timedKeys.contains(originalRows[$0].key) }),
              timedWindow.allSatisfy({ matchedTimed.contains($0) || !originalKeys.contains(timedRows[$0].key) }),
              Double(bodyMatches.count) / Double(originalBody.count) >= 0.9,
              Double(bodyMatches.count) / Double(timedBody.count) >= 0.9 else { return nil }
        let originalUnits = originalBody.reduce(0) { $0 + $1.units.count }
        let timedUnits = timedBody.reduce(0) { $0 + $1.units.count }
        let matchedUnits = bodyMatches.reduce(0) { $0 + originalRows[$1.authoritative].units.count }
        guard matchedUnits >= 32,
              Double(matchedUnits) / Double(originalUnits) >= 0.9,
              Double(matchedUnits) / Double(timedUnits) >= 0.9,
              Set(anchors.map { originalRows[$0.authoritative].key }).count >= 3 else { return nil }

        let anchorTimes = anchors.map { authoritative[originalRows[$0.authoritative].index].time }
        guard let firstTime = anchorTimes.first, let lastTime = anchorTimes.last,
              firstTime <= duration * 0.35, lastTime >= duration * 0.5,
              lastTime - firstTime >= min(15, duration * 0.35) else { return nil }
        let offsets = anchors.map {
            authoritative[originalRows[$0.authoritative].index].time - candidate[timedRows[$0.candidate].index].time
        }.sorted()
        let middle = offsets.count / 2
        let offset = offsets.count.isMultiple(of: 2) ? (offsets[middle - 1] + offsets[middle]) / 2 : offsets[middle]
        guard abs(offset) <= 2, offsets.allSatisfy({ abs($0 - offset) <= 0.3 + 0.000_001 }) else { return nil }
        // Provider credits at the edges can have tiny generated spans. A verse
        // or chorus outside the agreed body cannot be silently called a credit.
        let exteriorDuration = timedRows.indices.filter { !timedWindow.contains($0) }.reduce(0.0) { total, index in
            total + words[timedRows[index].index].filter { $0.duration > 0 }.reduce(0) { $0 + $1.duration }
        }
        guard exteriorDuration <= 1 else { return nil }

        var mapped: [Int: [LyricWord]] = [:]
        var timedUnitCount = 0
        for match in bodyMatches {
            let original = originalRows[match.authoritative]
            let timed = timedRows[match.candidate]
            let candidateWords = words[timed.index]
            var result: [LyricWord] = []
            for word in candidateWords {
                guard let range = mappedRange(word.range, from: timed.units, to: original.units) else { continue }
                let start = word.startTime + offset
                let end = start + word.duration
                guard start.isFinite, end.isFinite, start >= 0, end <= duration + 0.002 else { continue }
                result.append(LyricWord(utf16Location: range.location, utf16Length: range.length,
                                        startTime: start, duration: word.duration))
                if word.duration > 0 {
                    timedUnitCount += timed.units.filter { NSLocationInRange($0.range.location, word.range) }.count
                }
            }
            mapped[original.index] = result
        }
        let enrichedRows = mapped.filter { !$0.value.isEmpty }.map(\.key)
        guard enrichedRows.count >= 4,
              Set(originalRows.filter { enrichedRows.contains($0.index) }.map(\.key)).count >= 3,
              Double(timedUnitCount) / Double(originalUnits) >= 0.5 else { return nil }
        return authoritative.enumerated().map { index, line in
            LyricLine(id: line.id, time: line.time, text: line.text, translation: line.translation,
                      endTime: line.endTime, words: mapped[index] ?? [], timing: .wordAnnotated)
        }
    }

    private static func validTimeline(_ lines: [LyricLine], duration: Double, candidateEnvelope: Bool = false) -> Bool {
        guard !lines.isEmpty, lines.count <= 1_024 else { return false }
        var previous = 0.0
        for line in lines {
            guard line.time.isFinite, line.time >= previous, line.time <= duration + 2,
                  line.text.utf8.count <= 20_000 else { return false }
            // A provider's final header can include the track duration rather
            // than the remaining duration. It is not the word clock: each
            // transferred word is independently bounded by the real track.
            if let end = line.endTime, !end.isFinite || end < line.time || end > (candidateEnvelope ? 604_800 : duration + 2) { return false }
            previous = line.time
        }
        return true
    }

    private static func rows(_ lines: [LyricLine]) -> [Row]? {
        var result: [Row] = []
        var total = 0
        for (index, line) in lines.enumerated() {
            var units: [Unit] = []
            for position in line.text.indices {
                let next = line.text.index(after: position)
                let range = NSRange(position..<next, in: line.text)
                let folded = String(line.text[position..<next]).folding(options: [.caseInsensitive, .widthInsensitive],
                    locale: Locale(identifier: "en_US_POSIX")).precomposedStringWithCanonicalMapping
                units += folded.unicodeScalars.filter {
                    !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0)
                }.map { Unit(scalar: $0, range: range) }
            }
            total += units.count
            guard total <= 200_000 else { return nil }
            if !units.isEmpty {
                let key = String(String.UnicodeScalarView(units.map(\.scalar)))
                result.append(Row(index: index, key: key, units: units))
            }
        }
        return result
    }

    private static func orderedMatches(_ a: [Row], _ b: [Row]) -> [Match] {
        let width = b.count + 1
        var lengths = [UInt16](repeating: 0, count: (a.count + 1) * width)
        for i in a.indices.reversed() {
            for j in b.indices.reversed() {
                lengths[i * width + j] = a[i].key == b[j].key ? lengths[(i + 1) * width + j + 1] + 1
                    : max(lengths[(i + 1) * width + j], lengths[i * width + j + 1])
            }
        }
        var result: [Match] = [], i = 0, j = 0
        while i < a.count && j < b.count {
            if a[i].key == b[j].key { result.append(Match(authoritative: i, candidate: j)); i += 1; j += 1 }
            else if lengths[(i + 1) * width + j] >= lengths[i * width + j + 1] { i += 1 }
            else { j += 1 }
        }
        return result
    }

    private static func validWords(_ line: LyricLine) -> [LyricWord] {
        guard line.timing == .wordAnnotated else { return [] }
        let boundaries = Set(line.text.indices.map { $0.utf16Offset(in: line.text) } + [line.text.utf16.count])
        var result: [LyricWord] = [], previousEnd = line.time, previousRangeEnd = 0
        for word in line.words {
            guard word.utf16Location >= previousRangeEnd, word.utf16Length > 0,
                  word.utf16Location <= line.text.utf16.count,
                  word.utf16Length <= line.text.utf16.count - word.utf16Location,
                  boundaries.contains(word.utf16Location), boundaries.contains(NSMaxRange(word.range)),
                  word.startTime.isFinite, word.duration.isFinite, word.duration >= 0,
                  word.startTime >= previousEnd - 0.000_000_001, word.startTime + word.duration <= (line.endTime ?? .infinity) + 0.002,
                  word.duration > 0 || !meaningful(line.text, range: word.range) else { continue }
            result.append(word)
            previousEnd = word.startTime + word.duration
            previousRangeEnd = NSMaxRange(word.range)
        }
        return result
    }

    private static func meaningful(_ text: String, range: NSRange) -> Bool {
        (text as NSString).substring(with: range).unicodeScalars.contains {
            !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0)
        }
    }

    private static func mappedRange(_ range: NSRange, from source: [Unit], to target: [Unit]) -> NSRange? {
        guard source.count == target.count,
              let first = source.firstIndex(where: { $0.range.location >= range.location && NSMaxRange($0.range) <= NSMaxRange(range) }),
              let last = source.lastIndex(where: { $0.range.location >= range.location && NSMaxRange($0.range) <= NSMaxRange(range) }),
              first == 0 || target[first - 1].range != target[first].range,
              last == target.count - 1 || target[last + 1].range != target[last].range else { return nil }
        let start = target[first].range.location
        let end = NSMaxRange(target[last].range)
        return end > start ? NSRange(location: start, length: end - start) : nil
    }
}
