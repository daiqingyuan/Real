import Foundation

/// NetEase YRC uses prefix annotations, unlike QRC's suffix annotations:
/// [lineStart,lineDuration](absoluteWordStart,wordDuration,reserved)text
/// All provider times are milliseconds; displayed ranges use UTF-16 units.
enum NeteaseYRCParser {
    private static let linePattern = try! NSRegularExpression(pattern: #"^\s*\[([0-9]+),([0-9]+)\](.*)$"#)
    // Recognize malformed numeric annotations too, so a bad timing cannot
    // become visible lyric text. Ordinary parentheticals remain untouched.
    private static let annotationPattern = try! NSRegularExpression(pattern: #"\(([^(),\r\n]*,[^()\r\n]*)\)"#)
    private static let incompleteAnnotationPattern = try! NSRegularExpression(pattern: #"\(([^(),\r\n]*,[^()\r\n]*)(?=\(|$)"#)
    private static let maximumTimeMS = 604_800_000.0
    private static let maximumBytes = 2_000_000
    private static let lineEndToleranceMS = 2.0

    static func parse(_ input: String, duration: Double? = nil) -> [LyricLine] {
        guard input.utf8.count <= maximumBytes else { return [] }
        let trackLimit = duration.flatMap { $0.isFinite && $0 > 0 ? min(maximumTimeMS, $0 * 1000 + 2000) : nil }
            ?? maximumTimeMS
        var entries: [(start: Double, end: Double, text: String, words: [LyricWord], order: Int)] = []
        for row in input.components(separatedBy: .newlines) {
            let trimmed = row.trimmingCharacters(in: .whitespaces)
            // Metadata contains display links/credits, not sung words. Never
            // interpret or expose its JSON as an ordinary lyric row.
            if trimmed.isEmpty || trimmed.hasPrefix("{") { continue }
            let source = row as NSString
            guard let match = linePattern.firstMatch(in: row, range: NSRange(location: 0, length: source.length)),
                  let startMS = milliseconds(source.substring(with: match.range(at: 1))),
                  let durationMS = milliseconds(source.substring(with: match.range(at: 2))),
                  durationMS > 0, startMS + durationMS <= trackLimit else {
                // A damaged row header could otherwise silently delete part
                // of the song. Reject this enrichment and let LRC take over.
                return []
            }
            guard let parsed = parseWords(source.substring(with: match.range(at: 3)),
                                          lineStartMS: startMS, lineEndMS: startMS + durationMS,
                                          trackLimitMS: trackLimit) else { return [] }
            entries.append((startMS / 1000, parsed.endMS / 1000,
                            parsed.text, parsed.words, entries.count))
        }
        entries.sort { $0.start == $1.start ? $0.order < $1.order : $0.start < $1.start }
        return entries.enumerated().map { index, entry in
            LyricLine(id: index, time: entry.start, text: entry.text, endTime: entry.end,
                      words: entry.words, timing: .wordAnnotated)
        }
    }

    /// Instantaneous punctuation alone is not evidence of sung-word timing.
    static func hasWordTimings(_ lines: [LyricLine]) -> Bool {
        lines.contains { line in
            let text = line.text as NSString
            return line.words.contains { word in
                word.duration > 0 && text.substring(with: word.range).unicodeScalars.contains {
                    !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0)
                }
            }
        }
    }

    private static func milliseconds(_ value: String) -> Double? {
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = Double(value), number.isFinite, number <= maximumTimeMS else { return nil }
        return number
    }

    private static func looksNumeric(_ value: String) -> Bool {
        let value = value.trimmingCharacters(in: .whitespaces).lowercased()
        guard let first = value.first else { return false }
        return first.isASCII && (first.isNumber || first == "+" || first == "-")
            || ["nan", "inf", "infinity"].contains(value)
    }

    private static func parseWords(_ raw: String, lineStartMS: Double, lineEndMS: Double,
                                   trackLimitMS: Double) -> (text: String, words: [LyricWord], endMS: Double)? {
        let source = raw as NSString
        if incompleteAnnotationPattern.matches(in: raw, range: NSRange(location: 0, length: source.length)).contains(where: { match in
            source.substring(with: match.range(at: 1)).components(separatedBy: ",").prefix(2).contains(where: looksNumeric)
        }) { return nil }
        let annotations = annotationPattern.matches(in: raw, range: NSRange(location: 0, length: source.length)).filter { match in
            let fields = source.substring(with: match.range(at: 1)).components(separatedBy: ",")
            return fields.prefix(2).contains(where: looksNumeric)
        }
        guard let first = annotations.first else { return (raw, [], lineEndMS) }
        let prefix = source.substring(to: first.range.location)
        var text = prefix
        var textLength = (prefix as NSString).length
        var spans: [(fields: [String], location: Int, length: Int, fragment: String)] = []
        for (index, annotation) in annotations.enumerated() {
            let fields = source.substring(with: annotation.range(at: 1)).components(separatedBy: ",")
            let start = NSMaxRange(annotation.range)
            let end = index + 1 < annotations.count ? annotations[index + 1].range.location : source.length
            let fragment = source.substring(with: NSRange(location: start, length: end - start))
            let length = (fragment as NSString).length
            spans.append((fields, textLength, length, fragment))
            text += fragment
            textLength += length
        }
        // Validate against the complete displayed string before accepting any
        // span. A rejected grapheme fragment must not advance time ordering.
        let boundaries = Set(text.indices.map { $0.utf16Offset(in: text) } + [text.utf16.count])
        var words: [LyricWord] = []
        var previousEndMS = lineStartMS
        var acceptedEndMS = lineEndMS
        let latestWordEndMS = min(trackLimitMS, lineEndMS + lineEndToleranceMS)
        for span in spans {
            let fields = span.fields
            let instantaneous = !span.fragment.isEmpty && span.fragment.unicodeScalars.allSatisfy {
                CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.punctuationCharacters.contains($0)
            }
            if fields.count == 3, let startMS = milliseconds(fields[0]), let durationMS = milliseconds(fields[1]),
               !fields[2].isEmpty, fields[2].utf8.allSatisfy({ (48...57).contains($0) }), UInt64(fields[2]) != nil,
               span.length > 0, durationMS > 0 || instantaneous,
               boundaries.contains(span.location), boundaries.contains(span.location + span.length),
               startMS >= lineStartMS, startMS >= previousEndMS, startMS + durationMS <= latestWordEndMS {
                words.append(LyricWord(utf16Location: span.location, utf16Length: span.length,
                                      startTime: startMS / 1000, duration: durationMS / 1000))
                previousEndMS = startMS + durationMS
                acceptedEndMS = max(acceptedEndMS, previousEndMS)
            }
            // Unknown timing leaves this fragment white. Other independently
            // verified words remain usable, including after a zero-time lead-in.
        }
        return (text, words, acceptedEndMS)
    }
}
