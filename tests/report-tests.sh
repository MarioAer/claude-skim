#!/usr/bin/env bash
# Fixture suite for skills/report/report.sh.
#
# The reporter is a pure function from session logs to a summary, so every case
# runs against hand-written logs with no Claude Code process.
#
# Log format, tab separated: <event>\t<subject>\t<value>\t<cause>
#   lines   <path>     <n>                 counted toward the read budget
#   deny    <path>     <file line count>   threshold | budget | bash
#   escape  <path>
#   edit    <path>
#
# Usage: bash tests/report-tests.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPORT="$ROOT/skills/report/report.sh"
PASS=0
FAIL=0

WORK="$(mktemp -d "${TMPDIR:-/tmp}/skim-report.XXXXXX")" || {
  echo "cannot create temp dir" >&2; exit 1
}
trap 'rm -rf "$WORK"' EXIT

# field <output> <label> -> the value printed after "<label>:"
field() {
  printf '%s\n' "$1" | awk -F': *' -v k="$2" '$1==k {print $2; exit}'
}

check() {
  local name="$1" expected="$2" got="$3"
  if [ "$got" = "$expected" ]; then
    PASS=$((PASS + 1)); printf '  ok   %s\n' "$name"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL %s (expected %s, got %s)\n' "$name" "$expected" "$got"
  fi
}

# writes a log and returns the state dir that holds it
statedir() { # <name> <log-body>
  local dir="$WORK/$1"
  mkdir -p "$dir/sessions"
  printf '%b' "$2" > "$dir/sessions/s1.log"
  printf '%s' "$dir"
}

run() { CLAUDE_PLUGIN_DATA="$1" bash "$REPORT" 2>/dev/null; }

echo "report fixture suite"
[ -f "$REPORT" ] || { echo "  FAIL reporter not found at $REPORT"; exit 1; }

# --- no data -----------------------------------------------------------------
D="$(statedir empty "")"
OUT="$(run "$D")"
check "empty log: zero denials"        "0"    "$(field "$OUT" denials)"
check "empty log: escape rate n/a"     "n/a"  "$(field "$OUT" "escape rate")"

# --- denials, no escapes -------------------------------------------------------
D="$(statedir clean "deny\t/a.ts\t900\tthreshold\ndeny\t/b.ts\t500\tthreshold\n")"
OUT="$(run "$D")"
check "two denials counted"            "2"     "$(field "$OUT" denials)"
check "no escapes"                     "0"     "$(field "$OUT" escapes)"
check "escape rate 0.00"               "0.00"  "$(field "$OUT" "escape rate")"
check "files gated"                    "2"     "$(field "$OUT" "files gated")"
check "lines avoided sums denies"      "1400"  "$(field "$OUT" "lines avoided")"
check "gate passes"                    "PASS"  "$(field "$OUT" gate)"

# --- every denial escaped ------------------------------------------------------
D="$(statedir allescaped "deny\t/a.ts\t900\tthreshold\nescape\t/a.ts\t\t\n")"
OUT="$(run "$D")"
check "escape rate 1.00"               "1.00"  "$(field "$OUT" "escape rate")"
check "gate fails at 1.00"             "FAIL"  "$(field "$OUT" gate)"
check "escaped path not counted saved" "0"     "$(field "$OUT" "lines avoided")"

# --- the 0.30 boundary ----------------------------------------------------------
# 10 denials, 3 escapes = 0.30 exactly, which is at the gate and must pass
BODY=""
for i in 1 2 3 4 5 6 7 8 9 10; do BODY="${BODY}deny\t/f${i}.ts\t400\tthreshold\n"; done
for i in 1 2 3; do BODY="${BODY}escape\t/f${i}.ts\t\t\n"; done
D="$(statedir boundary "$BODY")"
OUT="$(run "$D")"
check "boundary rate 0.30"             "0.30"  "$(field "$OUT" "escape rate")"
check "boundary passes the gate"       "PASS"  "$(field "$OUT" gate)"

# 10 denials, 4 escapes = 0.40, over the gate
BODY="${BODY}escape\t/f4.ts\t\t\n"
D="$(statedir overgate "$BODY")"
OUT="$(run "$D")"
check "0.40 fails the gate"            "FAIL"  "$(field "$OUT" gate)"

# --- cumulative-budget denials are reported separately ----------------------------
D="$(statedir causes "deny\t/a.ts\t900\tthreshold\ndeny\t/b.ts\t350\tbudget\ndeny\tcat /c.ts\t800\tbash\n")"
OUT="$(run "$D")"
check "bypass attempts counted"        "1"     "$(field "$OUT" "bypass attempts")"
check "all causes counted as denials"  "3"     "$(field "$OUT" denials)"

# --- several sessions aggregate ----------------------------------------------------
D="$WORK/multi"; mkdir -p "$D/sessions"
printf 'deny\t/a.ts\t100\tthreshold\n' > "$D/sessions/s1.log"
printf 'deny\t/b.ts\t200\tthreshold\nescape\t/b.ts\t\t\n' > "$D/sessions/s2.log"
OUT="$(run "$D")"
check "aggregates across sessions"     "2"     "$(field "$OUT" denials)"
check "aggregate escape rate 0.50"     "0.50"  "$(field "$OUT" "escape rate")"

# --- robustness -----------------------------------------------------------------
D="$(statedir malformed "deny\t/a.ts\t900\tthreshold\ngarbage line with no tabs\n\ndeny\t/b.ts\tnotanumber\tthreshold\n")"
OUT="$(run "$D")"
check "malformed lines skipped"        "2"     "$(field "$OUT" denials)"
check "non-numeric value ignored"      "900"   "$(field "$OUT" "lines avoided")"

OUT="$(CLAUDE_PLUGIN_DATA="$WORK/does-not-exist" bash "$REPORT" 2>/dev/null)"
check "missing state dir reports zero" "0"     "$(field "$OUT" denials)"

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
