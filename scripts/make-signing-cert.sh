#!/bin/zsh
# Creates a self-signed "Velora Dev Signing" code-signing identity in the
# login keychain (one-time, ~10s). Why: ad-hoc signatures change on every
# rebuild, and macOS TCC pins permission grants (Microphone, Accessibility)
# to the signature — so with ad-hoc signing every rebuild silently invalidates
# the grants even though System Settings still shows them ON. A stable
# self-signed identity keeps grants working across rebuilds.
set -euo pipefail

NAME="Velora Dev Signing"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "OK: '$NAME' identity already exists"
  exit 0
fi

DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT

cat > "$DIR/velora.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3_codesign
prompt = no
[dn]
CN = $NAME
[v3_codesign]
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
basicConstraints = critical,CA:false
EOF

openssl req -x509 -newkey rsa:2048 -keyout "$DIR/velora.key" -out "$DIR/velora.crt" \
  -days 3650 -nodes -config "$DIR/velora.cnf" 2>/dev/null
openssl pkcs12 -export -out "$DIR/velora.p12" -inkey "$DIR/velora.key" \
  -in "$DIR/velora.crt" -passout pass:velora 2>/dev/null

security import "$DIR/velora.p12" -k ~/Library/Keychains/login.keychain-db \
  -P velora -T /usr/bin/codesign
security add-trusted-cert -p codeSign -k ~/Library/Keychains/login.keychain-db \
  "$DIR/velora.crt" || true

security find-identity -v -p codesigning | grep "$NAME" && echo "OK: '$NAME' created"
echo "Note: after switching from ad-hoc to this identity, re-grant Microphone,"
echo "Input Monitoring, and Accessibility once (remove stale Velora entries first)."
