import Foundation

// Build only with the listed lyric sources/tests, not AppMain/Preferences. The
// shim keeps all fixtures independent of user defaults or an application UI.
#if LYRICS_RESILIENCE_REGRESSION_RUNNER
@MainActor func tr(_ key: String) -> String { key }

@main
struct LyricsRegressionRunner {
    @MainActor static func main() async {
        var failures: [String] = []
        let resilienceOnly = CommandLine.arguments.contains("--resilience-only")
        if !resilienceOnly {
            failures += runKaraokeParserTests() + runLyricPlaybackClockTests() + runKaraokeRenderingTests()
            failures += runKaraokeNativeViewTests()
            failures += runTimedLyricsEnrichmentTests()
            failures += runLyricsTests() + runQQMusicLyricsTests()
            failures += await runQQMusicPipelineTests()
            failures += await runLyricsLifecycleTests()
            failures += await runNeteaseLyricsTests()
            failures += await runNeteaseEnrichmentIntegrationTests()
        }
        failures += await runLyricsResilienceTests()
        if failures.isEmpty {
            print(resilienceOnly ? "PASS: offline general lyric resilience integration suite"
                  : "PASS: offline LRC/language, QQ identity/pipeline, NetEase, lifecycle and general lyric resilience regression suites")
        } else {
            failures.forEach { print("FAIL: " + $0) }
            exit(1)
        }
    }
}
#endif
