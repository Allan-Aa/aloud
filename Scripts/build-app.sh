#!/bin/zsh
set -euo pipefail

repo_dir=${0:A:h:h}
cd "$repo_dir"

xcrun swift Scripts/voice-samples.swift validate
swift build -c release
bin_dir=$(swift build -c release --show-bin-path)
stage=$(mktemp -d /tmp/aloud-app.XXXXXX)
trap 'rm -rf "$stage"' EXIT
app="$stage/念.app"
sign_identity="${CODESIGN_IDENTITY:--}"

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Info.plist "$app/Contents/Info.plist"
cp "$bin_dir/Aloud" "$app/Contents/MacOS/Aloud"
cp Resources/Aloud.icns Resources/menubar.png Resources/menubar@2x.png "$app/Contents/Resources/"
ditto "$bin_dir/Aloud_Aloud.bundle" "$app/Contents/Resources/Aloud_Aloud.bundle"
codesign --force --deep --options runtime --timestamp=none --sign "$sign_identity" "$app"
codesign --verify --deep --strict "$app"
rm -rf build/念.app
ditto "$app" build/念.app
