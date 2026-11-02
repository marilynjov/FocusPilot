#!/bin/sh
# Builds FocusPilot.app into ./build, signed ad hoc for this Mac only.
#
# SwiftPM produces a bare executable; SMAppService and LSUIElement need a real
# app bundle with an Info.plist, so this script assembles one around it.
# Ad hoc signing ("-") needs no Apple Developer membership, but the app will
# only run on the Mac that built it.
set -eu

cd "$(dirname "$0")/.."

swift build --configuration release --product FocusPilot
swift build --configuration release --product RenderArtwork
swift build --configuration release --product focuspilot-cli
swift build --configuration release --product focuspilot-chrome-host
bin=$(swift build --configuration release --show-bin-path)

# Absolute: actool runs through a long-lived helper that may resolve relative
# paths against another directory.
app="$PWD/build/FocusPilot.app"
artwork="$PWD/build/artwork"
rm -rf "$app" "$artwork"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources" "$artwork"
cp "$bin/FocusPilot" "$app/Contents/MacOS/FocusPilot"
# The focuspilot command for Herdr panes. It lives in Helpers because
# MacOS/focuspilot and MacOS/FocusPilot would be the same file on a
# case-insensitive volume.
cp "$bin/focuspilot-cli" "$app/Contents/Helpers/focuspilot"
# Chrome's native messaging host; the app points Chrome's per-user host
# manifest at it on launch.
cp "$bin/focuspilot-chrome-host" "$app/Contents/Helpers/focuspilot-chrome-host"
cp Packaging/Info.plist "$app/Contents/Info.plist"
# The raccoon companion's layer strips and raccoon.json, committed output of
# scripts/build-raccoon-art.sh.
cp -R Packaging/Raccoon "$app/Contents/Resources/Raccoon"

# The Chrome extension, copied by the app to its stable folder in
# Application Support, where the owner loads it once. Icons are generated.
cp -R Extensions/Chrome "$app/Contents/Resources/ChromeExtension"
# A build stamp from the extension's sources: when it changes, the running
# extension sees a different build on disk and reloads itself.
build_stamp=$(find Extensions/Chrome -type f | LC_ALL=C sort | xargs shasum | shasum | cut -c1-8)
sed -i '' "s/(development)/build $build_stamp/" "$app/Contents/Resources/ChromeExtension/manifest.json"
"$bin/RenderArtwork" chrome-icons "$app/Contents/Resources/ChromeExtension/icons"

# The app icon is generated from the logo geometry (FocusPilotCore/AppIcon),
# then compiled by actool into Assets.car plus an .icns fallback. actool
# reports the Info.plist keys that name the icon; merge them in.
"$bin/RenderArtwork" icon "$artwork/AppIcon.icon"
xcrun actool "$artwork/AppIcon.icon" \
    --compile "$app/Contents/Resources" \
    --platform macosx --minimum-deployment-target 26.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$artwork/icon-info.plist" \
    --errors --warnings --output-format human-readable-text
/usr/libexec/PlistBuddy -c "Merge \"$artwork/icon-info.plist\"" "$app/Contents/Info.plist"
# Nested code is signed before the bundle that contains it.
codesign --force --sign - "$app/Contents/Helpers/focuspilot"
codesign --force --sign - "$app/Contents/Helpers/focuspilot-chrome-host"
codesign --force --sign - "$app"

echo "Built $app"
