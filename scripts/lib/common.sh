# shellcheck shell=bash
#
# Shared helpers for Kan's build scripts. Sourced by scripts/*.sh, never executed directly.
# Everything here must run under macOS's stock /bin/bash 3.2: no associative arrays, no mapfile,
# and never expand a possibly-empty array as "${a[@]}" while `set -u` is on.

# System tools first: conda, Homebrew and MacPorts ship GNU or look-alike versions of sed, ar,
# libtool, lipo, curl… whose flags and output differ. cmake, ninja and friends stay reachable.
PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export PATH

# --- Product constants (keep in sync with KanPaths.bundleIdentifier and Package.swift) -----------

KAN_BUNDLE_ID="com.nahian.Kan"
KAN_APP_NAME="Kan"
KAN_APP_EXECUTABLE="KanApp"       # CFBundleExecutable; the CLI is "kan" and APFS is case-insensitive
KAN_CLI_EXECUTABLE="kan"
KAN_CLI_IDENTIFIER="com.nahian.Kan.cli"

# --- Local code-signing identity (made once by scripts/setup-signing.sh) --------------------------
#
# The certificate lives in its own keychain, outside the repo. codesign only finds identities in
# keychains on the *search list*, and the search list is read from $HOME, so signing runs with
# HOME pointed at a private directory whose search list contains only this keychain. The user's
# login keychain and real search list are never touched.

KAN_SIGNING_IDENTITY="Kan Local Code Signing"
KAN_SIGNING_DIR="${KAN_SIGNING_DIR:-$HOME/Library/Application Support/Kan/Signing}"
KAN_SIGNING_KEYCHAIN="$KAN_SIGNING_DIR/kan-signing.keychain-db"
KAN_SIGNING_PASSWORD_FILE="$KAN_SIGNING_DIR/keychain-password"
KAN_SIGNING_HOME="$KAN_SIGNING_DIR/home"
KAN_SIGNING_CERT="$KAN_SIGNING_DIR/kan-signing-cert.pem"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# The paths of every copy of Kan that LaunchServices has registered, one per line, from the output
# of `lsregister -dump` on stdin. Running a copy's `kan` CLI (…/Kan.app/Contents/MacOS/kan)
# registers that copy too, and then `open -b com.nahian.Kan`, Relaunch or the login item may start it.
kan_copies_in_lsregister_dump() {
  /usr/bin/awk -v id="$KAN_BUNDLE_ID" '
    /^-+$/ { path = "" }
    /^path:/ { path = $0; sub(/^path:[ \t]*/, "", path); sub(/ \(0x[0-9a-fA-F]+\)$/, "", path) }
    /^identifier:/ {
      value = $0; sub(/^identifier:[ \t]*/, "", value); sub(/ \(0x[0-9a-fA-F]+\)$/, "", value)
      if (value == id && path != "") print path
    }' | /usr/bin/sort -u
}

# SHA-1 of the Kan signing identity in its keychain, or nothing when it isn't set up.
signing_identity_sha1() {
  [[ -f "$KAN_SIGNING_KEYCHAIN" ]] || return 0
  /usr/bin/security find-identity -p codesigning "$KAN_SIGNING_KEYCHAIN" 2>/dev/null |
    /usr/bin/awk -v name="\"$KAN_SIGNING_IDENTITY\"" 'index($0, name) && length($2) == 40 { print $2; exit }'
}

# Unlocks the signing keychain (always by explicit path: without one, `security` acts on the
# login keychain).
signing_unlock() {
  [[ -f "$KAN_SIGNING_PASSWORD_FILE" ]] || die "missing $KAN_SIGNING_PASSWORD_FILE (run scripts/setup-signing.sh)"
  /usr/bin/security unlock-keychain -p "$(cat "$KAN_SIGNING_PASSWORD_FILE")" "$KAN_SIGNING_KEYCHAIN" ||
    die "could not unlock $KAN_SIGNING_KEYCHAIN"
}

# codesign with the Kan identity: HOME points at the private signing home so codesign's keychain
# search list contains the signing keychain (with --keychain alone it reports "no identity found").
codesign_with_identity() {
  local sha1="$1"
  shift
  HOME="$KAN_SIGNING_HOME" /usr/bin/codesign --keychain "$KAN_SIGNING_KEYCHAIN" --sign "$sha1" "$@"
}

# The designated requirement of signed code, e.g.
#   identifier "com.nahian.Kan" and certificate root = H"0123…"
designated_requirement() {
  /usr/bin/codesign -d -r- "$1" 2>&1 | /usr/bin/sed -n 's/^# designated => //p; s/^designated => //p' | head -n 1
}

# --- Output --------------------------------------------------------------------------------------

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  _kan_bold=$'\033[1m' _kan_blue=$'\033[34m' _kan_green=$'\033[32m' _kan_reset=$'\033[0m'
else
  _kan_bold="" _kan_blue="" _kan_green="" _kan_reset=""
fi
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  _kan_red=$'\033[31m' _kan_yellow=$'\033[33m' _kan_ereset=$'\033[0m'
else
  _kan_red="" _kan_yellow="" _kan_ereset=""
fi

# Prints the comment block at the top of the running script: its usage text.
print_usage() {
  /usr/bin/awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); if (seen || $0 != "") { print; seen = 1 } next } { exit }' "$0"
}

step() { printf '%s==>%s %s%s%s\n' "$_kan_blue" "$_kan_reset" "$_kan_bold" "$*" "$_kan_reset"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '%s  ✓%s %s\n' "$_kan_green" "$_kan_reset" "$*"; }
warn() { printf '%swarning:%s %s\n' "$_kan_yellow" "$_kan_ereset" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$_kan_red" "$_kan_ereset" "$*" >&2; exit 1; }

# A warning that must not scroll by unnoticed.
loud_warning() {
  local line="!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  {
    printf '\n%s%s%s\n' "$_kan_yellow" "$line" "$_kan_ereset"
    local msg
    for msg in "$@"; do printf '%s!!%s %s\n' "$_kan_yellow" "$_kan_ereset" "$msg"; done
    printf '%s%s%s\n\n' "$_kan_yellow" "$line" "$_kan_ereset"
  } >&2
}

# --- Tools ---------------------------------------------------------------------------------------

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' not found. ${2:-}"
}

# Absolute path of an Apple developer tool (clang, ar, ranlib, lipo, otool…). Anaconda, Homebrew
# and MacPorts put look-alikes of several of these earlier in PATH; GNU ar, for one, writes archives
# whose symbol table Apple's linker rejects.
apple_tool() {
  local path
  path="$(/usr/bin/xcrun --find "$1" 2>/dev/null || true)"
  [[ -n "$path" && -x "$path" ]] ||
    die "Apple developer tool '$1' not found. Install the Command Line Tools: xcode-select --install"
  printf '%s\n' "$path"
}

# --- Files ---------------------------------------------------------------------------------------

file_size() { /usr/bin/stat -f %z "$1"; }

sha256_of() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{ print $1 }'; }

# 1081140203 -> "1.08 GB" (decimal units, like Finder).
human_bytes() {
  /usr/bin/awk -v b="$1" 'BEGIN {
    split("bytes KB MB GB TB", unit, " "); i = 1
    while (b >= 1000 && i < 5) { b /= 1000; i++ }
    if (i == 1) printf "%d %s", b, unit[i]; else printf "%.2f %s", b, unit[i]
  }'
}

# Free bytes on the volume holding $1 (which must exist).
free_bytes() { /bin/df -Pk "$1" | /usr/bin/awk 'NR == 2 { printf "%.0f", $4 * 1024 }'; }

# --- Locking -------------------------------------------------------------------------------------
#
# mkdir is atomic, so a lock is a directory holding the owner's PID. A lock whose owner is gone
# (crash, kill -9) is taken over.

acquire_lock() {
  local dir="$1" pid
  if ! mkdir "$dir" 2>/dev/null; then
    pid="$(cat "$dir/pid" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      die "$(basename "$0") is already running (pid $pid). If it isn't, remove $dir"
    fi
    rm -rf "${dir:?}"
    mkdir "$dir" 2>/dev/null || die "could not create the lock $dir"
  fi
  echo "$$" > "$dir/pid"
}

release_lock() { rm -rf "${1:?}"; }

# --- Versions ------------------------------------------------------------------------------------

# Marketing version (CFBundleShortVersionString): $KAN_VERSION, else the first line of <root>/VERSION,
# else KanVersion.current in Sources/KanCore.
kan_marketing_version() {
  local root="$1" version="" pattern='^[0-9]+(\.[0-9]+){0,2}$'
  if [[ -n "${KAN_VERSION:-}" ]]; then
    version="$KAN_VERSION"
  elif [[ -f "$root/VERSION" ]]; then
    version="$(head -n 1 "$root/VERSION" | tr -d '[:space:]')"
  else
    version="$(find "$root/Sources/KanCore" -name '*.swift' -exec /usr/bin/awk '
      FNR == 1 { inside = 0 }
      /enum[ \t]+KanVersion/ { inside = 1 }
      inside && /static let current/ {
        if (match($0, /"[^"]+"/)) { print substr($0, RSTART + 1, RLENGTH - 2); exit }
      }' {} + 2>/dev/null | head -n 1)"
  fi
  [[ "$version" =~ $pattern ]] ||
    die "invalid or missing version '${version}' (expected e.g. 0.1.0; set KAN_VERSION or add a VERSION file)"
  printf '%s\n' "$version"
}
