import Foundation

func runLyricsTests() -> [String] {
    var failures: [String] = []
    func expect(_ condition: @autoclosure () -> Bool, _ description: String) {
        if !condition() { failures.append(description) }
    }
    let basic = LRCParser.parse("[ar:An artist]\r\n[00:02.50]second\r\n[00:01]first\n[00:03.125]第三行 🎵")
    expect(basic.map(\.text) == ["first", "second", "第三行 🎵"], "LRC metadata, Unicode, CRLF and ordering")
    expect(basic.map(\.time) == [1, 2.5, 3.125], "LRC whole, hundredth and millisecond precision")
    let repeated = LRCParser.parse("[00:01.2][00:03.45] repeated\n[00:03.45]replacement\n[00:04.00]")
    expect(repeated.count == 4, "Each time tag produces a line, including blank clear markers")
    expect(repeated.map(\.time) == [1.2, 3.45, 3.45, 4], "Multiple time tags retain their independent timestamps")
    expect(repeated.map(\.text) == ["repeated", "repeated", "replacement", ""], "Stable duplicate timestamp order")
    expect(Set(repeated.map(\.id)).count == repeated.count, "Repeated timestamps have unique identity")
    let offset = LRCParser.parse("[00:00.2]a\n[01:01.23]b\n[offset:-500]")
    expect(offset.map(\.time) == [0, 60.73], "Global negative offset and clamping to zero")
    let plus = LRCParser.parse("[offset:+1000]\n[00:00]start")
    expect(plus.first?.time == 1, "Signed positive offset")
    expect(LRCParser.parse("plain lyrics\n[ar:Unknown]\n[00:99]bad\n[-1:02]bad\n[00:2]bad").isEmpty, "Malformed timestamps and untimed lyrics are ignored")
    expect(LRCParser.parse("").isEmpty, "Empty LRC input")
    expect(LyricLanguagePolicy.isEnglish(["I want to stay with you tonight", "Can you hear the music playing in my heart"]), "English lyrics suppress translations")
    expect(!LyricLanguagePolicy.isEnglish(["君と過ごした日々を忘れない", "いつまでもあなたのことを想っている"]), "Japanese lyrics retain translation support")
    expect(!LyricLanguagePolicy.isEnglish(["Je voudrais rester avec toi ce soir", "La musique nous accompagne dans la nuit"]), "French lyrics retain translation support")
    expect(!LyricLanguagePolicy.isEnglish(["风吹过夏天的街道", "我在这里等你回来"]), "Chinese lyrics are not classified by an English song title")
    expect(!LyricLanguagePolicy.isEnglish([]), "Empty lyrics have no inferred language")
    let gaps = LRCParser.parse("[00:01]first\n[00:02]\n[00:06]second", duration: 10)
    expect(LyricDisplayPolicy.line(in: gaps, at: 0) == nil, "No future lyric before the first line")
    expect(LyricDisplayPolicy.line(in: gaps, at: 5)?.text == "first", "Hold the previous lyric across blank rest markers")
    expect(LyricDisplayPolicy.line(in: gaps, at: 6)?.text == "second", "Advance exactly when the next lyric begins")
    expect(LyricDisplayPolicy.line(in: gaps, at: 1.5)?.text == "first", "Backward seek selects the earlier lyric instead of retaining a future line")
    expect(LyricDisplayPolicy.line(in: [], at: 7) == nil, "Track without lyrics cannot retain another track's text")
    expect(LyricDisplayPolicy.line(in: gaps, at: .nan) == nil, "Invalid playback timing cannot select a lyric")
    let qrcGap = [LyricLine(id: 0, time: 1, text: "first", translation: "translation", endTime: 2),
                  LyricLine(id: 1, time: 6, text: "second", endTime: 7)]
    expect(LyricDisplayPolicy.line(in: qrcGap, at: 3)?.translation == "translation", "QRC singing end does not erase the displayed lyric or its translation")
    return failures
}
