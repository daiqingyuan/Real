import Foundation

// Adapted from the user's authorized QQMusicQRCParser.swift integration.
// Translation matching now preserves timestamps instead of requiring identical line counts.
enum QQMusicQRCParser {
    struct QRCResult {
        let lines: [LyricLine]
        let translations: [LyricLine]
    }
    private static let linePattern = try! NSRegularExpression(pattern: #"\[(\d+),(\d+)\]([\s\S]*?)(?=\[\d+,\d+\]|$)"#)
    private static let wordPattern = try! NSRegularExpression(pattern: #"\(\d+,\d+\)"#)
    private static let entityPattern = try! NSRegularExpression(pattern: #"&#(x[0-9a-fA-F]+|\d+);"#)

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
                translation: translation == line.text ? nil : translation, endTime: line.endTime)
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
        var entries: [(Double, Double, String, Int)] = []
        let ns = content as NSString
        for match in linePattern.matches(in: content, range: NSRange(location: 0, length: ns.length)) {
            guard let startMS = Double(ns.substring(with: match.range(at: 1))),
                  let durationMS = Double(ns.substring(with: match.range(at: 2))),
                  startMS.isFinite, durationMS.isFinite else { continue }
            let raw = ns.substring(with: match.range(at: 3))
            let text = wordPattern.stringByReplacingMatches(in: raw, range: NSRange(location: 0, length: (raw as NSString).length), withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let start = startMS / 1000
            let end = start + durationMS / 1000
            guard start.isFinite, end.isFinite else { continue }
            entries.append((start, end, text, entries.count))
        }
        entries.sort { $0.0 == $1.0 ? $0.3 < $1.3 : $0.0 < $1.0 }
        return entries.enumerated().map { index, entry in
            LyricLine(id: index, time: entry.0, text: entry.2, endTime: entry.1)
        }
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
