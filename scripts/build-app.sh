#!/bin/zsh
# SPM実行ファイルから Voicewriter.app バンドルを組み立てるスクリプト。
# XcodeGen/Xcodeプロジェクトを使わず、swift build + 手動バンドル化で.appを作る。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${(%):-%x}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIGURATION="${1:-release}"

echo "==> swift build (-c $CONFIGURATION)"
swift build -c "$CONFIGURATION" --package-path "$ROOT_DIR"

BIN_PATH="$(swift build -c "$CONFIGURATION" --package-path "$ROOT_DIR" --show-bin-path)"
EXECUTABLE="$BIN_PATH/Voicewriter"

if [[ ! -f "$EXECUTABLE" ]]; then
  echo "error: executable not found at $EXECUTABLE" >&2
  exit 1
fi

APP_DIR="$ROOT_DIR/build/Voicewriter.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"

echo "==> Assembling app bundle at $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$FRAMEWORKS_DIR"

cp "$EXECUTABLE" "$MACOS_DIR/Voicewriter"
cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"

# KeyboardShortcutsのリソースバンドル(ローカライズ文字列等)が生成されていればコピーする
if [[ -d "$BIN_PATH/KeyboardShortcuts_KeyboardShortcuts.bundle" ]]; then
  cp -R "$BIN_PATH/KeyboardShortcuts_KeyboardShortcuts.bundle" "$RESOURCES_DIR/"
fi

# whisper.xcframework(dynamic framework)をContents/Frameworksへ配置する。
# 実行ファイルのrpathは @executable_path/../Frameworks を指すよう Package.swift でリンク設定済み。
if [[ -d "$BIN_PATH/whisper.framework" ]]; then
  cp -R "$BIN_PATH/whisper.framework" "$FRAMEWORKS_DIR/"
else
  echo "error: whisper.framework not found at $BIN_PATH (whisper.cpp integration will not work)" >&2
  exit 1
fi

# 署名identityの決定:
# - VOICEWRITER_SIGN_IDENTITY が指定されていればそれを使う
# - 未指定なら、ログインキーチェーンに"Voicewriter Dev Signing"(自己署名のコード署名用証明書)が
#   あればそれを使う(再ビルドのたびに同じ証明書で署名されるため、designated requirementの
#   `certificate leaf = H"..."`が安定し、TCC(アクセシビリティ等)の許可がリビルドをまたいで維持される)
# - どちらも無ければ従来通りアドホック署名("-")にフォールバックする
if [[ -n "${VOICEWRITER_SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY="$VOICEWRITER_SIGN_IDENTITY"
elif security find-identity -p codesigning 2>/dev/null | grep -q "Voicewriter Dev Signing"; then
  SIGN_IDENTITY="Voicewriter Dev Signing"
else
  SIGN_IDENTITY="-"
fi

echo "==> Code signing (identity: $SIGN_IDENTITY)"
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_DIR"

echo "==> Done: $APP_DIR"
