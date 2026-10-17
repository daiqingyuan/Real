import Foundation

/// All filesystem mutations use a disposable fixture. These checks never read
/// or change real preferences and never launch an app or trigger navigation.
func runSettingsUsabilityTests() -> [String] {
    var failures: [String] = []
    func check(_ condition: Bool, _ message: String) {
        if !condition { failures.append("Settings usability: " + message) }
    }
    let legacy = "com.example.first, com.example.second\ncom.unknown.old\tcom.example.first"
    check(ApplicationExclusions.identifiers(in: legacy) == ["com.example.first", "com.example.second", "com.unknown.old"], "legacy comma and whitespace values are read and deduplicated")
    check(ApplicationExclusions.updating(legacy, identifier: "com.example.first", excluded: true) == legacy, "a no-op selection does not reformat existing preferences")
    check(ApplicationExclusions.updating(legacy, identifier: "com.example.absent", excluded: false) == legacy, "a no-op removal does not write or reformat preferences")
    let removed = ApplicationExclusions.updating(legacy, identifier: "com.example.first", excluded: false)
    check(ApplicationExclusions.identifiers(in: removed) == ["com.example.second", "com.unknown.old"], "unchecking removes all duplicate occurrences but preserves unknown identifiers")
    let appended = ApplicationExclusions.updating(removed, identifier: "com.example.new", excluded: true)
    check(ApplicationExclusions.identifiers(in: appended) == ["com.example.second", "com.unknown.old", "com.example.new"], "checking a new app preserves every previous exclusion")
    check(ApplicationExclusions.updating(legacy, identifier: "malformed id", excluded: true) == legacy, "malformed new identifiers cannot corrupt the list format")
    check(ApplicationExclusions.identifiers(in: " \n, ,\t").isEmpty, "empty legacy separators produce an empty selection")
    let known = CatalogApplication(bundleIdentifier: "com.example.first", name: "First", url: URL(fileURLWithPath: "/fixture/First.app"), isRunning: false)
    let rows = ApplicationExclusions.applications([known, known], preserving: legacy)
    check(rows.count == 3 && Set(rows.map(\.id)).count == 3, "the picker shows one row per identifier including unavailable saved apps")
    check(rows.filter { $0.url == nil }.map(\.id).contains("com.unknown.old"), "unavailable exclusions remain visible and removable")
    check(ApplicationExclusions.applications([], preserving: legacy).count == 3, "a failed or empty scan cannot clear saved exclusions")

    func results(_ query: String, _ language: String = "zh-Hans") -> [String] {
        SettingsSearchIndex.search(query, language: language).map(\.id)
    }
    check(results("").isEmpty && results(" \n\t").isEmpty, "empty queries do not enumerate or invoke settings")
    check(results("no-such-setting-73192").isEmpty, "a query without matches returns no result")
    check(results("导出诊断").first == "runtime.diagnostics", "diagnostic search leads to the export destination")
    check(results("开机").contains("preferences.login"), "Chinese startup synonym finds login launch")
    check(results("字体").contains("music.lyrics.font"), "Chinese font synonym finds lyric text size")
    check(results("ＬＹＲＩＣＳ ＦＯＮＴ", "en").contains("music.lyrics.font"), "full-width uppercase multiword search matches English keywords")
    check(results("LYRICS color", "en").contains("music.lyrics.color"), "English queries ignore case and require all words")
    check(!results("lyrics uninstall", "en").contains("music.lyrics"), "words from unrelated settings are not merged across entries")
    check(results("歌詞 サイズ", "ja-JP").contains("music.lyrics.font"), "Japanese multiword search is supported")
    check(results("ТЕКСТ размер", "ru-RU").contains("music.lyrics.font"), "Russian multiword search is case insensitive")
    check(results("исключенные", "ru").contains("dock.exclusions"), "Russian accented characters fold consistently")
    let accent = SettingsSearchEntry(id: "accent", title: "Café", page: "preferences", anchor: "preferences.general", keywords: "café")
    check(SettingsSearchIndex.search("CAFE", language: "en", entries: [accent]).first?.id == "accent", "Latin diacritics are ignored")
    check(SettingsSearchIndex.search("cafe", language: "en", entries: [accent], limit: 0).isEmpty, "a zero result limit is respected")
    check(Set(SettingsSearchIndex.entries.map(\.id)).count == SettingsSearchIndex.entries.count, "search result identifiers are unique")
    let allowedPages: Set<String> = ["dock", "island", "preferences"]
    let allowedAnchors: Set<String> = ["dock.behavior", "dock.presence", "permissions", "music.lyrics", "music.playback", "island.appearance", "module.calendar", "module.shelf", "module.hud", "module.mirror", "preferences.general", "preferences.support", "runtime.health", "runtime.diagnostics", "preferences.uninstall"]
    check(SettingsSearchIndex.entries.allSatisfy { allowedPages.contains($0.page) && allowedAnchors.contains($0.anchor) }, "all results describe valid navigation destinations only")
    check(Set(SettingsSearchIndex.entries.compactMap(\.module)).isSuperset(of: ["music", "calendar", "shelf", "hud", "mirror"]), "all retained island modules are searchable")
    check(results("卸载").contains("preferences.uninstall") && results("授权").contains("permissions"), "sensitive settings can be located without invoking their actions")
    check(SettingsSearchIndex.entries.first(where: { $0.id == "music.source" })?.expand == "music", "advanced playback results request disclosure expansion")
    check(SettingsSearchIndex.entries.first(where: { $0.id == "island.more" })?.expand == "appearance", "advanced appearance results request disclosure expansion")

    let fm = FileManager.default
    let fixture = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("real-settings-tests-\(UUID().uuidString)", isDirectory: true)
    do {
        try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }
        func directory(_ name: String) throws -> URL {
            let url = fixture.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        func app(_ path: String, id: String, name: String) throws -> URL {
            let url = try directory(path)
            let contents = url.appendingPathComponent("Contents", isDirectory: true)
            try fm.createDirectory(at: contents, withIntermediateDirectories: true)
            let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundleDisplayName": name]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
            return url
        }
        let rootA = try directory("Applications")
        let rootB = try directory("User Applications")
        let running = try app("Running/Chosen.app", id: "test.same", name: "Running chosen")
        _ = try app("Applications/Duplicate.app", id: "test.same", name: "Root duplicate")
        _ = try app("User Applications/RootDuplicate.app", id: "test.same", name: "User duplicate")
        let preferred = try app("Applications/Preferred.app", id: "test.rootpriority", name: "Preferred")
        _ = try app("User Applications/Secondary.app", id: "test.rootpriority", name: "Secondary")
        _ = try app("Applications/Utilities/工具.app", id: "test.localized", name: "工具")
        _ = try app("Applications/Host.app", id: "test.host", name: "Host")
        _ = try app("Applications/Host.app/Contents/Nested.app", id: "test.nested", name: "Never enter packages")
        _ = try app("Applications/Old.app.disabled/Backup.app", id: "test.disabled", name: "Disabled backup")
        _ = try app("Applications/.Hidden.app", id: "test.hidden", name: "Hidden")
        try fm.createSymbolicLink(at: rootA.appendingPathComponent("Loop", isDirectory: true), withDestinationURL: rootA)
        try fm.createSymbolicLink(at: rootA.appendingPathComponent("Linked.app"), withDestinationURL: running)
        let snapshot = ApplicationCatalogScanner.scan(roots: [rootA, rootB], runningApplications: [running])
        check(snapshot.applications.count == 4, "bounded catalog finds apps but skips hidden, backup, symlink, and nested package fixtures")
        check(snapshot.applications.first(where: { $0.id == "test.same" })?.url == running && snapshot.applications.first(where: { $0.id == "test.same" })?.isRunning == true, "an actual running path wins over duplicate installed copies")
        check(snapshot.applications.first(where: { $0.id == "test.rootpriority" })?.url == preferred, "earlier explicit Applications roots win deterministic duplicates")
        check(!snapshot.truncated && !snapshot.cancelled && snapshot.directoriesVisited < 8, "symlink loops are not followed")
        check(!snapshot.applications.contains(where: { ["test.nested", "test.disabled", "test.hidden"].contains($0.id) }), "retired backups and package interiors stay excluded")

        let denied = try directory("Applications/Denied")
        _ = try app("Applications/Denied/Unreadable.app", id: "test.denied", name: "Unreadable")
        let withDenied = ApplicationCatalogScanner.scan(roots: [rootA], directoryContents: { directory in
            if directory == denied { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)) }
            return try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        })
        check(withDenied.failedPaths.contains(denied.path), "directory permission failures are reported without aborting accessible siblings")
        check(withDenied.applications.contains(where: { $0.id == "test.host" }), "a failed folder does not erase successfully scanned apps")
        check(ApplicationExclusions.applications(withDenied.applications, preserving: "test.denied, test.uninstalled").contains(where: { $0.id == "test.denied" && $0.url == nil }), "a permission failure preserves saved exclusions as unavailable rows")

        var tiny = ApplicationCatalogScanLimits(); tiny.maximumEntries = 2
        let bounded = ApplicationCatalogScanner.scan(roots: [rootA], limits: tiny)
        check(bounded.truncated && bounded.entriesVisited <= 2, "entry budgets cap traversal")
        var shallow = ApplicationCatalogScanLimits(); shallow.maximumDepth = 0
        let shallowResult = ApplicationCatalogScanner.scan(roots: [rootA], limits: shallow)
        check(shallowResult.truncated && !shallowResult.applications.contains(where: { $0.id == "test.localized" }), "depth budgets never descend into deeper folders")
        let cancelled = ApplicationCatalogScanner.scan(roots: [rootA], cancelled: { true })
        check(cancelled.cancelled && cancelled.entriesVisited == 0 && cancelled.applications.isEmpty, "cancelled scans stop before filesystem traversal")
        let missing = ApplicationCatalogScanner.scan(roots: [fixture.appendingPathComponent("DoesNotExist")])
        check(missing.applications.isEmpty, "missing roots are harmless")
        let hostile = ApplicationCatalogScanner.scan(roots: [rootA], directoryContents: { _ in [running] })
        check(hostile.applications.isEmpty, "out-of-root entries from a faulty provider are rejected")
    } catch { failures.append("Settings usability: fixture setup failed: \(error)") }
    return failures
}

#if SETTINGS_USABILITY_STANDALONE
@main
struct SettingsUsabilityStandaloneRunner {
    static func main() {
        let failures = runSettingsUsabilityTests()
        if failures.isEmpty { print("PASS: settings search, exclusion compatibility, and bounded app catalog fixtures") }
        else { failures.forEach { print("FAIL: " + $0) }; exit(1) }
    }
}
#endif
