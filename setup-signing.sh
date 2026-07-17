#!/bin/bash
# Creates a self-signed code-signing identity in the login keychain so
# Screen Recording / Accessibility grants persist across rebuilds.
# One-time setup. Re-run safely; existing cert is left in place.
set -e

NAME="Pin Top Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# Skip if an identity with this name already exists.
if security find-identity 2>/dev/null | grep -q "\"$NAME\""; then
  echo "Identity \"$NAME\" already exists; nothing to do."
  exit 0
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

openssl req -new -newkey rsa:2048 -nodes \
  -subj "/CN=$NAME" \
  -keyout "$WORKDIR/key.pem" -out "$WORKDIR/req.pem"

cat > "$WORKDIR/ext.cnf" <<'EOF'
basicConstraints=CA:FALSE
keyUsage=digitalSignature
extendedKeyUsage=codeSigning
EOF

openssl x509 -req -in "$WORKDIR/req.pem" -signkey "$WORKDIR/key.pem" \
  -days 3650 -extfile "$WORKDIR/ext.cnf" -out "$WORKDIR/cert.pem"

# Bundle as a legacy p12 (SHA-1 MAC) so macOS `security import` accepts it.
openssl pkcs12 -export -legacy \
  -in "$WORKDIR/cert.pem" -inkey "$WORKDIR/key.pem" \
  -out "$WORKDIR/identity.p12" -name "$NAME" \
  -passout pass:wp-local-signing

security import "$WORKDIR/identity.p12" -k "$KEYCHAIN" \
  -P "wp-local-signing" -T /usr/bin/codesign -T /usr/bin/security

echo "Created identity \"$NAME\"."
echo "Note: it will appear as CSSMERR_TP_NOT_TRUSTED in security find-identity."
echo "That's expected for self-signed certs and is fine for codesign."