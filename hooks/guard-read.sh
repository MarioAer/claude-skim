#!/usr/bin/env bash
# PreToolUse guard. Reads hook JSON on stdin, emits an allow or deny decision.
#
# Rule 9 of the decision order is the important one: ANY error allows. A plugin
# that breaks a session when it malfunctions is worse than no plugin, so every
# failure path falls through to allow.
#
# Mechanics verified against Claude Code 2.1.277; see docs/mechanisms.md.
#   - the decision must be nested under hookSpecificOutput
#   - agent_type is absent on the main thread, and is a BARE name for a
#     project-level agent, so the worker match accepts both forms
#
# State is an append-only event log rather than a rewritten table: Read calls
# are issued in parallel and their hooks run concurrently, so a read-modify-
# write of a shared file would race. Appends of this size are atomic.

set -u

MIN_LINES="${CLAUDE_PLUGIN_OPTION_MIN_LINES:-350}"
MIN_BYTES="${CLAUDE_PLUGIN_OPTION_MIN_BYTES:-40000}"
WORKER_NAME="bulk-reader"

allow() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"%s"}}\n' "${1:-ok}"
  exit 0
}

deny() {
  local rendered
  rendered="$(REASON="$1" python3 -c '
import json, os
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": os.environ["REASON"],
}}))' 2>/dev/null)"
  [ -n "$rendered" ] || allow "deny-render-failed"
  printf '%s\n' "$rendered"
  exit 0
}

command -v python3 >/dev/null 2>&1 || allow "no-python3"

INPUT="$(cat)" || allow "no-stdin"
[ -n "$INPUT" ] || allow "empty-stdin"

# --- parse ------------------------------------------------------------------
FIELDS="$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(3)
ti = d.get("tool_input") or {}
def clean(v):
    return str(v).replace("\x1f", " ").replace("\n", " ") if v is not None else ""
print("\x1f".join([
    clean(d.get("tool_name")),
    clean(d.get("session_id") or "nosession"),
    clean(d.get("agent_type")),
    clean(ti.get("file_path")),
    clean(ti.get("limit")),
    clean(ti.get("command")),
]))' 2>/dev/null)"
[ -n "$FIELDS" ] || allow "unparseable"

# \x1f is a non-whitespace delimiter: bash collapses runs of IFS WHITESPACE
# (space, tab, newline), which would shift every field after an empty one.
IFS=$'\037' read -r TOOL SESSION AGENT PATH_ARG LIMIT COMMAND <<<"$FIELDS"

# --- rule 1: the worker reads freely ----------------------------------------
# Accepts "bulk-reader" and "<plugin>:bulk-reader". A suffix-only match would
# deadlock a non-plugin install, where agent_type carries no prefix.
if [ -n "$AGENT" ]; then
  case "$AGENT" in
    "$WORKER_NAME" | *:"$WORKER_NAME") allow "worker" ;;
  esac
fi

# --- state ------------------------------------------------------------------
STATE_DIR="${CLAUDE_PLUGIN_DATA:-}"
[ -n "$STATE_DIR" ] || STATE_DIR="${TMPDIR:-/tmp}/skim"
LOG="$STATE_DIR/sessions/${SESSION}.log"
mkdir -p "$STATE_DIR/sessions" 2>/dev/null || allow "state-dir-unwritable"
: >>"$LOG" 2>/dev/null || allow "state-unwritable"

find "$STATE_DIR/sessions" -name '*.log' -mtime +7 -delete 2>/dev/null || true

record() { printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >>"$LOG" 2>/dev/null || true; }

# --- edits: record and allow -------------------------------------------------
case "$TOOL" in
  Edit | Write | NotebookEdit | MultiEdit)
    [ -n "$PATH_ARG" ] && record edit "$PATH_ARG"
    allow "edit-recorded"
    ;;
esac

# --- rule 7: bash readers -----------------------------------------------------
if [ "$TOOL" = "Bash" ]; then
  [ -n "$COMMAND" ] || allow "no-command"
  case "$COMMAND" in
    *\|* | *\>*) allow "piped-or-redirected" ;;
  esac
  BASH_VERDICT="$(python3 -c '
import os, re, shlex, sys
cmd = sys.argv[1]
min_lines, min_bytes = int(sys.argv[2]), int(sys.argv[3])
try:
    parts = shlex.split(cmd)
except ValueError:
    print("allow"); raise SystemExit
if not parts:
    print("allow"); raise SystemExit
prog = os.path.basename(parts[0])
if prog not in ("cat", "head", "tail"):
    print("allow"); raise SystemExit
m = re.search(r"-n\s*(\d+)", cmd)
if prog in ("head", "tail"):
    if m is None or int(m.group(1)) <= min_lines:
        print("allow"); raise SystemExit
paths = [p for p in parts[1:] if not p.startswith("-") and os.path.isfile(p)]
for p in paths:
    try:
        size = os.path.getsize(p)
        with open(p, "rb") as fh:
            nlines = fh.read().count(b"\n")
    except OSError:
        continue
    if nlines > min_lines or size > min_bytes:
        print("deny"); raise SystemExit
print("allow")' "$COMMAND" "$MIN_LINES" "$MIN_BYTES" 2>/dev/null)"
  [ "$BASH_VERDICT" = "deny" ] || allow "bash-within-budget"
  record deny "$COMMAND"
  deny "That file exceeds the reading threshold. Delegate the question to the ${WORKER_NAME} subagent, or bound the command by piping it or using head -n. If you genuinely need the whole file, re-issue this identical command and it will be permitted."
fi

# --- only Read is gated from here --------------------------------------------
[ "$TOOL" = "Read" ] || allow "not-a-read"
[ -n "$PATH_ARG" ] || allow "no-path"
[ -f "$PATH_ARG" ] || allow "not-a-file"

# replay the log for this path: "<cumulative_lines> <denials> <edited>"
STATS="$(python3 -c '
import sys
log, target = sys.argv[1], sys.argv[2]
lines = denials = 0
edited = 0
try:
    for row in open(log):
        parts = row.rstrip("\n").split("\t")
        if len(parts) < 2 or parts[1] != target:
            continue
        ev = parts[0]
        val = parts[2] if len(parts) > 2 else ""
        if ev == "lines":
            try:
                lines += int(val)
            except ValueError:
                pass
        elif ev == "deny":
            denials += 1
        elif ev == "edit":
            edited = 1
except OSError:
    pass
print(lines, denials, edited)' "$LOG" "$PATH_ARG" 2>/dev/null)"
[ -n "$STATS" ] || STATS="0 0 0"
read -r CUM DENIALS EDITED <<<"$STATS"

# --- rule 3: a file you have edited is yours ---------------------------------
if [ "$EDITED" = "1" ]; then allow "previously-edited"; fi

# --- rule 4: second strike ----------------------------------------------------
if [ "${DENIALS:-0}" -ge 1 ]; then
  record escape "$PATH_ARG"
  allow "second-strike"
fi

# --- rule 2 and size measurement -----------------------------------------------
MEASURE="$(python3 -c '
import os, sys
p = sys.argv[1]
try:
    with open(p, "rb") as fh:
        blob = fh.read()
except OSError:
    print("binary"); raise SystemExit
if b"\x00" in blob[:8192]:
    print("binary"); raise SystemExit
print(blob.count(b"\n"), os.path.getsize(p))' "$PATH_ARG" 2>/dev/null)"
[ -n "$MEASURE" ] || MEASURE="binary"
if [ "$MEASURE" = "binary" ]; then allow "binary-or-unreadable"; fi
read -r NLINES NBYTES <<<"$MEASURE"

# --- rule 5: bounded read within remaining budget --------------------------------
if [ -n "$LIMIT" ]; then
  REMAINING=$((MIN_LINES - CUM))
  if [ "$LIMIT" -le "$REMAINING" ]; then
    record lines "$PATH_ARG" "$LIMIT"
    allow "bounded-within-budget"
  fi
  record deny "$PATH_ARG"
  deny "Cumulative reads of this file have reached the budget (${CUM} of ${MIN_LINES} lines). Reading a file in chunks costs more than reading it once. Delegate to the ${WORKER_NAME} subagent, or re-issue this identical call to take the whole file."
fi

# --- rule 6: small enough --------------------------------------------------------
if [ "$NLINES" -le "$MIN_LINES" ] && [ "$NBYTES" -le "$MIN_BYTES" ]; then
  record lines "$PATH_ARG" "$NLINES"
  allow "within-thresholds"
fi

# --- rule 8: deny ------------------------------------------------------------------
record deny "$PATH_ARG"
deny "This file is ${NLINES} lines / ${NBYTES} bytes, above the ${MIN_LINES}-line / ${MIN_BYTES}-byte threshold. Outline it first by grepping for declarations, then read the region you need with offset and limit; or delegate the question to the ${WORKER_NAME} subagent. If you need the full file to edit or debug it, re-issue this identical Read and it will be permitted."
