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

**A worker** (`bulk-reader`, pinned to Haiku) for questions that still need the
whole file. It answers with `path:line` anchors *and* the verbatim lines, so
citations are checkable.

If anything malfunctions — missing file, unwritable state, malformed input — the
read is allowed. A plugin that breaks your session is worse than no plugin.

## Does it work

Measured in this repository, five repetitions per arm, Claude Sonnet:

| Task shape | Whole-file reads before | After |
| --- | --- | --- |
| Retrieval, answer is a greppable string | 1 / 5 | 0 / 5 |
| Comprehension, no string to search for | 5 / 5 | 0 / 5 |

On the comprehension task mean tokens fell from 78,182 to 57,582, with no
overlap between the two sets and no loss of answer quality.

Read [`docs/benchmark.md`](docs/benchmark.md) before trusting those numbers. It
lists what the measurement does not cover.

**Two honest caveats.** The `Explore` subagent plus a project instruction has
not been benchmarked against this plugin, and it remains the most plausible way
`skim` turns out to be unnecessary. And the Haiku worker is the least justified
part: outlining removed every whole-file read on its own, and no agent chose to
delegate in 30 baseline runs.

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

Apache-2.0. Prior art: Spotify's `shunt` plugin established the pattern of a
read-blocking hook plus a cheap worker model.
