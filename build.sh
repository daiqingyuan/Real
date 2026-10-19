#!/bin/zsh
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
install_preview=false
headless_tests=false
identity="DockClickToggle Local Code Signing"
for option in "$@"; do
  case "$option" in
    --install-preview) install_preview=true ;;
    --ad-hoc) identity="-" ;;
    --headless-tests) headless_tests=true ;;
    *) print -u2 -- "Unknown option: $option"; exit 2 ;;
  esac
done
if $install_preview && [[ "$identity" == "-" ]]; then
  print -u2 -- "Ad-hoc candidates are for isolated tests only; preview installation requires the stable signing identity."
  exit 2
fi
mkdir -p "$root/build"
stage="$(mktemp -d /private/tmp/real-build.XXXXXX)"
trap 'rm -rf "$stage"' EXIT
app="$stage/Real.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
snapshot="$stage/source"
mkdir -p "$snapshot"
cp "$root"/Sources/Real/*.swift "$root"/Tests/*.swift "$snapshot/"
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -parse-as-library -O -module-cache-path "$stage/module-cache" -D SYSTEM_KEY_POLICY_TESTS \
  "$snapshot"/*.swift \
  -framework AppKit -framework SwiftUI -framework EventKit -framework AVFoundation \
  -framework CoreAudio -framework IOKit -framework Carbon -framework QuickLookUI -framework ScreenCaptureKit -framework Accelerate -lz \
  -o "$app/Contents/MacOS/real"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
cp "$root/Resources/Translations.json" "$app/Contents/Resources/Translations.json"
cp "$root/Resources/Real.icns" "$app/Contents/Resources/Real.icns"
for locale in "$root"/Resources/*.lproj(N); do cp -R "$locale" "$app/Contents/Resources/"; done
cp "$root/Resources/mediaremote-adapter.pl" "$app/Contents/Resources/"
cp -R "$root/Resources/Licenses" "$app/Contents/Resources/"
ditto --noextattr --norsrc "$root/Vendor/MediaRemoteAdapter.framework" "$app/Contents/Frameworks/MediaRemoteAdapter.framework"
xattr -cr "$app"
codesign --force --sign "$identity" --timestamp=none "$app/Contents/Frameworks/MediaRemoteAdapter.framework"
codesign --force --sign "$identity" --timestamp=none \
  --entitlements "$root/Resources/real.entitlements" "$app"
codesign --verify --strict "$app"
if $headless_tests; then
  "$app/Contents/MacOS/real" --self-test-headless
else
  "$app/Contents/MacOS/real" --self-test
fi
# Keep the asynchronous lyric recovery suites in every package preflight.
zsh "$root/Scripts/test-lyrics.sh" "$snapshot"
archive="$root/build/real-independent.zip"
if [[ "$identity" == "-" ]]; then archive="$root/build/real-debug-adhoc.zip"; fi
ditto -c -k --keepParent --norsrc "$app" "$archive"
if $install_preview; then
  preview="$HOME/Applications/Real 预览.app"
  # A failed process inventory is not evidence that replacing an app is safe.
  if ! process_list="$(ps -axo command=)"; then
    print -u2 -- "Cannot inspect running processes; package created, preview left untouched."
    exit 1
  fi
  if print -r -- "$process_list" | /usr/bin/grep -Eq '/([Rr]eal|[Rr]eal 预览|real-independent-[0-9]+/real)\.app/Contents/MacOS/real'; then
    print -- "Running app preserved; updated candidate is in the ZIP."
  else
    mkdir -p "$(dirname "$preview")"
    ditto --noextattr --norsrc "$app" "$preview"
    codesign --verify --strict "$preview"
    print -r -- "$preview" > "$root/build/preview-app-path.txt"
  fi
fi
(cd "$snapshot" && shasum -a 256 *.swift) > "${archive%.zip}.sources.sha256"
print -- "Package: $archive"
