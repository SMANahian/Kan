#!/usr/bin/env bash
#
# Installs build/Kan.app and (re)launches it.
#
# Usage: scripts/install.sh [--no-launch] [--cli] [--dest DIR] [--app PATH]
#
#   --no-launch   don't start Kan afterwards
#   --cli         also link ~/.local/bin/kan to the installed app's kan CLI (KAN_CLI_DIR overrides)
#   --dest DIR    install into DIR instead of /Applications (default: /Applications when it is
#                 writable, otherwise ~/Applications)
#   --app PATH    install this bundle instead of build/Kan.app
#
# Steps: quit a running Kan gracefully (a "quit" Apple Event, then SIGTERM; either way Kan saves a
# recording in progress before exiting), copy the bundle with ditto and swap it in with one rename,
# unregister every other copy LaunchServices knows (the build copy, a copy whose kan CLI was run)
# and register the installed one, so that `open -b com.nahian.Kan` finds it, then relaunch.
#
# Kan keeps its permissions (Microphone, System Audio Recording…) when the new build is signed with
# the same identity as the installed one; the script warns when that isn't the case.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=lib/common.sh
source "$ROOT/scripts/lib/common.sh"

APP_SRC="$ROOT/build/$KAN_APP_NAME.app"
DEST_DIR=""
LAUNCH=1
LINK_CLI=0
CLI_DIR="${KAN_CLI_DIR:-$HOME/.local/bin}"
QUIT_TIMEOUT="${KAN_QUIT_TIMEOUT:-30}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-launch) LAUNCH=0 ;;
    --cli) LINK_CLI=1 ;;
    --dest)
      [[ $# -ge 2 ]] || die "--dest needs a directory"
      DEST_DIR="$2"
      shift
      ;;
    --app)
      [[ $# -ge 2 ]] || die "--app needs a path"
      APP_SRC="$2"
      shift
      ;;
    -h | --help) print_usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
  shift
done

# --- Helpers ---------------------------------------------------------------------------------------

kan_pids() { /usr/bin/pgrep -x "$KAN_APP_EXECUTABLE" 2>/dev/null || true; }

wait_for_exit() {
  local ticks=$(($1 * 4)) i=0
  while [[ -n "$(kan_pids)" ]]; do
    if [[ $i -ge $ticks ]]; then return 1; fi
    sleep 0.25
    i=$((i + 1))
  done
}

# Runs a command, killing it after $1 seconds (macOS has no `timeout`). Returns 124 on timeout.
run_with_timeout() {
  local seconds="$1" pid ticks=0
  shift
  "$@" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [[ $ticks -ge $((seconds * 10)) ]]; then
      kill -TERM "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 0.1
    ticks=$((ticks + 1))
  done
  wait "$pid"
}

quit_running_kan() {
  [[ -n "$(kan_pids)" ]] || return 0
  step "Quitting the running Kan (it saves a recording in progress first)"
  # The Apple Event takes NSApplication's normal termination path. Only send it when LaunchServices
  # knows a running app with Kan's bundle id: `tell application` launches apps that aren't running.
  # macOS may ask once whether Terminal may control Kan; if that's declined, SIGTERM below does the
  # same job (Kan turns SIGTERM into a normal quit).
  if [[ -n "$(/usr/bin/lsappinfo find "bundleid=$KAN_BUNDLE_ID" 2>/dev/null)" ]]; then
    run_with_timeout 20 /usr/bin/osascript -e "tell application id \"$KAN_BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    if wait_for_exit "$QUIT_TIMEOUT"; then ok "Kan quit"; return 0; fi
  fi
  local pids
  pids="$(kan_pids)"
  if [[ -n "$pids" ]]; then
    info "sending SIGTERM to pid $(printf '%s\n' "$pids" | paste -sd ' ' -)"
    # shellcheck disable=SC2086 # one pid per word
    kill -TERM $pids 2>/dev/null || true
    if wait_for_exit "$QUIT_TIMEOUT"; then ok "Kan quit"; return 0; fi
  fi
  die "Kan is still running (pid $(kan_pids | paste -sd ' ' -)). Quit it from the menu bar, then run the install again."
}

# --- Checks ----------------------------------------------------------------------------------------

[[ -d "$APP_SRC" ]] || die "$APP_SRC not found. Build it first: make app"
APP_SRC="$(cd "$APP_SRC" && pwd -P)"
[[ -x "$APP_SRC/Contents/MacOS/$KAN_APP_EXECUTABLE" ]] || die "$APP_SRC has no Contents/MacOS/$KAN_APP_EXECUTABLE"
SRC_ID="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$APP_SRC/Contents/Info.plist" 2>/dev/null || true)"
[[ "$SRC_ID" == "$KAN_BUNDLE_ID" ]] || die "$APP_SRC is not Kan (bundle id '${SRC_ID}')"
/usr/bin/codesign --verify --deep --strict "$APP_SRC" 2>/dev/null ||
  die "$APP_SRC has a missing or broken signature. Rebuild it: make app"
NEW_DR="$(designated_requirement "$APP_SRC")"
VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$APP_SRC/Contents/Info.plist") ($(/usr/bin/plutil -extract CFBundleVersion raw -o - "$APP_SRC/Contents/Info.plist"))"
if [[ "$NEW_DR" == cdhash* ]]; then
  loud_warning \
    "This build is signed ad-hoc: macOS will ask for Kan's permissions again after every install." \
    "Fix it once with:  make signing && make app"
fi

if [[ -z "$DEST_DIR" ]]; then
  if [[ -w /Applications ]]; then DEST_DIR="/Applications"; else DEST_DIR="$HOME/Applications"; fi
fi
mkdir -p "$DEST_DIR" 2>/dev/null || true
[[ -d "$DEST_DIR" && -w "$DEST_DIR" ]] || die "can't write to $DEST_DIR"
DEST_DIR="$(cd "$DEST_DIR" && pwd -P)"
DEST="$DEST_DIR/$KAN_APP_NAME.app"
[[ "$DEST" != "$APP_SRC" ]] || die "$APP_SRC is already the installed copy"

for other in "/Applications/$KAN_APP_NAME.app" "$HOME/Applications/$KAN_APP_NAME.app"; do
  if [[ -d "$other" && "$(cd "$other" && pwd -P)" != "$DEST" ]]; then
    warn "another copy of Kan is installed at $other. Delete it so macOS can't start the wrong one."
  fi
done

if [[ -d "$DEST" ]]; then
  OLD_DR="$(designated_requirement "$DEST")"
  if [[ -n "$OLD_DR" && "$OLD_DR" != "$NEW_DR" ]]; then
    warn "this build is signed differently from the installed Kan, so macOS will ask for its permissions again."
    info "installed: $OLD_DR"
    info "new:       $NEW_DR"
  fi
fi

CLI_LINK="$CLI_DIR/$KAN_CLI_EXECUTABLE"
if [[ "$LINK_CLI" == 1 && -e "$CLI_LINK" && ! -L "$CLI_LINK" ]]; then
  die "$CLI_LINK exists and isn't a symlink; move it away so install can link the kan CLI there"
fi

# --- Install ---------------------------------------------------------------------------------------

STAGING="$DEST_DIR/.$KAN_APP_NAME.app.installing.$$"
PREVIOUS="$DEST_DIR/.$KAN_APP_NAME.app.previous.$$"
trap 'rm -rf "${STAGING:?}" "${PREVIOUS:?}"' EXIT

quit_running_kan

step "Installing Kan $VERSION to $DEST"
/usr/bin/ditto "$APP_SRC" "$STAGING"
/usr/bin/codesign --verify --deep --strict "$STAGING" 2>/dev/null || die "the copy in $STAGING doesn't verify; nothing was replaced"
if [[ -d "$DEST" ]]; then mv "$DEST" "$PREVIOUS"; fi
mv "$STAGING" "$DEST"
rm -rf "${PREVIOUS:?}"

# The installed copy must be the only one LaunchServices offers for com.nahian.Kan. Running a
# copy's kan CLI registers that copy, so forget every other one LaunchServices knows (their files
# stay; a copy that is opened again gets registered again), then register the installed copy.
"$LSREGISTER" -u "$APP_SRC" 2>/dev/null || true
while IFS= read -r copy; do
  [[ -n "$copy" ]] || continue
  if [[ "$copy" -ef "$DEST" ]]; then continue; fi       # the installed copy, however it's spelled
  if "$LSREGISTER" -u "$copy" 2>/dev/null; then
    info "unregistered another copy of Kan that LaunchServices knew: $copy"
  else
    warn "LaunchServices knows another copy of Kan at $copy; delete it so macOS can't start it instead"
  fi
done < <("$LSREGISTER" -dump 2>/dev/null | kan_copies_in_lsregister_dump)
if "$LSREGISTER" -f "$DEST"; then
  ok "registered $DEST with LaunchServices (the only copy it knows)"
else
  warn "lsregister couldn't register $DEST; macOS will register it when it first opens"
fi

if [[ "$LINK_CLI" == 1 ]]; then
  mkdir -p "$CLI_DIR"
  ln -sfn "$DEST/Contents/MacOS/$KAN_CLI_EXECUTABLE" "$CLI_LINK"
  ok "kan CLI: $CLI_LINK -> $DEST/Contents/MacOS/$KAN_CLI_EXECUTABLE"
  case ":$PATH:" in
    *":$CLI_DIR:"*) ;;
    *) warn "$CLI_DIR is not on your PATH. Add to ~/.zshrc:  export PATH=\"$CLI_DIR:\$PATH\"" ;;
  esac
fi

if [[ "$LAUNCH" == 1 ]]; then
  step "Launching Kan"
  /usr/bin/open -b "$KAN_BUNDLE_ID" || die "open -b $KAN_BUNDLE_ID failed"
  launched=""
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    for pid in $(kan_pids); do
      if [[ "$(ps -o comm= -p "$pid" 2>/dev/null)" == "$DEST/Contents/MacOS/$KAN_APP_EXECUTABLE" ]]; then launched="$pid"; fi
    done
    [[ -z "$launched" ]] || break
    sleep 0.25
  done
  if [[ -n "$launched" ]]; then
    ok "Kan is running (pid $launched); look for the ear in the menu bar"
  else
    warn "couldn't confirm that $DEST started. Check for other copies of Kan.app, or start it with: open \"$DEST\""
  fi
fi

step "Installed $DEST"
info "signature: $NEW_DR"
