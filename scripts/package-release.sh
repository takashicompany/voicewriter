#!/bin/zsh
# 配布用zipパッケージを作成するスクリプト。
#
# 1. scripts/build-app.sh release でVoicewriter.appをビルド
# 2. ditto -c -k --keepParent で build/Voicewriter.app を dist/Voicewriter-vX.Y.Z.zip に圧縮
#    (ditto はZIP内にmacOS拡張属性・リソースフォーク・コード署名を保持するため、
#    macOS向けアプリの配布zip作成では `zip` コマンドより ditto が推奨される)
# 3. 生成したzipのSHA-256を出力(受け取り側が改ざん確認に使えるように)
#
# バージョン番号の決定:
# - 引数(第1引数、例: ./scripts/package-release.sh 1.2.0)があればそれを使う
# - 無ければ Resources/Info.plist の CFBundleShortVersionString を使う
# - Info.plistにCFBundleShortVersionStringが無ければ 1.0.0 を設定してから使う
# いずれの場合も、決定したバージョンは(Info.plistの値と異なっていれば)Resources/Info.plistへ
# 書き戻してからビルドする。こうしないと、引数でバージョンを指定した場合にzipファイル名と
# ビルドされたアプリ内のCFBundleShortVersionStringが食い違ってしまうため。
# 注意: 書き戻しには /usr/libexec/PlistBuddy を使うため、値に変更が生じた回はplist全体が
# キー名アルファベット順・タブインデントに整形し直される(内容的な差分はバージョン文字列のみ)。
# コミット前に `git diff Resources/Info.plist` でバージョン以外に意図しない差分が無いか確認すること。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${(%):-%x}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INFO_PLIST="$ROOT_DIR/Resources/Info.plist"

VERSION="${1:-}"

if [[ -z "$VERSION" ]]; then
  if ! /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST" >/dev/null 2>&1; then
    echo "==> Resources/Info.plist に CFBundleShortVersionString が無いため 1.0.0 を設定します"
    /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string 1.0.0" "$INFO_PLIST"
  fi
  VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST")"
fi

# ファイル名・plist値として安全な文字種のみ許可する(空白・パス区切り文字等の混入を防ぐ)
if [[ ! "$VERSION" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "error: invalid version string: '$VERSION' (allowed: letters, digits, '.', '_', '-')" >&2
  exit 1
fi

CURRENT_PLIST_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST" 2>/dev/null || echo "")"
if [[ "$CURRENT_PLIST_VERSION" != "$VERSION" ]]; then
  echo "==> Resources/Info.plist の CFBundleShortVersionString を $VERSION に更新します"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$INFO_PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$INFO_PLIST"
fi

echo "==> Packaging version: $VERSION"

echo "==> Building release app bundle"
"$SCRIPT_DIR/build-app.sh" release

APP_DIR="$ROOT_DIR/build/Voicewriter.app"
if [[ ! -d "$APP_DIR" ]]; then
  echo "error: $APP_DIR not found (build-app.sh failed?)" >&2
  exit 1
fi

DIST_DIR="$ROOT_DIR/dist"
mkdir -p "$DIST_DIR"
ZIP_PATH="$DIST_DIR/Voicewriter-v${VERSION}.zip"

echo "==> Creating $ZIP_PATH"
rm -f "$ZIP_PATH"
# --keepParent: zip展開時に "Voicewriter.app" ディレクトリごと展開されるようにする
# (中身だけが展開されてFinderで扱いにくくなるのを防ぐ)
ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"

echo "==> SHA-256:"
shasum -a 256 "$ZIP_PATH"

echo "==> Done: $ZIP_PATH"
