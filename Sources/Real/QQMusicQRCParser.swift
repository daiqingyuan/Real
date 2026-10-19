import Foundation

// Adapted from the user's authorized QQMusicQRCParser.swift integration.
// Translation matching now preserves timestamps instead of requiring identical line counts.
enum QQMusicQRCParser {
    struct QRCResult {
        let lines: [LyricLine]
        let translations: [LyricLine]
    }
    private static let linePattern = try! NSRegularExpression(pattern: #"\[(\d+),(\d+)\]([\s\S]*?)(?=\[\d+,\d+\]|$)"#)
    // Capture malformed numeric annotations as well, so readable lyrics can
    // survive a bad word timestamp without exposing it as part of the lyric.
    private static let wordPattern = try! NSRegularExpression(pattern: #"\(([^(),\r\n]*),([^()\r\n]*)\)"#)
    private static let entityPattern = try! NSRegularExpression(pattern: #"&#(x[0-9a-fA-F]+|\d+);"#)
    private static let maximumWordTimeMS = 604_800_000.0 // A generous seven-day audio bound.

    static func parse(qrcContent: String, translationContent: String? = nil, duration: Double? = nil) -> QRCResult {
        let content = decodeEntities(qrcContent)
        let qrc = parseQRCLines(content)
        let lines = qrc.isEmpty ? LRCParser.parse(content, duration: duration) : qrc
        let translated = decodeEntities(translationContent ?? "")
        let qrcTranslations = parseQRCLines(translated)
        return QRCResult(lines: lines, translations: qrcTranslations.isEmpty ? LRCParser.parse(translated, duration: duration) : qrcTranslations)
    }

    static func applyTranslations(_ lines: [LyricLine], translations: [LyricLine]) -> [LyricLine] {
        guard !translations.isEmpty else { return lines }
        var used: Set<Int> = []
        return lines.map { line in
            let match = translations.indices.filter { !used.contains($0) && !translations[$0].text.isEmpty && abs(translations[$0].time - line.time) <= 0.6 }
                .min { abs(translations[$0].time - line.time) < abs(translations[$1].time - line.time) }
            guard let match else { return line }
            used.insert(match)
            let translation = translations[match].text
            return LyricLine(id: line.id, time: line.time, text: line.text,
                translation: translation == line.text ? nil : translation, endTime: line.endTime,
                words: line.words, timing: line.timing)
        }
    }

    static func hasUsableLyrics(_ lines: [LyricLine]) -> Bool {
        let texts = lines.map(\.text).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !texts.isEmpty else { return false }
        if texts.count <= 2 {
            let combined = texts.joined()
            let notices = ["纯音乐", "暂无歌词", "暂时没有歌词", "没有填词", "歌词暂不", "暂无滚动歌词", "请您欣赏", "请欣赏"]
            if notices.contains(where: combined.contains) { return false }
        }
        return true
    }

    static func parseResponse(original: String, translation: String?, duration: Double? = nil) -> [LyricLine] {
        guard let decoded = decodePayload(original) else { return [] }
        let embedded = extractFromXML(decoded)
        let originalText = embedded.orig ?? decoded
        var translatedText = embedded.trans
        if let translation, let decodedTranslation = decodePayload(translation) {
            let fields = extractFromXML(decodedTranslation)
            translatedText = fields.trans ?? fields.orig ?? decodedTranslation
        }
        let parsed = parse(qrcContent: originalText, translationContent: translatedText, duration: duration)
        return applyTranslations(parsed.lines, translations: parsed.translations)
    }

    static func decodePayload(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 4_000_000 else { return nil }
        let compact = trimmed.filter { !$0.isWhitespace }
        if !compact.isEmpty, compact.allSatisfy({ $0.isASCII && $0.isHexDigit }) {
            return QQMusicQRCDecoder.decode(compact)
        }
        return trimmed
    }

    static func extractFromXML(_ value: String) -> (orig: String?, trans: String?) {
        var xml = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if xml.hasPrefix("<!--"), xml.hasSuffix("-->") { xml = String(xml.dropFirst(4).dropLast(3)) }
        guard xml.contains("<"), xml.utf8.count <= 4_000_000 else { return (nil, nil) }
        func rawAttribute(_ name: String) -> String? {
            let pattern = name + #"\s*=\s*(["'])([\s\S]*?)\1"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: xml, range: NSRange(location: 0, length: (xml as NSString).length)) else { return nil }
            // XMLParser normalizes literal attribute newlines to spaces, destroying lyric rows.
            return decodeEntities((xml as NSString).substring(with: match.range(at: 2)))
        }
        let rawOriginal = rawAttribute("LyricContent")
        let rawTranslation = rawAttribute("LyricTranslation")
        let delegate = LyricXMLReader()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        if parser.parse(), delegate.original != nil || delegate.translation != nil {
            return (rawOriginal ?? delegate.original, rawTranslation ?? delegate.translation)
        }
        // The live legacy endpoint also returns XML wrapped inside an outer comment marker.
        // Extract only the two documented fields; do not require that wrapper to be valid XML.
        func field(_ name: String) -> String? {
            let pattern = "<" + name + #"\b[^>]*>([\s\S]*?)</"# + name + ">"
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: xml, range: NSRange(location: 0, length: (xml as NSString).length)) else { return nil }
            var value = (xml as NSString).substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("<![CDATA["), value.hasSuffix("]]>") { value = String(value.dropFirst(9).dropLast(3)) }
            return value
        }
        return (field("content") ?? rawOriginal, field("contentts") ?? rawTranslation)
    }

    static func decodeEntities(_ value: String) -> String {
        var result = value
        let ns = result as NSString
        for match in entityPattern.matches(in: result, range: NSRange(location: 0, length: ns.length)).reversed() {
            let digits = ns.substring(with: match.range(at: 1))
            let number = digits.hasPrefix("x") ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
            guard let number, let scalar = UnicodeScalar(number), let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: String(scalar))
        }
        return result.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func parseQRCLines(_ content: String) -> [LyricLine] {
        var entries: [(start: Double, end: Double, text: String, words: [LyricWord], order: Int)] = []
        let ns = content as NSString
        for match in linePattern.matches(in: content, range: NSRange(location: 0, length: ns.length)) {
            guard let startMS = Double(ns.substring(with: match.range(at: 1))),
                  let durationMS = Double(ns.substring(with: match.range(at: 2))),
                  startMS.isFinite, durationMS.isFinite else { continue }
            let raw = ns.substring(with: match.range(at: 3))
            let start = startMS / 1000
            let end = start + durationMS / 1000
            guard start.isFinite, end.isFinite else { continue }
            let parsed = parseWords(raw, lineStartMS: startMS, lineEndMS: startMS + durationMS)
            let adjustedEnd = parsed.acceptedEndMS.isFinite ? max(end, parsed.acceptedEndMS / 1000) : end
            entries.append((start, adjustedEnd, parsed.text, parsed.words, entries.count))
        }
        entries.sort { $0.start == $1.start ? $0.order < $1.order : $0.start < $1.start }
        return entries.enumerated().map { index, entry in
            LyricLine(id: index, time: entry.start, text: entry.text, endTime: entry.end,
                      words: entry.words, timing: .wordAnnotated)
        }
    }

    private static func parseWords(_ raw: String, lineStartMS: Double, lineEndMS: Double) -> (text: String, words: [LyricWord], acceptedEndMS: Double) {
        let source = raw as NSString
        var text = ""
        var textLength = 0
        var cursor = 0
        var candidates: [(range: NSRange, startMS: Double?, durationMS: Double?)] = []
        let validEnvelope = lineStartMS >= 0 && lineEndMS <= maximumWordTimeMS && lineEndMS > lineStartMS
        let instantaneousCharacters = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)

        func isTimingField(_ value: String) -> Bool {
            let value = value.trimmingCharacters(in: .whitespaces).lowercased()
            guard let first = value.first else { return false }
            return first.isASCII && (first.isNumber || first == "+" || first == "-")
                || ["nan", "inf", "infinity"].contains(value)
        }
        func milliseconds(_ value: String) -> Double? {
            guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
                  let number = Double(value), number.isFinite, number <= maximumWordTimeMS else { return nil }
            return number
        }

        for match in wordPattern.matches(in: raw, range: NSRange(location: 0, length: source.length)) {
            let startField = source.substring(with: match.range(at: 1))
            let durationField = source.substring(with: match.range(at: 2))
            // Ordinary lyric parentheticals such as "(hello, world)" are text.
            guard isTimingField(startField) || isTimingField(durationField) else { continue }
            let segment = source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let length = (segment as NSString).length
            text += segment
            candidates.append((NSRange(location: textLength, length: length),
                               milliseconds(startField), milliseconds(durationField)))
            textLength += length
            cursor = NSMaxRange(match.range)
        }
        let tail = source.substring(from: cursor)
        text += tail
        // Trailing text has no provider clock and stays outside timed ranges.

        // Trim whole Characters, then adjust provider ranges to the text that
        // is actually displayed. Internal whitespace and punctuation survive.
        let first = text.firstIndex(where: { !$0.isWhitespace }) ?? text.endIndex
        let last = text.lastIndex(where: { !$0.isWhitespace }).map { text.index(after: $0) } ?? first
        let trimStart = first.utf16Offset(in: text)
        let trimEnd = last.utf16Offset(in: text)
        let trimmed = String(text[first..<last])
        let boundaries = Set(trimmed.indices.map { $0.utf16Offset(in: trimmed) } + [trimmed.utf16.count])
        var adjusted: [LyricWord] = []
        var previousEndMS = lineStartMS
        var acceptedEndMS = lineEndMS
        for candidate in candidates {
            let start = max(trimStart, candidate.range.location)
            let end = min(trimEnd, NSMaxRange(candidate.range))
            guard end > start else { continue } // An edge segment may contain only trimmed spaces.
            let location = start - trimStart
            let length = end - start
            guard validEnvelope, boundaries.contains(location), boundaries.contains(location + length),
                  let startMS = candidate.startMS, let durationMS = candidate.durationMS,
                  startMS >= lineStartMS, startMS <= lineEndMS, startMS >= previousEndMS,
                  startMS + durationMS <= maximumWordTimeMS,
                  // QQ headers sometimes round an inclusive final millisecond.
                  // Preserve the source token clock, allowing only this tiny
                  // header-end discrepancy, and expand the published envelope.
                  startMS + durationMS <= lineEndMS + 2 else { continue }
            let displayedSpan = (trimmed as NSString).substring(with: NSRange(location: location, length: length))
            // Unknown sung spans remain readable and uncolored. A bad range or
            // clock never consumes the temporal watermark of a later good span.
            guard durationMS > 0 || displayedSpan.unicodeScalars.allSatisfy({ instantaneousCharacters.contains($0) }) else { continue }
            adjusted.append(LyricWord(utf16Location: location, utf16Length: length,
                startTime: startMS / 1000, duration: durationMS / 1000))
            previousEndMS = startMS + durationMS
            acceptedEndMS = max(acceptedEndMS, previousEndMS)
        }
        return (trimmed, adjusted, acceptedEndMS)
    }

    private final class LyricXMLReader: NSObject, XMLParserDelegate {
        var original: String?
        var translation: String?
        private var currentField: String?
        private var text = ""
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            if name == "content" || name == "contentts" { currentField = name; text = "" }
            if let value = attributes["LyricContent"] { original = value }
            if let value = attributes["LyricTranslation"] { translation = value }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { if currentField != nil { text += string } }
        func parser(_ parser: XMLParser, foundCDATA data: Data) { if currentField != nil { text += String(data: data, encoding: .utf8) ?? "" } }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            guard name == currentField else { return }
            if name == "content" { original = text } else { translation = text }
            currentField = nil
            text = ""
        }
    }
}
