#!/usr/bin/env bash
#
# Builds and runs every kan-selftest-* product (debug) and summarizes the results.
#
# Usage: scripts/test.sh [SUITE…] [-- ARG…]
#
#   SUITE   only these suites, by short name ("core", "audio", …) or product name (default: all)
#   ARG     passed to every test executable, e.g.  -- --filter Library   or   -- --list
#
# Environment: SCRATCH_PATH (SwiftPM --scratch-path), TEST_TIMEOUT (seconds per suite, default 1800),
# KEEP_TEST_HOME=1 (keep each suite's temporary KAN_HOME for inspection).
#
# Every suite runs with KAN_HOME set to a fresh temporary directory, so even a test that forgets to
# isolate itself can't touch ~/Documents/Kan or ~/Library/Application Support/Kan. Models are still
# read from the shared models folder unless KAN_MODELS is set. Exits non-zero if any suite fails to
# build, has failing tests, crashes or times out.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=lib/common.sh
source "$ROOT/scripts/lib/common.sh"

TEST_TIMEOUT="${TEST_TIMEOUT:-1800}"
SCRATCH_PATH="${SCRATCH_PATH:-}"
[[ "$TEST_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die "TEST_TIMEOUT must be a positive number of seconds"

WANTED=()
TEST_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --) shift; TEST_ARGS=("$@"); break ;;
    -h | --help) print_usage; exit 0 ;;
    -*) die "unknown option: $1 (test arguments go after --)" ;;
    *) WANTED+=("$1") ;;
  esac
  shift
done

ALL_SUITES=()
while IFS= read -r product; do ALL_SUITES+=("$product"); done < <(
  sed -n 's/.*\.executable(name: "\(kan-selftest-[^"]*\)".*/\1/p' "$ROOT/Package.swift"
)
[[ ${#ALL_SUITES[@]} -gt 0 ]] || die "no kan-selftest-* products in Package.swift"

SUITES=()
if [[ ${#WANTED[@]} -eq 0 ]]; then
  SUITES=("${ALL_SUITES[@]}")
else
  for want in "${WANTED[@]}"; do
    match=""
    for suite in "${ALL_SUITES[@]}"; do
      if [[ "$suite" == "$want" || "$suite" == "kan-selftest-$want" ]]; then match="$suite"; fi
    done
    [[ -n "$match" ]] || die "no test suite '$want'. Available: $(printf '%s\n' "${ALL_SUITES[@]}" | sed 's/^kan-selftest-//' | paste -sd ' ' -)"
    SUITES+=("$match")
  done
fi

SWIFT_ARGS=(--package-path "$ROOT")
if [[ -n "$SCRATCH_PATH" ]]; then SWIFT_ARGS+=(--scratch-path "$SCRATCH_PATH"); fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/kan-test.XXXXXX")"
cleanup() {
  if [[ "${KEEP_TEST_HOME:-0}" == 1 ]]; then
    info "logs and test homes kept in $WORK"
  else
    rm -rf "${WORK:?}"
  fi
}
trap cleanup EXIT

# Runs one test executable with a private KAN_HOME, streaming its output to the terminal and to
# $log, killing it after $TEST_TIMEOUT seconds. Sets RUN_STATUS and RUN_TIMED_OUT.
run_suite() {
  local bin="$1" log="$2" home="$3" fifo="$2.fifo" pid tee_pid ticks=0
  RUN_STATUS=0
  RUN_TIMED_OUT=0
  mkfifo "$fifo"
  tee "$log" < "$fifo" &
  tee_pid=$!
  # The test runs in a subshell whose own stderr is discarded: when a test crashes, bash prints a
  # "Trace/BPT trap: 5  <source line>" notice there. The test's output goes to the FIFO. The trailing
  # `exit` keeps bash from exec'ing the test in place of the subshell.
  (
    KAN_HOME="$home" "$bin" ${TEST_ARGS[@]+"${TEST_ARGS[@]}"} > "$fifo" 2>&1 < /dev/null
    exit $?
  ) 2>/dev/null &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [[ $ticks -ge $((TEST_TIMEOUT * 5)) ]]; then
      RUN_TIMED_OUT=1
      pkill -TERM -P "$pid" 2>/dev/null || true
      sleep 2
      pkill -KILL -P "$pid" 2>/dev/null || true
      break
    fi
    sleep 0.2
    ticks=$((ticks + 1))
  done
  wait "$pid" || RUN_STATUS=$?
  wait "$tee_pid" || true   # tee ends when the test's end of the FIFO closes: no output is lost
  rm -f "$fifo"
  if [[ "$RUN_TIMED_OUT" == 1 ]]; then
    warn "$(basename "$bin") was still running after $TEST_TIMEOUT s and was stopped"
  elif [[ "$RUN_STATUS" -gt 128 ]]; then
    local signal=$((RUN_STATUS - 128)) hint=""
    if [[ "$signal" == 5 ]]; then hint=" (SIGTRAP: a Swift runtime error such as fatalError or an index out of range)"; fi
    warn "$(basename "$bin") crashed with signal $signal$hint"
  fi
}

RESULTS=()
TOTAL_PASSED=0
TOTAL_FAILED=0
TOTAL_SKIPPED=0
FAILURES=0
START=$SECONDS

for suite in "${SUITES[@]}"; do
  step "$suite"
  build_log="$WORK/$suite.build.log"
  if ! swift build "${SWIFT_ARGS[@]}" --product "$suite" > "$build_log" 2>&1; then
    tail -n 40 "$build_log" >&2
    RESULTS+=("$suite|BUILD FAILED|-|-|-|-")
    FAILURES=$((FAILURES + 1))
    continue
  fi
  bin="$(swift build "${SWIFT_ARGS[@]}" --show-bin-path)/$suite"
  home="$WORK/$suite.home"
  mkdir -p "$home"
  log="$WORK/$suite.log"
  run_suite "$bin" "$log" "$home"

  summary="$(grep -E '^[0-9]+ passed, [0-9]+ failed, [0-9]+ skipped in ' "$log" | tail -n 1 || true)"
  passed="-" failed="-" skipped="-" took="-"
  if [[ -n "$summary" ]]; then
    read -r passed _ failed _ skipped _ _ took <<< "$(echo "$summary" | tr -d ',')"
    TOTAL_PASSED=$((TOTAL_PASSED + passed))
    TOTAL_FAILED=$((TOTAL_FAILED + failed))
    TOTAL_SKIPPED=$((TOTAL_SKIPPED + skipped))
  fi
  if [[ "$RUN_TIMED_OUT" == 1 ]]; then
    result="TIMEOUT (${TEST_TIMEOUT} s)"
  elif [[ "$RUN_STATUS" == 0 ]]; then
    result="PASS"
  elif [[ -n "$summary" ]]; then
    result="FAIL"
  elif [[ "$RUN_STATUS" -gt 128 ]]; then
    result="CRASH (signal $((RUN_STATUS - 128)))"
  else
    result="ERROR (exit $RUN_STATUS)"
  fi
  [[ "$result" == "PASS" ]] || FAILURES=$((FAILURES + 1))
  RESULTS+=("$suite|$result|$passed|$failed|$skipped|$took")
done

echo
printf '%-26s %-22s %7s %7s %8s  %s\n' "Suite" "Result" "Passed" "Failed" "Skipped" "Time"
for row in "${RESULTS[@]}"; do
  IFS='|' read -r suite result passed failed skipped took <<< "$row"
  printf '%-26s %-22s %7s %7s %8s  %s\n' "$suite" "$result" "$passed" "$failed" "$skipped" "$took"
done
printf '%-26s %-22s %7s %7s %8s  %s\n' "Total" "" "$TOTAL_PASSED" "$TOTAL_FAILED" "$TOTAL_SKIPPED" "$((SECONDS - START)) s"
echo

if [[ "$FAILURES" -gt 0 ]]; then
  die "$FAILURES of ${#SUITES[@]} suite(s) did not pass"
fi
ok "all ${#SUITES[@]} suite(s) passed"
