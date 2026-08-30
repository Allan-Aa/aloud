#!/usr/bin/env bash
# 用 SPM 编译 + 手工组装 .app。不走 xcodebuild:这个项目没有 .xcodeproj,
# 也不需要——SwiftUI 只要 SDK 在就能编。
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="build/念.app"
SIGN_ID="${CODESIGN_IDENTITY:--}"

echo "▸ swift build ($CONFIG)"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Aloud"

echo "▸ 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Aloud"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/Aloud.icns "$APP/Contents/Resources/"
cp Resources/menubar.png Resources/menubar@2x.png "$APP/Contents/Resources/"

echo "▸ 签名 ($SIGN_ID)"
codesign --force --sign "$SIGN_ID" "$APP"
codesign -dvvv "$APP" 2>&1 | grep -E "^Authority|^Identifier"

echo "▸ 完成: $APP"
