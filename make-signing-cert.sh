#!/bin/bash
# One-time setup: creates a self-signed "MeetingNotes Local" code-signing certificate in your login keychain.
# build.sh signs Hoot with it, so the app keeps the same identity across rebuilds and macOS remembers
# the Microphone and Screen & System Audio Recording permissions instead of silently dropping them.
set -euo pipefail
NAME="MeetingNotes Local"

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "\"$NAME\" already exists — nothing to do."
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
# -legacy keeps the .p12 readable by macOS's `security` with OpenSSL 3; LibreSSL doesn't need it.
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/id.p12" -passout pass:hoot 2>/dev/null ||
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/id.p12" -passout pass:hoot
security import "$TMP/id.p12" -k ~/Library/Keychains/login.keychain-db -P hoot -T /usr/bin/codesign
echo "Created \"$NAME\". Now run: ./build.sh install"
