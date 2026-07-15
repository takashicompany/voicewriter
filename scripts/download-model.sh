#!/bin/zsh
# whisper.cpp用のggml-large-v3-turboモデル(約1.6GB)を
# ~/Library/Application Support/Voicewriter/models/ にダウンロードするスクリプト。
set -euo pipefail

# "main"ブランチではなく特定コミット(revision)を明示的に固定し、再現性を確保する。
# https://huggingface.co/api/models/ggerganov/whisper.cpp/revision/main で取得した時点のsha。
MODEL_REVISION="5359861c739e955e79d9a303bcbc70fb988958b1"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/${MODEL_REVISION}/ggml-large-v3-turbo.bin"
MODEL_FILENAME="ggml-large-v3-turbo.bin"
DEST_DIR="$HOME/Library/Application Support/Voicewriter/models"
DEST_PATH="$DEST_DIR/$MODEL_FILENAME"
# ダウンロード完了前のファイルはこの一時名で扱い、成功時にのみリネームする(中断時の壊れたファイル混入を防ぐ)
TMP_PATH="$DEST_PATH.part"

# 想定サイズ(バイト)。HuggingFace上の実サイズに合わせた大まかな下限チェック用。
MIN_EXPECTED_SIZE=1000000000

# 上記revisionからダウンロードした実ファイルのSHA-256(2026-07-15 に本スクリプトで検証済み)。
EXPECTED_SHA256="1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"

echo "==> Destination: $DEST_PATH"
mkdir -p "$DEST_DIR"

if [[ -f "$DEST_PATH" ]]; then
  EXISTING_SIZE=$(stat -f%z "$DEST_PATH" 2>/dev/null || echo 0)
  EXISTING_SHA256=$(shasum -a 256 "$DEST_PATH" 2>/dev/null | awk '{print $1}')
  if [[ "$EXISTING_SIZE" -gt "$MIN_EXPECTED_SIZE" && "$EXISTING_SHA256" == "$EXPECTED_SHA256" ]]; then
    echo "==> Model already present and verified ($EXISTING_SIZE bytes, sha256=$EXISTING_SHA256). Skipping download."
    echo "    Delete $DEST_PATH manually to force re-download."
    exit 0
  else
    echo "==> Existing file at $DEST_PATH is missing/incomplete/mismatched (size=$EXISTING_SIZE, sha256=$EXISTING_SHA256). Re-downloading."
    rm -f "$DEST_PATH"
  fi
fi

echo "==> Checking available disk space"
AVAIL_KB=$(df -k "$HOME" | tail -1 | awk '{print $4}')
AVAIL_BYTES=$((AVAIL_KB * 1024))
REQUIRED_BYTES=$((MIN_EXPECTED_SIZE + 500000000)) # モデル本体 + 余裕分
if [[ "$AVAIL_BYTES" -lt "$REQUIRED_BYTES" ]]; then
  echo "error: not enough free disk space. available=${AVAIL_BYTES} bytes, need roughly ${REQUIRED_BYTES} bytes" >&2
  exit 1
fi
echo "    OK ($((AVAIL_BYTES / 1024 / 1024)) MB available)"

echo "==> Downloading $MODEL_URL"
curl -L --fail --continue-at - -o "$TMP_PATH" "$MODEL_URL"

DOWNLOADED_SIZE=$(stat -f%z "$TMP_PATH" 2>/dev/null || echo 0)
if [[ "$DOWNLOADED_SIZE" -lt "$MIN_EXPECTED_SIZE" ]]; then
  echo "error: downloaded file smaller than expected ($DOWNLOADED_SIZE bytes). Aborting." >&2
  exit 1
fi

echo "==> Verifying SHA-256"
DOWNLOADED_SHA256=$(shasum -a 256 "$TMP_PATH" | awk '{print $1}')
if [[ "$DOWNLOADED_SHA256" != "$EXPECTED_SHA256" ]]; then
  echo "error: sha256 mismatch. expected=$EXPECTED_SHA256 actual=$DOWNLOADED_SHA256" >&2
  echo "       leaving partial file at $TMP_PATH for inspection; not installing it as $DEST_PATH" >&2
  exit 1
fi
echo "    OK (sha256=$DOWNLOADED_SHA256)"

mv "$TMP_PATH" "$DEST_PATH"
echo "==> Done: $DEST_PATH ($DOWNLOADED_SIZE bytes)"
