#!/bin/zsh
# whisper.cpp用のVAD(Voice Activity Detection)モデル ggml-silero-v5.1.2(約860KB)を
# ~/Library/Application Support/Voicewriter/models/ にダウンロードするスクリプト。
# VADは既定OFFの任意機能で、設定画面から有効化した場合のみこのモデルを使用する
# (WhisperCppEngine.swift参照)。
set -euo pipefail

MODEL_URL="https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin"
MODEL_FILENAME="ggml-silero-v5.1.2.bin"
DEST_DIR="$HOME/Library/Application Support/Voicewriter/models"
DEST_PATH="$DEST_DIR/$MODEL_FILENAME"
TMP_PATH="$DEST_PATH.part"

# 想定サイズ(バイト)。HuggingFace上の実サイズ(885,098バイト)に合わせた下限チェック用。
MIN_EXPECTED_SIZE=800000

# 2026-07-15 に本スクリプトで検証済みのSHA-256。
EXPECTED_SHA256="29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf"

echo "==> Destination: $DEST_PATH"
mkdir -p "$DEST_DIR"

if [[ -f "$DEST_PATH" ]]; then
  EXISTING_SIZE=$(stat -f%z "$DEST_PATH" 2>/dev/null || echo 0)
  EXISTING_SHA256=$(shasum -a 256 "$DEST_PATH" 2>/dev/null | awk '{print $1}')
  if [[ "$EXISTING_SIZE" -gt "$MIN_EXPECTED_SIZE" && "$EXISTING_SHA256" == "$EXPECTED_SHA256" ]]; then
    echo "==> VAD model already present and verified ($EXISTING_SIZE bytes, sha256=$EXISTING_SHA256). Skipping download."
    echo "    Delete $DEST_PATH manually to force re-download."
    exit 0
  else
    echo "==> Existing file at $DEST_PATH is missing/incomplete/mismatched (size=$EXISTING_SIZE, sha256=$EXISTING_SHA256). Re-downloading."
    rm -f "$DEST_PATH"
  fi
fi

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
