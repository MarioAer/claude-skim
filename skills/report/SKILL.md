---
name: report
description: Use when asked how skim is performing, whether the read guard is paying for itself, what the escape rate is, how often reads were blocked, or to check skim against its own pass gate
---

# skim report

## Overview

Prints what skim's guard has done across the retained session logs, and judges
it against the gate the design fixed in advance.

## Running it

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/report/report.sh"
```

Show the output as printed. Do not recompute or round the figures.

## Reading the result

| Field | Meaning |
| --- | --- |
| `denials` | Reads the guard blocked |
| `escapes` | Blocked reads the model then re-issued and was permitted |
| `escape rate` | escapes ÷ denials — **the number that matters** |
| `gate` | PASS at or below 0.30, FAIL above it |
| `bypass attempts` | Reads denied by cumulative accounting, not by file size |
| `lines avoided` | Lines the main thread never took |

**A failing gate is a real result, not a bug to explain away.** Above an escape
rate of roughly 0.30 the toll has degraded into a habit of reading everything
twice, and skim costs more than it saves. If the gate fails, say so plainly and
recommend either raising `min_lines` so fewer reads are gated, or uninstalling.

`lines avoided` is an upper bound. It does not subtract content the model read
again afterwards through a bounded call, so treat it as a ceiling rather than a
measured saving.

A small number of denials makes the rate meaningless — one stubborn file can
put it at 1.0. Say so rather than reporting a verdict on a handful of events.

## Privacy

Everything is read from local session logs and nothing is transmitted. Those
logs contain absolute file paths from this machine, so do not paste the raw log
anywhere; the summary carries no paths.
