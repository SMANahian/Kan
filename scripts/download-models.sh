#!/usr/bin/env bash
#
# Downloads Kan's transcription models (resumable, checksum-verified).
#
# Usage: scripts/download-models.sh [--recommended | --minimal | --all | --only ID[,ID…]]
#                                   [--list] [--dry-run] [--verify] [--dest DIR]
#
#   --recommended  (default) VAD + Whisper large-v3 q5_0 + large-v3-turbo + the Bangla model, 3.5 GB
#   --minimal      VAD + Whisper large-v3 q5_0 (one model for language ID, English and Bangla), 1.1 GB
#   --all          everything below, including full-precision large-v3, 6.6 GB
#   --only IDS     just these model ids (comma-separated)
#   --list         show the catalog and what is installed, then exit
#   --dry-run      show what would be downloaded
#   --verify       also check the SHA-256 of models that are already installed
#   --dest DIR     download into DIR (default: $KAN_MODELS, else ~/Library/Application Support/Kan/Models)
#
# Files are fetched from pinned Hugging Face revisions into <name>.part, resumed after an interruption
# (just run the script again), checked against the expected size and SHA-256, and only then renamed.
# Files that already have the right size are skipped. Speaker-separation models (FluidAudio, ~130 MB)
# are downloaded by Kan itself when it first needs them.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=lib/common.sh
source "$ROOT/scripts/lib/common.sh"

# id | file name | URL | bytes | SHA-256 | role | sets | description
# File names and ids must match KanTranscribe's ModelStore (see docs/ARCHITECTURE.md).
CATALOG="
silero-v6.2.0|ggml-silero-v6.2.0.bin|https://huggingface.co/ggml-org/whisper-vad/resolve/9ffd54a1e1ee413ddf265af9913beaf518d1639b/ggml-silero-v6.2.0.bin|885098|2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987|vad|minimal recommended all|Silero VAD: finds the speech before transcription
large-v3-q5_0|ggml-large-v3-q5_0.bin|https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-q5_0.bin|1081140203|d75795ecff3f83b5faa89d1900604ad8c780abd5739fae406de19f23ecd98ad1|general|minimal recommended all|Whisper large-v3, 5-bit: language ID, English and fallback Bangla (~2 GB RAM)
large-v3-turbo|ggml-large-v3-turbo.bin|https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo.bin|1624555275|1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69|english|recommended all|Whisper large-v3-turbo: fast, accurate English (~2 GB RAM)
bengali-medium-q8_0|ggml-bengali-whisper-medium-q8_0.bin|https://huggingface.co/SayedShaun/bengali-whisper-medium-ggml/resolve/06e5be79bab49db9ebeff3ce8e8fb9d31fd9f800/ggml-model-q8_0.bin|823414983|a6827a244c5041a5c97a9d04e5b0a8076f0aad38faef5dbec8943d833dfe04eb|bangla|recommended all|Bengali.AI Whisper-medium fine-tune, 8-bit: much better Bangla spelling
large-v3|ggml-large-v3.bin|https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3.bin|3095033483|64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2|general|all|Whisper large-v3, full precision: same quality as q5_0, twice the memory (~4.3 GB RAM)
"

SET="recommended"
ONLY=""
LIST=0
DRY_RUN=0
VERIFY=0
DEST="${KAN_MODELS:-$HOME/Library/Application Support/Kan/Models}"
ATTEMPTS=5
FREE_SPACE_MARGIN=$((1024 * 1024 * 1024))

while [[ $# -gt 0 ]]; do
  case "$1" in
    --recommended) SET="recommended" ;;
    --minimal) SET="minimal" ;;
    --all) SET="all" ;;
    --only)
      [[ $# -ge 2 ]] || die "--only needs model ids, e.g. --only large-v3-turbo,silero-v6.2.0"
      ONLY="$2"
      shift
      ;;
    --list) LIST=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --verify) VERIFY=1 ;;
    --dest)
      [[ $# -ge 2 ]] || die "--dest needs a directory"
      DEST="$2"
      shift
      ;;
    -h | --help) print_usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
  shift
done

# --- Catalog ---------------------------------------------------------------------------------------

catalog_lines() { printf '%s\n' "$CATALOG" | sed '/^$/d'; }

catalog_has() { catalog_lines | cut -d'|' -f1 | grep -qxF "$1"; }

# Prints the catalog lines selected by --only or the chosen set.
selected_lines() {
  local id file url size sha role sets desc
  while IFS='|' read -r id file url size sha role sets desc; do
    if [[ -n "$ONLY" ]]; then
      case ",$ONLY," in *",$id,"*) ;; *) continue ;; esac
    else
      case " $sets " in *" $SET "*) ;; *) continue ;; esac
    fi
    printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "$id" "$file" "$url" "$size" "$sha" "$role" "$sets" "$desc"
  done < <(catalog_lines)
}

if [[ -n "$ONLY" ]]; then
  for id in $(printf '%s' "$ONLY" | tr ',' ' '); do
    catalog_has "$id" || die "unknown model id '$id'. Known: $(catalog_lines | cut -d'|' -f1 | paste -sd ' ' -)"
  done
fi

# installed | partial (<bytes> of <total>) | missing | wrong size
model_status() {
  local file="$1" size="$2" current
  if [[ -f "$DEST/$file" ]]; then
    current="$(file_size "$DEST/$file")"
    if [[ "$current" == "$size" ]]; then echo "installed"
    elif [[ "$current" -lt "$size" ]]; then echo "partial ($(human_bytes "$current") of $(human_bytes "$size"))"
    else echo "wrong size"; fi
  elif [[ -f "$DEST/$file.part" ]]; then
    echo "partial ($(human_bytes "$(file_size "$DEST/$file.part")") of $(human_bytes "$size"))"
  else
    echo "missing"
  fi
}

print_table() {
  local id file url size sha role sets desc
  printf '  %-21s %-10s %-8s %-25s %s\n' "id" "size" "role" "sets" "status"
  while IFS='|' read -r id file url size sha role sets desc; do
    printf '  %-21s %-10s %-8s %-25s %s\n' "$id" "$(human_bytes "$size")" "$role" "$sets" "$(model_status "$file" "$size")"
    printf '  %-21s %s\n' "" "$desc"
  done
}

if [[ "$LIST" == 1 ]]; then
  echo "Models in $DEST:"
  catalog_lines | print_table
  exit 0
fi

# --- Download --------------------------------------------------------------------------------------

# Bytes still to download for one model (0 when installed).
remaining_bytes() {
  local file="$1" size="$2" have=0
  if [[ -f "$DEST/$file" ]]; then
    have="$(file_size "$DEST/$file")"
    if [[ "$have" -gt "$size" ]]; then have=0; fi
  fi
  if [[ -f "$DEST/$file.part" ]]; then
    local part
    part="$(file_size "$DEST/$file.part")"
    if [[ "$part" -le "$size" && "$part" -gt "$have" ]]; then have="$part"; fi
  fi
  echo $((size - have))
}

# Resumes $1 (URL) into $2 (.part) until it has $3 bytes; up to $ATTEMPTS tries.
download_part() {
  local url="$1" part="$2" size="$3" attempt=1 status progress=(--silent --show-error)
  if [[ -t 2 ]]; then progress=(--progress-bar); fi
  while :; do
    status=0
    # -C - resumes from the current size of the .part file; stalled transfers (<1 KB/s for 60 s)
    # are aborted and resumed by the next attempt.
    /usr/bin/curl --fail --location --connect-timeout 30 --speed-time 60 --speed-limit 1024 \
      --continue-at - --output "$part" "${progress[@]}" "$url" || status=$?
    if [[ "$status" == 0 && "$(file_size "$part")" == "$size" ]]; then return 0; fi
    if [[ "$status" == 33 ]]; then
      warn "the server refused to resume; starting over"
      rm -f "$part"
    elif [[ "$status" == 0 ]]; then
      warn "download ended at $(file_size "$part") of $size bytes"
      if [[ "$(file_size "$part")" -gt "$size" ]]; then rm -f "$part"; fi
    fi
    if [[ $attempt -ge $ATTEMPTS ]]; then return 1; fi
    attempt=$((attempt + 1))
    info "retrying ($attempt of $ATTEMPTS) in $((attempt * 3)) s…"
    sleep $((attempt * 3))
  done
}

# Called as `fetch_model … || …`, so `set -e` is off inside: every failure is handled explicitly.
fetch_model() {
  local id="$1" file="$2" url="$3" size="$4" sha="$5"
  local final="$DEST/$file" part="$DEST/$file.part" current actual

  if [[ -f "$final" ]]; then
    current="$(file_size "$final")"
    if [[ "$current" == "$size" ]]; then
      if [[ "$VERIFY" == 0 ]]; then ok "$id: already installed"; return 0; fi
      info "$id: checking SHA-256…"
      actual="$(sha256_of "$final")"
      if [[ "$actual" == "$sha" ]]; then ok "$id: installed, checksum OK"; return 0; fi
      warn "$id: checksum mismatch ($actual); downloading it again"
      rm -f "$final"
    elif [[ "$current" -lt "$size" ]]; then
      # An interrupted download that wrote straight to the final name: keep the larger partial copy.
      if [[ ! -f "$part" || "$(file_size "$part")" -lt "$current" ]]; then mv -f "$final" "$part"; else rm -f "$final"; fi
    else
      warn "$id: $file is larger than expected; downloading it again"
      rm -f "$final"
    fi
  fi
  if [[ -f "$part" && "$(file_size "$part")" -gt "$size" ]]; then rm -f "$part"; fi

  if [[ -f "$part" && "$(file_size "$part")" == "$size" ]]; then
    info "$id: download already complete, verifying"
  else
    if [[ -f "$part" ]]; then
      step "$id: resuming at $(human_bytes "$(file_size "$part")") of $(human_bytes "$size")"
    else
      step "$id: downloading $(human_bytes "$size")"
    fi
    download_part "$url" "$part" "$size" || { warn "$id: download failed; run the script again to resume"; return 1; }
  fi

  actual="$(sha256_of "$part")"
  if [[ "$actual" != "$sha" ]]; then
    rm -f "$part"
    warn "$id: checksum mismatch (got $actual, expected $sha); deleted the file, run again to retry"
    return 1
  fi
  mv -f "$part" "$final" || { warn "$id: could not rename $part"; return 1; }
  ok "$id: installed ($(human_bytes "$size"), checksum OK)"
}

SELECTED="$(selected_lines)"
[[ -n "$SELECTED" ]] || die "no models selected"
if [[ -d "$DEST" ]]; then DEST="$(cd "$DEST" && pwd -P)"; fi

NEEDED=0
while IFS='|' read -r id file url size sha role sets desc; do
  NEEDED=$((NEEDED + $(remaining_bytes "$file" "$size")))
done <<< "$SELECTED"

if [[ -n "$ONLY" ]]; then LABEL="models: $ONLY"; else LABEL="the $SET set"; fi
echo "Kan models → $DEST ($LABEL)"
if [[ "$DRY_RUN" == 1 ]]; then
  printf '%s\n' "$SELECTED" | print_table
  echo "Would download $(human_bytes "$NEEDED")."
  exit 0
fi

mkdir -p "$DEST" || die "can't create $DEST"
DEST="$(cd "$DEST" && pwd -P)"
FREE="$(free_bytes "$DEST")"
if [[ "$NEEDED" -gt 0 && $((NEEDED + FREE_SPACE_MARGIN)) -gt "$FREE" ]]; then
  die "need $(human_bytes "$NEEDED") (plus 1 GB to spare) but only $(human_bytes "$FREE") is free on that volume. Free some space or pick fewer models (--minimal, --only)."
fi

LOCK="$DEST/.download-models.lock"
acquire_lock "$LOCK"
trap 'release_lock "$LOCK"' EXIT
trap 'echo; warn "interrupted; run the script again to resume"; exit 130' INT TERM

FAILED=0
while IFS='|' read -r id file url size sha role sets desc; do
  fetch_model "$id" "$file" "$url" "$size" "$sha" || FAILED=$((FAILED + 1))
done <<< "$SELECTED"

echo
printf '%s\n' "$SELECTED" | print_table
if [[ "$FAILED" -gt 0 ]]; then die "$FAILED model(s) failed to download"; fi
echo
info "Kan uses the best installed model for each job (Settings › Transcription: \"auto\")."
