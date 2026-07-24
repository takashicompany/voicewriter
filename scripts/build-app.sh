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

# アプリアイコン(.icns)。Info.plistのCFBundleIconFile="AppIcon"に対応させるため
# ファイル名はAppIcon.icnsのままContents/Resourcesへ配置する。
if [[ -f "$ROOT_DIR/Resources/AppIcon.icns" ]]; then
  cp "$ROOT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
else
  echo "warning: $ROOT_DIR/Resources/AppIcon.icns not found (app will use the default generic icon)" >&2
fi

# メニューバー用ブランドグリフ(1x/2x PNG)。StatusBarControllerがBundle.main.resourcePath配下の
# MenuBarIcon/を実行時に読むため、Contents/Resourcesにそのままコピーする。
if [[ -d "$ROOT_DIR/Resources/MenuBarIcon" ]]; then
  mkdir -p "$RESOURCES_DIR/MenuBarIcon"
  cp "$ROOT_DIR/Resources/MenuBarIcon/"*.png "$RESOURCES_DIR/MenuBarIcon/"
fi

# KeyboardShortcutsのリソースバンドル(ローカライズ文字列等)が生成されていればコピーする。
# Contents/Resources/への配置が正規の配置場所(vendor/KeyboardShortcutsのUtilities.swiftが
# ここを最優先で探す。2026-07-24: 配布先で「設定→ショートカット」タブを開くとクラッシュする
# 不具合の原因調査・修正の詳細はそちらのコメント参照。かつてはここに.appバンドル直下への
# コピーも追加しようとしたが、macOSの.appはContents/配下のみが正規の内容物であり、
# `codesign`が直下(Contents外)の内容物を「unsealed contents present in the bundle root」
# として署名を拒否するため断念した)。
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

# Hardened Runtimeの有無:
# - 既定(VOICEWRITER_HARDENED未指定 or 0)では従来通り付けない(自己署名配布では公証もできず、
#   Hardened Runtimeを付けてもメリットが無いため)
# - VOICEWRITER_HARDENED=1 を指定すると `-o runtime` を付け、mainの実行ファイルには
#   Resources/Voicewriter.entitlements (マイク入力のみ) を紐付ける。将来Apple Developer Program
#   に加入し公証(notarization)へ移行する際は、正式なDeveloper ID証明書を
#   VOICEWRITER_SIGN_IDENTITY に指定した上でこのフラグを立てる想定。
HARDENED="${VOICEWRITER_HARDENED:-0}"
FRAMEWORK_SIGN_ARGS=()
APP_SIGN_ARGS=()
if [[ "$HARDENED" == "1" ]]; then
  echo "==> Hardened Runtime: enabled (-o runtime)"
  FRAMEWORK_SIGN_ARGS+=(-o runtime)
  APP_SIGN_ARGS+=(-o runtime --entitlements "$ROOT_DIR/Resources/Voicewriter.entitlements")
else
  echo "==> Hardened Runtime: disabled (default)"
fi

# コード署名(inside-out): --deep は macOS 13以降 man codesign 上でDEPRECATED指定のため使わない。
# 代わりにvendor由来のネストしたコード(whisper.frameworkの実体dylib)を先に個別署名し、
# 最後に.app本体を署名する。既に有効な署名を持つネストしたコードは、.app本体の署名時に
# (--deepなしでも)そのまま尊重される。
# 現行のvendor/whisper.xcframeworkは"Versions/A"固定でパスを直書きしている。将来ベンダーの
# xcframeworkが別バージョン識別子(Versions/B等)を使うようになった場合はこのパスも追随して
# 更新すること(上のエラーメッセージで検知できる)。
WHISPER_DYLIB="$FRAMEWORKS_DIR/whisper.framework/Versions/A/whisper"
if [[ ! -f "$WHISPER_DYLIB" ]]; then
  echo "error: whisper dylib not found at $WHISPER_DYLIB" >&2
  exit 1
fi

echo "==> Code signing whisper.framework dylib (identity: $SIGN_IDENTITY)"
codesign --force --sign "$SIGN_IDENTITY" "${FRAMEWORK_SIGN_ARGS[@]}" "$WHISPER_DYLIB"

echo "==> Code signing $APP_DIR (identity: $SIGN_IDENTITY)"
codesign --force --sign "$SIGN_IDENTITY" "${APP_SIGN_ARGS[@]}" "$APP_DIR"

echo "==> Done: $APP_DIR"
