#!/usr/bin/env bash
#
# Builds build/Kan.app: the menu-bar app (KanApp) plus the `kan` CLI, signed so that macOS keeps
# Kan's privacy permissions across rebuilds.
#
# Usage: scripts/build-app.sh            (or `make app`)
#
# Environment (all optional):
#   CONFIG=release|debug    SwiftPM configuration (default release)
#   SIGN_MODE=selfsigned    (default) sign with "Kan Local Code Signing" (scripts/setup-signing.sh);
#                           falls back to ad-hoc, with a loud warning, if that identity doesn't exist
#   SIGN_MODE=adhoc         `codesign -s -`: macOS forgets Kan's permissions after every rebuild
#   SIGN_MODE=none          keep the linker's ad-hoc signatures; the bundle itself stays unsigned
#   HARDENED=1|0            1 (default) = hardened runtime + Resources/Kan.entitlements. Without it,
#                           any program running as you could start Kan with DYLD_INSERT_LIBRARIES
#                           and use Kan's Microphone, System Audio Recording, Accessibility and
#                           Automation permissions. 0 = no hardened runtime, for troubleshooting
#                           only. The designated requirement is the same either way, so switching
#                           keeps the permissions.
#   KAN_VERSION             CFBundleShortVersionString (default: VERSION file, else KanVersion.current)
#   KAN_BUILD_NUMBER        CFBundleVersion (default: yyyyMMdd.HHmmss, so newer builds sort higher)
#   OUT_DIR                 where Kan.app is written (default: build)
#   SCRATCH_PATH            SwiftPM --scratch-path (default: .build)
#
# Bundle layout:
#   Kan.app/Contents/Info.plist                from Resources/Info.plist.template
#   Kan.app/Contents/PkgInfo
#   Kan.app/Contents/MacOS/KanApp              the app (CFBundleExecutable)
#   Kan.app/Contents/MacOS/kan                 CLI + MCP server, signed as com.nahian.Kan.cli
#   Kan.app/Contents/Resources/AppIcon.icns    plus anything in Resources/Bundle/
#
# The bundle is assembled and signed in a staging directory and only then moved to build/Kan.app,
# so a failed build never leaves a half-signed app behind. Prints the bundle path last.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=lib/common.sh
source "$ROOT/scripts/lib/common.sh"

CONFIG="${CONFIG:-release}"
SIGN_MODE="${SIGN_MODE:-selfsigned}"
HARDENED="${HARDENED:-1}"
OUT_DIR="${OUT_DIR:-$ROOT/build}"
SCRATCH_PATH="${SCRATCH_PATH:-}"

TEMPLATE="$ROOT/Resources/Info.plist.template"
ENTITLEMENTS="$ROOT/Resources/Kan.entitlements"
ICON="$ROOT/Resources/AppIcon.icns"
EXTRA_RESOURCES="$ROOT/Resources/Bundle"
WHISPER_LIBS=(libwhisper.a libggml.a libggml-base.a libggml-cpu.a libggml-blas.a libggml-metal.a)

case "${1:-}" in
  "") ;;
  -h | --help) print_usage; exit 0 ;;
  *) die "unknown argument: $1 (configure with environment variables; see --help)" ;;
esac
case "$CONFIG" in release | debug) ;; *) die "CONFIG must be release or debug, not '$CONFIG'" ;; esac
case "$SIGN_MODE" in selfsigned | adhoc | none) ;; *) die "SIGN_MODE must be selfsigned, adhoc or none, not '$SIGN_MODE'" ;; esac
case "$HARDENED" in 0 | 1) ;; *) die "HARDENED must be 0 or 1, not '$HARDENED'" ;; esac

VERSION="$(kan_marketing_version "$ROOT")"
BUILD_NUMBER="${KAN_BUILD_NUMBER:-$(date +%Y%m%d.%H%M%S)}"
BUILD_NUMBER_PATTERN='^[0-9]+(\.[0-9]+){0,2}$'
[[ "$BUILD_NUMBER" =~ $BUILD_NUMBER_PATTERN ]] ||
  die "KAN_BUILD_NUMBER must be one to three dot-separated integers, not '$BUILD_NUMBER'"

APP="$OUT_DIR/$KAN_APP_NAME.app"
STAGING_DIR="$OUT_DIR/.staging.$$"
STAGED_APP="$STAGING_DIR/$KAN_APP_NAME.app"
LIPO="$(apple_tool lipo)"

trap 'rm -rf "${STAGING_DIR:?}"' EXIT

# --- Preflight -------------------------------------------------------------------------------------

[[ "$(uname -m)" == "arm64" ]] || warn "this shell runs as $(uname -m) (Rosetta?); Kan is built for arm64 only"
for lib in "${WHISPER_LIBS[@]}"; do
  [[ -f "$ROOT/Vendor/whisper/lib/$lib" ]] || die "Vendor/whisper/lib/$lib is missing. Run 'make bootstrap' first."
done
[[ -f "$TEMPLATE" ]] || die "missing $TEMPLATE"
if [[ "$HARDENED" == "1" ]]; then
  [[ -f "$ENTITLEMENTS" ]] || die "the hardened runtime needs $ENTITLEMENTS (or build with HARDENED=0)"
  # These two would undo what the hardened runtime is for (code injected into Kan).
  if grep -qE 'com\.apple\.security\.cs\.(allow-dyld-environment-variables|disable-library-validation)' "$ENTITLEMENTS"; then
    die "$ENTITLEMENTS must not grant allow-dyld-environment-variables or disable-library-validation"
  fi
fi
if [[ ! -f "$ICON" ]]; then
  warn "Resources/AppIcon.icns is missing; rendering it (commit the result)"
  /usr/bin/swift "$ROOT/scripts/make-icon.swift" --icns "$ICON"
fi

# Decide how to sign before spending time on the build.
EFFECTIVE_SIGN_MODE="$SIGN_MODE"
IDENTITY_SHA1=""
if [[ "$SIGN_MODE" == "selfsigned" ]]; then
  IDENTITY_SHA1="$(signing_identity_sha1)"
  if [[ -z "$IDENTITY_SHA1" ]]; then
    EFFECTIVE_SIGN_MODE="adhoc"
    loud_warning \
      "No local signing identity found in $KAN_SIGNING_DIR." \
      "Signing AD-HOC instead. macOS will forget Kan's Microphone, System Audio Recording and" \
      "Automation permissions after every rebuild, and ask again." \
      "Fix it once with:  make signing   (then rebuild)"
  fi
fi

# --- Build -----------------------------------------------------------------------------------------

SWIFT_ARGS=(--package-path "$ROOT" -c "$CONFIG" --arch arm64)
if [[ -n "$SCRATCH_PATH" ]]; then SWIFT_ARGS+=(--scratch-path "$SCRATCH_PATH"); fi

# One product at a time: a plain `swift build` also builds FluidAudio's CLI, which doesn't compile
# with only the Diarizer trait enabled.
for product in "$KAN_APP_EXECUTABLE" "$KAN_CLI_EXECUTABLE"; do
  step "swift build --product $product ($CONFIG, arm64)"
  swift build "${SWIFT_ARGS[@]}" --product "$product"
done
BIN_DIR="$(swift build "${SWIFT_ARGS[@]}" --show-bin-path)"

for product in "$KAN_APP_EXECUTABLE" "$KAN_CLI_EXECUTABLE"; do
  [[ -x "$BIN_DIR/$product" ]] || die "swift build did not produce $BIN_DIR/$product"
  archs="$("$LIPO" -archs "$BIN_DIR/$product")"
  [[ "$archs" == "arm64" ]] || die "$product was built for '$archs', expected arm64"
done

# SwiftPM resource bundles (Bundle.module) can't work inside Kan.app: the generated accessor looks for
# them at the bundle root, where codesign rejects them ("unsealed contents present in the bundle
# root"), and otherwise falls back to an absolute path inside .build.
for bundle in "$BIN_DIR"/*.bundle; do
  [[ -d "$bundle" ]] || continue
  name="$(basename "$bundle")"
  if grep -aqF "$name" "$BIN_DIR/$KAN_APP_EXECUTABLE" "$BIN_DIR/$KAN_CLI_EXECUTABLE"; then
    die "the app uses the SwiftPM resource bundle $name (Bundle.module), which can't be shipped in Kan.app. Put those files in Resources/Bundle/ (copied to Contents/Resources) and load them with Bundle.main."
  fi
done

# --- Assemble --------------------------------------------------------------------------------------

step "Assembling $KAN_APP_NAME.app $VERSION ($BUILD_NUMBER)"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp "$BIN_DIR/$KAN_APP_EXECUTABLE" "$STAGED_APP/Contents/MacOS/$KAN_APP_EXECUTABLE"
cp "$BIN_DIR/$KAN_CLI_EXECUTABLE" "$STAGED_APP/Contents/MacOS/$KAN_CLI_EXECUTABLE"
cp "$ICON" "$STAGED_APP/Contents/Resources/AppIcon.icns"
if [[ -d "$EXTRA_RESOURCES" ]]; then
  /usr/bin/ditto "$EXTRA_RESOURCES" "$STAGED_APP/Contents/Resources"
fi
printf 'APPL????' > "$STAGED_APP/Contents/PkgInfo"

PLIST="$STAGED_APP/Contents/Info.plist"
sed -e "s/@KAN_VERSION@/$VERSION/g" -e "s/@KAN_BUILD_NUMBER@/$BUILD_NUMBER/g" "$TEMPLATE" > "$PLIST"
# Validates the XML and rewrites it canonically (which also drops the template's comment).
/usr/bin/plutil -convert xml1 "$PLIST" || die "Resources/Info.plist.template is not a valid property list"
if grep -q '@KAN_[A-Z_]*@' "$PLIST"; then die "unreplaced placeholder in Info.plist: $(grep -o '@KAN_[A-Z_]*@' "$PLIST" | head -n 1)"; fi
plist_value() { /usr/bin/plutil -extract "$1" raw -o - "$PLIST"; }
[[ "$(plist_value CFBundleIdentifier)" == "$KAN_BUNDLE_ID" ]] || die "Info.plist CFBundleIdentifier must be $KAN_BUNDLE_ID"
[[ "$(plist_value CFBundleExecutable)" == "$KAN_APP_EXECUTABLE" ]] || die "Info.plist CFBundleExecutable must be $KAN_APP_EXECUTABLE"
# macOS shows these in its prompts; without one the prompt has no explanation (or never appears).
for key in NSMicrophoneUsageDescription NSAudioCaptureUsageDescription NSDocumentsFolderUsageDescription; do
  [[ -n "$(plist_value "$key" 2>/dev/null)" ]] || die "Info.plist needs $key (the text of macOS's permission prompt)"
done

# --- Sign ------------------------------------------------------------------------------------------

RUNTIME_ARGS=()
APP_ENTITLEMENT_ARGS=()
HARDENED_NOTE=""
if [[ "$HARDENED" == "1" ]]; then
  RUNTIME_ARGS=(--options runtime)
  HARDENED_NOTE=", hardened runtime"
  APP_ENTITLEMENT_ARGS=(--entitlements "$ENTITLEMENTS")
elif [[ "$EFFECTIVE_SIGN_MODE" != "none" ]]; then
  warn "HARDENED=0: other programs can inject code into this Kan.app and use its permissions; use it only for troubleshooting"
fi

sign() {
  case "$EFFECTIVE_SIGN_MODE" in
    selfsigned) codesign_with_identity "$IDENTITY_SHA1" --force --timestamp=none "$@" ;;
    adhoc) /usr/bin/codesign --force --sign - "$@" ;;
  esac
}

if [[ "$EFFECTIVE_SIGN_MODE" == "none" ]]; then
  warn "SIGN_MODE=none: the bundle is unsigned (macOS may refuse permissions or kill the app)"
else
  step "Signing ($EFFECTIVE_SIGN_MODE$HARDENED_NOTE)"
  if [[ "$EFFECTIVE_SIGN_MODE" == "selfsigned" ]]; then signing_unlock; fi
  # Inside out: nested code must already be signed when the bundle is sealed.
  sign --identifier "$KAN_CLI_IDENTIFIER" ${RUNTIME_ARGS[@]+"${RUNTIME_ARGS[@]}"} \
    "$STAGED_APP/Contents/MacOS/$KAN_CLI_EXECUTABLE"
  sign ${RUNTIME_ARGS[@]+"${RUNTIME_ARGS[@]}"} ${APP_ENTITLEMENT_ARGS[@]+"${APP_ENTITLEMENT_ARGS[@]}"} "$STAGED_APP"

  step "Verifying the signature"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$STAGED_APP"
  if [[ "$HARDENED" == "1" ]]; then
    for code in "$STAGED_APP" "$STAGED_APP/Contents/MacOS/$KAN_CLI_EXECUTABLE"; do
      # sed reads everything (grep -q would quit early, and codesign's SIGPIPE fails the pipeline).
      flags="$(/usr/bin/codesign -dv "$code" 2>&1 | /usr/bin/sed -n 's/^CodeDirectory .*flags=\([^ ]*\).*/\1/p')"
      [[ "$flags" == *runtime* ]] || die "$(basename "$code") was signed without the hardened runtime (flags: ${flags:-none})"
    done
  fi
  DR="$(designated_requirement "$STAGED_APP")"
  CLI_DR="$(designated_requirement "$STAGED_APP/Contents/MacOS/$KAN_CLI_EXECUTABLE")"
  if [[ "$EFFECTIVE_SIGN_MODE" == "selfsigned" ]]; then
    [[ "$DR" == "identifier \"$KAN_BUNDLE_ID\" and certificate root = H\""* ]] ||
      die "unexpected designated requirement: $DR"
  fi
fi

# --- Install into build/ ---------------------------------------------------------------------------

rm -rf "${APP:?}"
mv "$STAGED_APP" "$APP"

step "Built $APP"
info "version:      $VERSION ($BUILD_NUMBER), $CONFIG, arm64"
case "$EFFECTIVE_SIGN_MODE" in
  selfsigned) info "signed with:  $KAN_SIGNING_IDENTITY (SHA-1 $IDENTITY_SHA1)$HARDENED_NOTE" ;;
  adhoc) info "signed with:  ad-hoc$HARDENED_NOTE (permissions reset on every rebuild)" ;;
  none) info "signed with:  nothing" ;;
esac
if [[ "$EFFECTIVE_SIGN_MODE" != "none" ]]; then
  info "designated requirement:"
  info "  app: $DR"
  info "  cli: $CLI_DR"
fi
info "next: make install   (copies it to /Applications and relaunches Kan; run make models first if you haven't)"
echo "$APP"
