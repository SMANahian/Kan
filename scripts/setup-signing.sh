#!/usr/bin/env bash
#
# One-time setup of the local code-signing identity "Kan Local Code Signing".
#
# Usage: scripts/setup-signing.sh [--status]
#
#   (no flags)  create the identity if needed (idempotent) and print its SHA-1
#   --status    only report whether the identity exists (exit 1 if not); changes nothing
#
# Why: macOS ties Kan's privacy permissions (Microphone, System Audio Recording, Automation…) to
# the app's designated requirement. An ad-hoc signature's requirement is its cdhash, which changes
# with every build, so every rebuild would lose them. Signing with this certificate gives
#   identifier "com.nahian.Kan" and certificate root = H"<certificate SHA-1>"
# which stays the same across rebuilds.
#
# Creates, in ~/Library/Application Support/Kan/Signing (override with KAN_SIGNING_DIR):
#   kan-signing.keychain-db   a dedicated keychain holding the identity
#   keychain-password         its random password (mode 600)
#   kan-signing-cert.pem      the public certificate
#   home/                     a private HOME whose keychain search list is only that keychain
#
# An existing identity is always kept: a new one means a new requirement, and macOS then asks for
# every permission again. Back up the Signing folder.
#
# Never touches the login keychain, the default keychain or your keychain search list; both are
# compared before and after. The certificate is self-signed and untrusted, which is fine: codesign
# doesn't need trust, and Gatekeeper doesn't assess apps you build on this Mac.

set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=lib/common.sh
source "$ROOT/scripts/lib/common.sh"

OPENSSL=/usr/bin/openssl   # LibreSSL: its PKCS#12 defaults import on every macOS version
SECURITY=/usr/bin/security
VALID_DAYS=3650

STATUS_ONLY=0
case "${1:-}" in
  "") ;;
  --status) STATUS_ONLY=1 ;;
  -h | --help) print_usage; exit 0 ;;
  *) die "unknown option: $1 (see --help)" ;;
esac

print_identity() {
  local sha1="$1" end
  ok "identity \"$KAN_SIGNING_IDENTITY\""
  info "SHA-1:     $sha1"
  if [[ -f "$KAN_SIGNING_CERT" ]]; then
    end="$("$OPENSSL" x509 -in "$KAN_SIGNING_CERT" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"
    info "valid to:  $end"
  fi
  info "keychain:  $KAN_SIGNING_KEYCHAIN"
  info "requirement of apps signed with it:"
  info "  identifier \"$KAN_BUNDLE_ID\" and certificate root = H\"$(printf '%s' "$sha1" | tr 'A-F' 'a-f')\""
}

if [[ "$STATUS_ONLY" == 1 ]]; then
  SHA1="$(signing_identity_sha1)"
  if [[ -n "$SHA1" ]]; then print_identity "$SHA1"; exit 0; fi
  echo "No Kan signing identity in $KAN_SIGNING_DIR (run scripts/setup-signing.sh)."
  exit 1
fi

[[ -x "$OPENSSL" ]] || die "$OPENSSL not found"

# --- Snapshot what must not change ----------------------------------------------------------------

USER_PREFS="$HOME/Library/Preferences/com.apple.security.plist"
prefs_state() { if [[ -f "$USER_PREFS" ]]; then /usr/bin/stat -f '%m %z' "$USER_PREFS"; else echo absent; fi; }
LIST_BEFORE="$("$SECURITY" list-keychains -d user)"
DEFAULT_BEFORE="$("$SECURITY" default-keychain -d user)"
PREFS_BEFORE="$(prefs_state)"

WORK=""
cleanup() { if [[ -n "$WORK" ]]; then rm -rf "${WORK:?}"; fi; }
trap cleanup EXIT

mkdir -p "$KAN_SIGNING_DIR" "$KAN_SIGNING_HOME/Library/Preferences"
chmod 700 "$KAN_SIGNING_DIR"
WORK="$(mktemp -d "$KAN_SIGNING_DIR/.tmp.XXXXXX")"

# --- Keychain --------------------------------------------------------------------------------------

if [[ -f "$KAN_SIGNING_KEYCHAIN" ]]; then
  [[ -f "$KAN_SIGNING_PASSWORD_FILE" ]] ||
    die "$KAN_SIGNING_KEYCHAIN exists but $KAN_SIGNING_PASSWORD_FILE is missing. Restore it from a backup, or delete the Signing folder to start over (macOS will then ask for Kan's permissions again)."
  step "Using the existing signing keychain"
else
  step "Creating the signing keychain"
  "$OPENSSL" rand -hex 24 > "$KAN_SIGNING_PASSWORD_FILE"
  chmod 600 "$KAN_SIGNING_PASSWORD_FILE"
  # HOME redirect: create-keychain adds the new keychain to the search list, which must be the
  # private one, not yours.
  HOME="$KAN_SIGNING_HOME" "$SECURITY" create-keychain -p "$(cat "$KAN_SIGNING_PASSWORD_FILE")" "$KAN_SIGNING_KEYCHAIN"
  # No auto-lock timeout. ALWAYS pass the path: without one this edits the login keychain.
  "$SECURITY" set-keychain-settings "$KAN_SIGNING_KEYCHAIN"
fi
signing_unlock

# --- Identity --------------------------------------------------------------------------------------

SHA1="$(signing_identity_sha1)"
if [[ -n "$SHA1" ]]; then
  ok "identity \"$KAN_SIGNING_IDENTITY\" already exists; keeping it"
else
  step "Creating the self-signed identity \"$KAN_SIGNING_IDENTITY\""
  cat > "$WORK/cert.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions    = ext
prompt             = no
[ dn ]
CN = $KAN_SIGNING_IDENTITY
O  = Kan (local self-signed)
[ ext ]
basicConstraints     = critical, CA:false
keyUsage             = critical, digitalSignature
extendedKeyUsage     = critical, codeSigning
subjectKeyIdentifier = hash
EOF
  "$OPENSSL" req -x509 -newkey rsa:2048 -sha256 -days "$VALID_DAYS" -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.cnf" 2>/dev/null ||
    die "openssl could not create the certificate"
  P12_PASSWORD="$("$OPENSSL" rand -hex 16)"
  "$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$KAN_SIGNING_IDENTITY" \
    -out "$WORK/identity.p12" -passout "pass:$P12_PASSWORD" ||
    die "openssl could not package the identity"
  # `security import` prints nothing on success; the find-identity below is the real check.
  "$SECURITY" import "$WORK/identity.p12" -k "$KAN_SIGNING_KEYCHAIN" -f pkcs12 -P "$P12_PASSWORD" \
    -T /usr/bin/codesign >/dev/null
  # Lets codesign use the key without the "codesign wants to sign using key…" dialog.
  "$SECURITY" set-key-partition-list -S apple-tool:,apple:,codesign: -s \
    -k "$(cat "$KAN_SIGNING_PASSWORD_FILE")" "$KAN_SIGNING_KEYCHAIN" >/dev/null
  cp "$WORK/cert.pem" "$KAN_SIGNING_CERT"
  SHA1="$(signing_identity_sha1)"
  [[ -n "$SHA1" ]] || die "the identity was imported but codesign can't see it in $KAN_SIGNING_KEYCHAIN"
fi

if [[ ! -f "$KAN_SIGNING_CERT" ]]; then
  "$SECURITY" find-certificate -c "$KAN_SIGNING_IDENTITY" -p "$KAN_SIGNING_KEYCHAIN" > "$KAN_SIGNING_CERT"
fi
chmod 644 "$KAN_SIGNING_CERT"
CERT_SHA1="$("$OPENSSL" x509 -in "$KAN_SIGNING_CERT" -noout -fingerprint -sha1 | sed 's/^.*=//; s/://g' | tr 'a-f' 'A-F')"
[[ "$CERT_SHA1" == "$SHA1" ]] ||
  die "$KAN_SIGNING_CERT (SHA-1 $CERT_SHA1) doesn't match the keychain identity ($SHA1)"

# --- Private search list ---------------------------------------------------------------------------

HOME="$KAN_SIGNING_HOME" "$SECURITY" list-keychains -d user -s "$KAN_SIGNING_KEYCHAIN"

# --- Prove that codesign can use it ----------------------------------------------------------------

cp /usr/bin/true "$WORK/probe"
codesign_with_identity "$SHA1" --force --timestamp=none --identifier "$KAN_BUNDLE_ID.signing-probe" \
  "$WORK/probe" 2>/dev/null || die "codesign could not sign with the identity (see: HOME=\"$KAN_SIGNING_HOME\" codesign …)"
PROBE_DR="$(designated_requirement "$WORK/probe")"
[[ "$PROBE_DR" == *"certificate root = H\""* ]] ||
  die "unexpected designated requirement for a test signature: $PROBE_DR"

# --- Nothing of yours changed ----------------------------------------------------------------------

LIST_AFTER="$("$SECURITY" list-keychains -d user)"
if [[ "$LIST_AFTER" != "$LIST_BEFORE" ]]; then
  # Never expected; restore the exact previous list.
  warn "your keychain search list changed; restoring it"
  RESTORE=()
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line#\"}"
    line="${line%\"}"
    if [[ -n "$line" ]]; then RESTORE+=("$line"); fi
  done <<< "$LIST_BEFORE"
  if [[ ${#RESTORE[@]} -gt 0 ]]; then "$SECURITY" list-keychains -d user -s "${RESTORE[@]}"; fi
fi
[[ "$("$SECURITY" default-keychain -d user)" == "$DEFAULT_BEFORE" ]] ||
  warn "your default keychain changed (it was $DEFAULT_BEFORE); check Keychain Access"
[[ "$(prefs_state)" == "$PREFS_BEFORE" ]] ||
  warn "$USER_PREFS changed during setup; check: security list-keychains -d user"

print_identity "$SHA1"
info "test signature: $PROBE_DR"
info "your keychain search list (unchanged):"
printf '%s\n' "$LIST_AFTER" | sed 's/^ */      /'
echo
info "Back up $KAN_SIGNING_DIR: a new identity makes macOS ask for Kan's permissions again."
