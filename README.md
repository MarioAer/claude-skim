# skim

A Claude Code plugin that keeps bulk file contents out of the main model's
context.

Reading a large file costs its full token price on the way in, then again at the
cache-read rate on every later turn. Most of that content is never used. `skim`
teaches the model to outline a file before reading it, and blocks the oversized
reads that slip through.

## Install

```
/plugin marketplace add MarioAer/claude-skim
/plugin install skim
```

Or for one session: `claude --plugin-dir /path/to/claude-skim`

## What it does

**A skill** that runs before any large read: size the file, grep its
declarations, then read only the region that matters — or grep for the
distinguishing property when no single region holds the answer.

**A guard** (`PreToolUse` hook) that denies reads over 350 lines or 40 KB and
says why. Re-issue the identical call and it is permitted: a one-round-trip
toll, not a wall. Files you have already edited, bounded reads within budget,
binaries, and piped `cat`/`head` are never blocked.

**A worker** (`bulk-reader`, pinned to Haiku) as a fallback for the rare file
that outlining cannot reduce. It answers with `path:line` anchors *and* the
verbatim lines, so citations are checkable. In practice it is almost never
needed — see below.

If anything malfunctions — missing file, unwritable state, malformed input — the
read is allowed. A plugin that breaks your session is worse than no plugin.

## Does it work

Measured in this repository, five repetitions per arm, Claude Sonnet:

| Task shape | Whole-file reads before | After |
| --- | --- | --- |
| Retrieval, answer is a greppable string | 1 / 5 | 0 / 5 |
| Comprehension, no string to search for | 5 / 5 | 0 / 5 |
| One question across three large files | 15 / 15 files | 0 |

Mean tokens fell 26% on the comprehension task and 27% on the three-file one,
with no overlap between the two sets in either case and no loss of answer
quality. On the three-file task the skill arm was *more* accurate: it found a
race condition every baseline run missed.

Read [`docs/benchmark.md`](docs/benchmark.md) before trusting those numbers. It
lists what the measurement does not cover, and records a contaminated run that
had to be discarded.

**Two honest caveats.** The `Explore` subagent plus a project instruction has
not been benchmarked against this plugin, and it remains the most plausible way
`skim` turns out to be unnecessary.

And the worker has not earned its place. The three-file scenario was built to
favour delegation and delegation was chosen zero times out of five; outlining
handled it. The worker stays as a fallback, but skim is an outlining plugin,
not a delegation one.

## Requirements

- A recent Claude Code. Verified on 2.1.277.
- `bash` and `python3`.
- `CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1` overrides the worker's model pin. There
  is no defence against it.

Thresholds (350 lines, 40 KB) are provisional. Break-even is near 248 lines.

## Privacy

All counters are local and nothing is transmitted. The session state under
`${CLAUDE_PLUGIN_DATA}` records file paths from your machine; logs older than
seven days are pruned.

## Development

```
bash tests/run-tests.sh              # 18 guard fixtures, no Claude process needed
claude plugin validate . --strict
```

The benchmark harness is in [`evals/`](evals/README.md). Verified hook
behaviour, including several published claims that did not survive testing, is
in [`docs/mechanisms.md`](docs/mechanisms.md).

## License

Apache-2.0.
