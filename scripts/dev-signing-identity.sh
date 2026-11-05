#!/usr/bin/env bash
# For development and testing only: create a self-signed code-signing identity called
# "Cursor Pilot Development" in your login keychain. scripts/build-app.sh signs with it when it
# exists and CODESIGN_IDENTITY isn't set, so every build has the same designated requirement
# (`identifier "com.louistuis.cursorpilot" and certificate leaf = H"..."`) instead of a new ad-hoc
# hash, and macOS keeps Microphone, Speech Recognition, Screen Recording and the keychain entry
# across rebuilds.
#
# It is not a Developer ID. Other Macs treat an app signed with it like an unsigned app, it can't
# be notarized, and nobody but you trusts it. Shipping still needs a Developer ID.
#
#   scripts/dev-signing-identity.sh           create it (once; does nothing if it exists)
#   scripts/dev-signing-identity.sh --check   say whether it exists, and its SHA-1
#
# Needs no administrator password and changes no trust settings: codesign accepts an untrusted
# self-signed certificate, and macOS's privacy settings compare only the certificate's hash. The
# first build that uses it may ask whether codesign may use the key: click Always Allow.
#
# For testing this script: CP_DEV_KEYCHAIN=<path> uses another keychain (it must be in the
# keychain search list for codesign to find the identity), and CP_DEV_KEYCHAIN_PASSWORD, when
# set, lets codesign use the key without asking (security set-key-partition-list).
set -euo pipefail

NAME="Cursor Pilot Development"
KEYCHAIN="${CP_DEV_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
OPENSSL=/usr/bin/openssl # LibreSSL from macOS: its .p12 files are ones `security import` reads

die() { echo "dev-signing-identity: $*" >&2; exit 1; }
[[ "$(uname -s)" == Darwin ]] || die "run this on macOS"

# The SHA-1 of the identity in $KEYCHAIN, or nothing. (Read whole, then searched: no broken pipe.)
identity_hash() {
  local ids
  ids="$(security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null || true)"
  awk -v name="\"$NAME\"" 'index($0, name) { print $2; exit }' <<<"$ids"
}

EXISTING="$(identity_hash)"
if [[ "${1:-}" == "--check" ]]; then
  if [[ -n "$EXISTING" ]]; then echo "$NAME: $EXISTING"; exit 0; fi
  echo "$NAME: not found in $KEYCHAIN"
  exit 1
fi
if [[ -n "$EXISTING" ]]; then
  echo "$NAME already exists ($EXISTING). Nothing to do."
  exit 0
fi
[[ -f "$KEYCHAIN" ]] || die "no keychain at $KEYCHAIN"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
umask 077

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

echo "Creating a self-signed code-signing certificate \"$NAME\" (valid for 10 years)"
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null || die "openssl couldn't make the certificate"
PASS="$("$OPENSSL" rand -hex 16)"
"$OPENSSL" pkcs12 -export -name "$NAME" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/identity.p12" -passout "pass:$PASS" || die "openssl couldn't package the identity"

echo "Adding it to $KEYCHAIN"
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null \
  || die "the keychain didn't accept the identity"
if [[ -n "${CP_DEV_KEYCHAIN_PASSWORD:-}" ]]; then
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$CP_DEV_KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null \
    || die "couldn't let codesign use the key without asking"
fi

HASH="$(identity_hash)"
[[ -n "$HASH" ]] || die "the identity isn't in $KEYCHAIN after importing it"

# Prove that codesign can use it and that the signature names the certificate, not a hash.
if security list-keychains -d user | grep -qF "$KEYCHAIN"; then
  cp /usr/bin/true "$TMP/probe"
  codesign --force --sign "$HASH" "$TMP/probe" 2>/dev/null || die "codesign can't sign with it"
  REQ="$(codesign -d -r - "$TMP/probe" 2>&1 || true)"
  [[ "$REQ" == *"certificate leaf = H\"$(tr 'A-F' 'a-f' <<<"$HASH")\""* ]] || die "unexpected designated requirement: $REQ"
  echo "codesign works with it: $(grep designated <<<"$REQ")"
else
  echo "Note: $KEYCHAIN isn't in the keychain search list, so codesign won't find the identity there."
fi

echo
echo "Done: \"$NAME\" ($HASH)."
echo "scripts/build-app.sh now signs with it when CODESIGN_IDENTITY isn't set."
echo "After the next build, grant Cursor Pilot's permissions once more; they then survive rebuilds."
echo "This is for development and testing. Shipping still needs a Developer ID."
