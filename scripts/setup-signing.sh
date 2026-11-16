#!/bin/bash
# Creates a self-signed code-signing certificate ("Floaty Dev") in the login
# keychain so macOS keeps Floaty's Screen Recording permission across rebuilds.
# Run once. Safe to re-run: it does nothing if the identity already exists.
set -euo pipefail

NAME="Floaty Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "Signing identity '$NAME' already exists."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.conf" <<EOF
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

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.conf" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/floaty.p12" -passout pass:floaty -name "$NAME"

security import "$WORK/floaty.p12" -k "$KEYCHAIN" -P floaty -T /usr/bin/codesign
echo "Created signing identity '$NAME'."
