#!/usr/bin/env bash
# Summarise skim's guard activity across the retained session logs.
#
# Reads ${CLAUDE_PLUGIN_DATA}/sessions/*.log, which the guard appends to. All
# figures are local; nothing is transmitted. Logs are pruned after seven days
# by the guard, so this is a rolling window rather than all time.
#
# Usage: bash skills/report/report.sh

set -u

GATE="0.30"

STATE_DIR="${CLAUDE_PLUGIN_DATA:-}"
[ -n "$STATE_DIR" ] || STATE_DIR="${TMPDIR:-/tmp}/skim"
SESSIONS="$STATE_DIR/sessions"

command -v python3 >/dev/null 2>&1 || {
  echo "skim: python3 not available, cannot report" >&2
  exit 0
}

python3 - "$SESSIONS" "$GATE" <<'PY'
import glob, os, sys

sessions, gate = sys.argv[1], float(sys.argv[2])

denials = escapes = bypass = 0
denied_lines = {}      # path -> lines denied, summed
escaped_paths = set()
gated_paths = set()
files = sorted(glob.glob(os.path.join(sessions, "*.log")))

for path in files:
    try:
        handle = open(path, encoding="utf-8", errors="replace")
    except OSError:
        continue
    with handle:
        for row in handle:
            parts = row.rstrip("\n").split("\t")
            if len(parts) < 2:
                continue
            event, subject = parts[0], parts[1]
            value = parts[2] if len(parts) > 2 else ""
            cause = parts[3] if len(parts) > 3 else ""
            if event == "deny":
                denials += 1
                gated_paths.add(subject)
                if cause == "budget":
                    bypass += 1
                try:
                    denied_lines[subject] = denied_lines.get(subject, 0) + int(value)
                except ValueError:
                    pass
            elif event == "escape":
                escapes += 1
                escaped_paths.add(subject)

# Lines the main thread never took. Upper bound: the model may have read the
# same region afterwards with a bounded call, which this does not subtract.
avoided = sum(n for p, n in denied_lines.items() if p not in escaped_paths)

if denials:
    rate = escapes / denials
    rate_text = f"{rate:.2f}"
    verdict = "PASS" if rate <= gate else "FAIL"
else:
    rate_text = "n/a"
    verdict = "n/a"

print(f"sessions: {len(files)}")
print(f"files gated: {len(gated_paths)}")
print(f"denials: {denials}")
print(f"escapes: {escapes}")
print(f"bypass attempts: {bypass}")
print(f"escape rate: {rate_text}")
print(f"gate: {verdict}")
print(f"lines avoided: {avoided}")
print()
print(f"The gate is an escape rate at or below {gate:.2f}. Above it, the toll has")
print("degraded into a habit of reading everything twice and skim costs more")
print("than it saves. 'lines avoided' is an upper bound: it does not subtract")
print("content re-read later through a bounded call.")
print("All figures are local to this machine and cover the last seven days.")
PY
