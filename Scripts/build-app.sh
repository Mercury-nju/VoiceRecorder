#!/bin/zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$(cd "$PROJECT_DIR/.." && pwd)/outputs"
APP_PATH="$OUTPUT_DIR/VoiceRecorder.app"

cd "$PROJECT_DIR"
BIN_PATH="$(swift build -c release --show-bin-path)"
swift build -c release

rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BIN_PATH/VoiceRecorder" "$APP_PATH/Contents/MacOS/VoiceRecorder"
cp "$PROJECT_DIR/Support/Info.plist" "$APP_PATH/Contents/Info.plist"
printf 'APPL????' > "$APP_PATH/Contents/PkgInfo"

# 临时本地构建使用 ad-hoc 签名；正式分发时应改用 Developer ID 签名并公证。
codesign --force --deep --sign - "$APP_PATH"

echo "Built: $APP_PATH"
