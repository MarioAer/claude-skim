#!/usr/bin/env bash
# Fixture suite for hooks/guard-read.sh.
#
# The guard is a pure function from hook JSON on stdin to a decision on stdout,
# so every case below runs without a Claude Code process.
#
# Usage: bash tests/run-tests.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$ROOT/hooks/guard-read.sh"
PASS=0
FAIL=0

WORK="$(mktemp -d "${TMPDIR:-/tmp}/skim-tests.XXXXXX")" || {
  echo "cannot create temp dir" >&2; exit 1
}
trap 'rm -rf "$WORK"' EXIT

# --- fixtures ---------------------------------------------------------------
SMALL="$WORK/small.ts"
BIG="$WORK/big.ts"
ONELINE="$WORK/bundle.min.js"
BINARY="$WORK/blob.bin"
AT="$WORK/at-threshold.ts"
OVER="$WORK/over-threshold.ts"

for i in $(seq 1 40); do echo "export const small${i} = ${i};"; done > "$SMALL"
for i in $(seq 1 1200); do echo "export const big${i} = ${i}; // padding padding padding"; done > "$BIG"
# exactly at and one past the 350-line threshold, kept under the byte limit so
# the line rule is what is being tested
for i in $(seq 1 350); do echo "const a${i}=${i};"; done > "$AT"
for i in $(seq 1 351); do echo "const b${i}=${i};"; done > "$OVER"
python3 -c "open('$ONELINE','w').write('var x=' + 'a'*60000 + ';')"
python3 -c "open('$BINARY','wb').write(b'\x7fELF' + bytes(range(256))*40)"

# --- helpers ----------------------------------------------------------------
# decision <json> -> prints allow|deny
decision() {
  printf '%s' "$1" | bash "$GUARD" 2>/dev/null \
    | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    print('MALFORMED'); raise SystemExit
print(d.get('hookSpecificOutput',{}).get('permissionDecision','MISSING'))
" 2>/dev/null
}

check() {
  local name="$1" expected="$2" got="$3"
  if [ "$got" = "$expected" ]; then
    PASS=$((PASS + 1)); printf '  ok   %s\n' "$name"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL %s (expected %s, got %s)\n' "$name" "$expected" "$got"
  fi
}

# fresh state directory per case, so cases do not leak into each other
fresh() {
  CLAUDE_PLUGIN_DATA="$WORK/state-$RANDOM"
  export CLAUDE_PLUGIN_DATA
  mkdir -p "$CLAUDE_PLUGIN_DATA"
}

read_json() { # path [limit] [agent_type] [session]
  python3 - "$@" <<'PY'
import json,sys
path=sys.argv[1]
limit=sys.argv[2] if len(sys.argv)>2 and sys.argv[2] else None
agent=sys.argv[3] if len(sys.argv)>3 and sys.argv[3] else None
sess=sys.argv[4] if len(sys.argv)>4 and sys.argv[4] else "sess-1"
d={"hook_event_name":"PreToolUse","session_id":sess,"tool_name":"Read",
   "tool_input":{"file_path":path}}
if limit: d["tool_input"]["limit"]=int(limit)
if agent: d["agent_type"]=agent; d["agent_id"]="a1"
print(json.dumps(d))
PY
}

bash_json() { # command
  python3 - "$1" <<'PY'
import json,sys
print(json.dumps({"hook_event_name":"PreToolUse","session_id":"sess-1",
  "tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))
PY
}

edit_json() { # path
  python3 - "$1" <<'PY'
import json,sys
print(json.dumps({"hook_event_name":"PreToolUse","session_id":"sess-1",
  "tool_name":"Edit","tool_input":{"file_path":sys.argv[1]}}))
PY
}

echo "guard fixture suite"
[ -x "$GUARD" ] || [ -f "$GUARD" ] || { echo "  FAIL guard not found at $GUARD"; exit 1; }

# --- cases ------------------------------------------------------------------

fresh
check "oversized file denies"            deny  "$(decision "$(read_json "$BIG")")"

fresh
check "small file allows"                allow "$(decision "$(read_json "$SMALL")")"

fresh
check "exactly at threshold allows"      allow "$(decision "$(read_json "$AT")")"

fresh
check "one line over threshold denies"   deny  "$(decision "$(read_json "$OVER")")"

fresh
check "less of oversized denies"         deny  "$(decision "$(bash_json "less $BIG")")"

fresh
check "more of oversized denies"         deny  "$(decision "$(bash_json "more $BIG")")"

fresh
CLAUDE_PLUGIN_OPTION_MIN_LINES=garbage
export CLAUDE_PLUGIN_OPTION_MIN_LINES
check "non-numeric threshold falls back" deny  "$(decision "$(read_json "$BIG")")"
unset CLAUDE_PLUGIN_OPTION_MIN_LINES

fresh
check "bounded read under budget allows" allow "$(decision "$(read_json "$BIG" 100)")"

fresh
decision "$(read_json "$BIG" 300)" >/dev/null
check "cumulative over budget denies"    deny  "$(decision "$(read_json "$BIG" 300)")"

fresh
decision "$(read_json "$BIG" 100)" >/dev/null
decision "$(read_json "$BIG" 100)" >/dev/null
decision "$(read_json "$BIG" 100)" >/dev/null
check "fourth chunked read denies"       deny  "$(decision "$(read_json "$BIG" 100)")"

fresh
check "plugin-scoped worker allows"      allow "$(decision "$(read_json "$BIG" "" "skim:bulk-reader")")"

fresh
check "bare-name worker allows"          allow "$(decision "$(read_json "$BIG" "" "bulk-reader")")"

fresh
check "unrelated subagent still gated"   deny  "$(decision "$(read_json "$BIG" "" "Explore")")"

fresh
decision "$(edit_json "$BIG")" >/dev/null
check "previously edited path allows"    allow "$(decision "$(read_json "$BIG")")"

fresh
decision "$(read_json "$BIG")" >/dev/null
check "second identical read allows"     allow "$(decision "$(read_json "$BIG")")"

fresh
check "one-line oversized bytes denies"  deny  "$(decision "$(read_json "$ONELINE")")"

fresh
check "binary file allows"               allow "$(decision "$(read_json "$BINARY")")"

fresh
check "cat of oversized denies"          deny  "$(decision "$(bash_json "cat $BIG")")"

fresh
check "cat piped to grep allows"         allow "$(decision "$(bash_json "cat $BIG | grep foo")")"

fresh
check "head -n 20 allows"                allow "$(decision "$(bash_json "head -n 20 $BIG")")"

fresh
check "nonexistent file allows"          allow "$(decision "$(read_json "$WORK/nope.ts")")"

fresh
check "malformed stdin allows"           allow "$(decision 'not json at all')"

fresh
CLAUDE_PLUGIN_DATA=/proc/nonexistent-cannot-write
export CLAUDE_PLUGIN_DATA
check "unwritable state dir allows"      allow "$(decision "$(read_json "$BIG")")"

# --- summary ----------------------------------------------------------------
echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
