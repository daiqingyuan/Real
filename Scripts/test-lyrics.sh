#!/bin/zsh
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_stage="$(mktemp -d /private/tmp/real-lyrics-tests.XXXXXX)"
trap 'rm -rf "$test_stage"' EXIT
snapshot_dir="${1:-}"
if [[ -z "$snapshot_dir" ]]; then
  snapshot_dir="$test_stage/source"
  mkdir -p "$snapshot_dir"
  cp "$project_dir"/Sources/Real/*.swift "$project_dir"/Tests/*.swift "$snapshot_dir/"
fi
xcrun swiftc -swift-version 5 -parse-as-library -D LYRICS_RESILIENCE_REGRESSION_RUNNER \
  -module-cache-path "$test_stage/module-cache" \
  "$snapshot_dir/LyricDisplayPolicy.swift" "$snapshot_dir/LyricsService.swift" \
  "$snapshot_dir/TimedLyricsEnrichment.swift" "$snapshot_dir/TimedLyricsEnrichmentTests.swift" \
  "$snapshot_dir/NeteaseEnrichmentIntegrationTests.swift" \
  "$snapshot_dir/KaraokeLyricText.swift" "$snapshot_dir/LyricPlaybackClock.swift" \
  "$snapshot_dir/KaraokeParserTests.swift" "$snapshot_dir/KaraokeRenderingTests.swift" "$snapshot_dir/LyricPlaybackClockTests.swift" \
  "$snapshot_dir/KaraokeNativeViewTests.swift" "$snapshot_dir/NeteaseYRCParser.swift" \
  "$snapshot_dir/NeteaseLyricsProvider.swift" "$snapshot_dir/QQMusicLyricsProvider.swift" \
  "$snapshot_dir/QQMusicQRCLyricsProvider.swift" "$snapshot_dir/QQMusicQRCParser.swift" \
  "$snapshot_dir/QQMusicQRCDecoder.swift" "$snapshot_dir/LyricsTests.swift" \
  "$snapshot_dir/QQMusicLyricsTests.swift" "$snapshot_dir/LyricsLifecycleTests.swift" \
  "$snapshot_dir/NeteaseLyricsTests.swift" "$snapshot_dir/LyricsResilienceTests.swift" \
  "$project_dir/Scripts/LyricsRegressionRunner.swift" -lz -o "$test_stage/lyrics-tests"
"$test_stage/lyrics-tests"
