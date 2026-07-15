#!/bin/zsh
# ログインキーチェーンに、ローカル開発用の自己署名コード署名証明書("Voicewriter Dev Signing")を
# 非対話で作成するスクリプト。
#
# 背景: build-app.shは元々アドホック署名(codesign --sign -)を使っていたが、これはビルドごとに
# 実行ファイルの内容から署名identityを算出するため、再ビルドのたびに署名が変わり、TCC
# (アクセシビリティ等のプライバシー許可)が「別アプリ」とみなされて許可がリセットされてしまう。
# 同一の証明書で署名し続ければ、designated requirementの`certificate leaf`部分が安定するため、
# TCCの許可がリビルドをまたいで維持される。
#
# 手法: Keychain AccessアプリのCertificate Assistant(証明書アシスタント)の
# 「自己署名ルート証明書 > コード署名」機能をCLIで代替するため、
# openssl で extendedKeyUsage=codeSigning の自己署名証明書を作成し、
# `security import`でログインキーチェーンへ登録する。
#
# 既に同名の証明書がキーチェーンにあれば何もせず終了する(再実行安全)。
set -euo pipefail

IDENTITY_NAME="${VOICEWRITER_SIGN_IDENTITY_NAME:-Voicewriter Dev Signing}"
KEYCHAIN="${VOICEWRITER_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"

if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "\"$IDENTITY_NAME\""; then
  echo "==> \"$IDENTITY_NAME\" は既にキーチェーンに存在します。再利用します。"
  exit 0
fi

echo "==> \"$IDENTITY_NAME\" が見つからないため、新規に自己署名のコード署名証明書を作成します。"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

KEY_FILE="$WORKDIR/dev-signing.key"
CRT_FILE="$WORKDIR/dev-signing.crt"
P12_FILE="$WORKDIR/dev-signing.p12"
OPENSSL_CONF="$WORKDIR/openssl.cnf"

cat > "$OPENSSL_CONF" <<EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_ca
prompt = no
[req_distinguished_name]
CN = $IDENTITY_NAME
[v3_ca]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

echo "==> openssl で秘密鍵+自己署名証明書(extendedKeyUsage=codeSigning)を生成"
openssl req -x509 -newkey rsa:2048 -keyout "$KEY_FILE" -out "$CRT_FILE" \
  -days 3650 -nodes -config "$OPENSSL_CONF"

# p12へ詰めるための一時パスワード(importが終われば不要、WORKDIRごと破棄される)
P12_PASS="$(openssl rand -base64 24)"

echo "==> PKCS#12にまとめてログインキーチェーンへimport"
openssl pkcs12 -export -inkey "$KEY_FILE" -in "$CRT_FILE" \
  -name "$IDENTITY_NAME" -out "$P12_FILE" -passout "pass:$P12_PASS"

# -T /usr/bin/codesign でcodesignからのアクセスを明示的に許可しておくことで、
# security set-key-partition-list(ログインパスワードが必要)を使わずに済む。
security import "$P12_FILE" -k "$KEYCHAIN" -P "$P12_PASS" \
  -T /usr/bin/codesign -T /usr/bin/security

echo "==> 作成完了。security find-identity -p codesigning で確認できます"
echo "    (注: 自己署名のためtrust設定上は「信頼されていない」扱いのままですが、"
echo "     -T /usr/bin/codesignの許可により codesign --sign \"$IDENTITY_NAME\" は正常に動作します)"
security find-identity -p codesigning "$KEYCHAIN" | grep "$IDENTITY_NAME" || true
