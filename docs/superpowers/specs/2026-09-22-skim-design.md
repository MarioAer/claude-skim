# skim: design

Date: 2026-09-22
Revised: 2026-09-29
Status: partly superseded by measurement. Read
[`docs/benchmark.md`](../../benchmark.md) and
[`docs/mechanisms.md`](../../mechanisms.md) alongside this document; where they
disagree with it, they win, because they record what was observed.
Repository: https://github.com/MarioAer/claude-skim
License: Apache-2.0

> **Revision note (2026-09-29).** Sections 2, 3, 5.2, 6, 7, 10 and 11 were
> changed after the skill was built and the hook mechanisms were spiked. The
> substantive corrections, in descending order of consequence:
>
> 1. The targeting was inverted. Retrieval questions, which section 2 named as
>    the goal, are the case the baseline already handles. Comprehension and
>    debugging, which section 3 excluded, are the case that fails every time.
> 2. Section 6's denial JSON was malformed and would have failed silently.
> 3. Section 5.2's worker match would have deadlocked a non-plugin install.
> 4. Section 7's per-path table would have raced under parallel reads.
>
> Original text is kept where it is still accurate. Superseded claims are marked
> rather than deleted, because the reasoning that produced them is worth keeping
> next to the evidence that overturned them.

## 1. Problem

Claude Code sessions spend a large share of their input tokens on reading files. When
the main session runs an expensive model, every line read is billed at that model's
input rate, and the file contents remain in the conversation prefix for the rest of the
session, where they are re-billed at the cache-read rate on every subsequent turn and
push the session toward compaction.

Most of that reading does not require the capability of the main model. Answering
"where is the retry budget configured" or "which types implement this interface" is
retrieval, not reasoning.

> **Superseded.** Both examples are wrong, and the second paragraph reaches the
> right conclusion for the wrong case. Measured on those exact questions, the
> main model already greps and then reads a 40-70 line window four times in
> five. Retrieval is the shape that needs no help, because the answer is a
> string and the model searches for it.

## 2. Goal

Keep bulk file contents out of the main model's context, independently of which
model the main session runs.

The target is the **comprehension-shaped** read: a question about a file that no
string search answers, such as "why does this budget never trip" or "which of
these functions violates the invariant". There the main model reads the file
whole, every time, and pays for the whole file to use a fraction of it.

Two mechanisms serve that goal, and measurement puts them in this order:

1. **Outlining before reading.** Grep the declarations, identify the region that
   matters or the property that distinguishes it, then read only that. This does
   the work: it removed every whole-file read in testing at no cost to answer
   quality.
2. **Delegating to a Haiku worker**, for the residue where neither an outline
   nor a property grep localises the answer. This remains unproven. It was
   chosen spontaneously in none of 30 baseline repetitions, and the single
   measured delegation won on tokens by a margin that may not survive counting
   the nested subagent's own usage.

> The original goal statement read: "Route bulk file reading to a Claude Haiku
> 4.5 subagent, so that file contents never enter the main model's context." The
> routing destination turned out to be the less important half.

## 3. Non-goals

| Excluded | Reason |
| --- | --- |
| Code generation delegation | Spotify's `code-write` half writes generated files to disk unreviewed. Low value, high risk. |
| Any network dependency | The original requires an internal CLI and a server-side model registry. This design uses only native Claude Code primitives. |
| Telemetry leaving the machine | All counters are written locally and never transmitted. |

> **Removed from this table:** "Delegating editing, debugging, or architectural
> judgment — these require exact context." That exclusion carved out precisely
> the case the plugin exists for. Debugging and review are where the main model
> reads whole files 5 times in 5.
>
> The premise was still half right: these tasks do need exact context. The
> resolution is not to exempt them but to serve them differently — outline to
> find the region, then read that region **in full**, which is what the skill's
> step 5 now says. Exact context for the part that matters is cheaper than
> approximate context for all of it.

## 4. Prior art

Spotify's `shunt` plugin (`spotify/portal-ai-plugins`) established the pattern: a
`PreToolUse` hook blocking oversized reads, scripts invoking a cheap worker model, and
skills teaching the main model when to delegate. It reports 82 to 94 percent token
savings on bulk reads in a Java monorepo.

This design differs in four respects.

1. The worker is a native Claude Code subagent pinned by frontmatter, not an external
   CLI calling a server-side model registry. The plugin has no runtime dependencies
   beyond `bash` and `jq`.
2. The hard block is replaced by a one-round-trip toll, because blocking reads also
   blocks the reads that must precede edits.
3. Reads are accounted cumulatively per file, closing the chunked-read bypass.
4. The savings claim is measured in this repository against a defined benchmark, with
   a pass threshold fixed in advance, rather than inherited.

## 5. Architecture

| Component | Responsibility |
| --- | --- |
| `agents/bulk-reader.md` | Worker subagent. Pinned to `model: haiku`. Tools restricted to `Read`, `Grep`, `Glob`. |
| `hooks/guard-read.sh` | Sole enforcement point. Reads hook JSON on stdin, emits an allow or deny decision. |
| `hooks/count-delegation.sh` | `SubagentStart` and `SubagentStop` counter for the measurement gate. Not built; see section 10. |
| `hooks/hooks.json` | Wires the guard to `PreToolUse`. Uses exec form: an unquoted `${CLAUDE_PLUGIN_ROOT}` word-splits on a path containing a space. |
| `skills/reading-large-files/SKILL.md` | Teaches outlining before reading, with delegation as the last branch. Renamed from `skills/read/`, which collided with the tool name. |
| `skills/report/SKILL.md` | Prints the current session's measurement counters. Not built. |
| `.claude-plugin/plugin.json` | Manifest. `author` carries no email, since the repository is public. |
| `.claude-plugin/marketplace.json` | Makes the repository installable as its own marketplace. Not built. |

The skill, not the guard, turned out to be the load-bearing component. The guard
is a backstop for what the skill misses: with the plugin loaded whole, the model
read the target region directly and the guard never had to deny.

### 5.1 Model pinning

Claude Code resolves a subagent's model in this order:

1. per-invocation `model` parameter
2. subagent frontmatter `model`
3. `CLAUDE_CODE_SUBAGENT_MODEL` environment variable
4. the main conversation's model

Frontmatter therefore outranks a user's global subagent-model default, which is the
mechanism this design depends on. Two constraints follow.

- **A minimum version is required**, because the resolution order above has not
  always held. The specific figure of 2.1.251 given here could not be sourced to
  any release note and should not be quoted until it can be. Verified behaviour
  is on 2.1.277.
- **`CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1` defeats the pin.** When set together with
  `CLAUDE_CODE_SUBAGENT_MODEL`, all frontmatter `model` fields are ignored. The plugin
  has no defence against this and documents it as an incompatibility. Documented
  from 2.1.257.

The frontmatter uses the alias `haiku` rather than a dated model identifier, so the
plugin follows the current Haiku generation without releases.

### 5.2 Why the worker does not deadlock

Hooks fire for tool calls made inside subagents, and the hook input carries `agent_id`
and `agent_type`. For an agent shipped by a plugin, `agent_type` is the plugin-scoped
identifier, `skim:bulk-reader`.

**Confirmed.** The stdin-dump task was carried out; `agent_type` is exactly
`skim:bulk-reader`. `agent_id` and `agent_type` are **absent on the main
thread**, so the guard must read absence as "main thread" rather than as a
parse failure.

> **Corrected.** The original rule allowed any read whose `agent_type` *ends in*
> `:bulk-reader`. For a project-level agent in `.claude/agents/`, `agent_type`
> is the bare name `bulk-reader` with no prefix, so the suffix test fails, the
> worker is gated by its own guard, and the plugin deadlocks. The guard matches
> both the bare name and any `<prefix>:bulk-reader`.

## 6. Guard decision order

Evaluated top to bottom; the first match decides.

| # | Condition | Decision |
| --- | --- | --- |
| 1 | `agent_type` is `bulk-reader` or ends in `:bulk-reader` | allow |
| 2 | Target file is binary (NUL byte in first 8 KB) | allow |
| 3 | Path was edited or written earlier in this session | allow |
| 4 | Identical `Read` of this path already denied once this session | allow, increment `escapes` |
| 5 | `Read` with `limit`, and cumulative lines + `limit` within budget | allow, add to cumulative |
| 6 | File within both thresholds | allow, record |
| 7 | `Bash` `cat`/`head`/`tail` that is piped, redirected, or bounded within budget | allow |
| 8 | Anything else | deny |
| 9 | Any error at any point | allow |

Rule 9 is not a fallback, it is a requirement. A missing file, an absent `jq`, an
unwritable state directory, or malformed input must all allow the read. A plugin that
breaks a session when it malfunctions is worse than no plugin.

Rule 3 exists because a file the model has already modified is a file it owns.

Rule 4 is the escape hatch. The deny message in rule 8 states it explicitly: if the
full file is needed to edit, debug, or follow control flow, re-issuing the identical
read will be permitted. This converts the block from a wall into a one-round-trip toll.

Rules 5 and 6 evaluate a dual threshold. A single-line minified bundle or a one-line
JSON fixture passes any line-based gate while carrying hundreds of kilobytes, so the
byte threshold is what makes the plugin language-agnostic rather than an incidental
extra.

Denial is expressed in JSON on stdout with exit status 0, not as exit status 2.
Exit status 2 blocks but cannot carry structured output, and the denial reason
is the only instruction the main model receives at that moment.

> **Corrected shape.** A bare `permissionDecision` at the top level is not
> recognised and fails silently, leaving the read permitted. It must nest:
>
> ```json
> {"hookSpecificOutput":{"hookEventName":"PreToolUse",
>  "permissionDecision":"deny","permissionDecisionReason":"..."}}
> ```

**The reason does reach the model.** This was the one assumption that could have
invalidated the whole toll, and it was tested directly: the text of
`permissionDecisionReason` arrives as a `tool_result` block with
`is_error: true`, and a round trip of deny, re-issue, allow completes with the
correct answer. Open issue reports to the contrary did not reproduce on 2.1.277.

**No interception alternative exists.** A `PostToolUse` hook cannot substitute a
summary for the file: `updatedToolOutput` was ignored at both the top level and
under `hookSpecificOutput`, as was `additionalContext`. `PreToolUse` deny is the
only enforcement point available, so rule 4 is not one option among several.

## 7. Session state

Location: `${CLAUDE_PLUGIN_DATA}/sessions/<session_id>.log`, an **append-only
event log**, one line per event: `<event>\t<path>\t<value>`, with events
`lines`, `deny`, `escape` and `edit`. Per-path figures are obtained by replaying
the log.

> **Changed from a per-path table.** The original stored one mutable record per
> path in a `.tsv`. Claude Code issues `Read` calls in parallel and runs their
> hooks concurrently, so a read-modify-write of a shared record races and loses
> updates. Appends of this size are atomic, which makes the log correct under
> concurrency without a lock file. Replaying costs nothing at these volumes.

Replay yields the same quantities the table held: `cumulative_lines` is the sum
of `lines` values, `denials` and `escapes` are counts, `edited` is the presence
of an `edit` event. `denials` and `escapes` stay distinct because the
measurement gate in section 10 is the ratio between them.

For an inline plugin loaded with `--plugin-dir`, `CLAUDE_PLUGIN_DATA` resolves
to `~/.claude/plugins/data/<name>-inline`, not `<name>`, and an exported value
does not override it.

Remaining budget for a path is the lower of the two thresholds minus
`cumulative_lines`, expressed in lines; a bounded read is within budget when its
`limit` does not exceed that remainder.

Session files older than seven days are pruned when the state file is written. The
state directory is created on demand; failure to create or write it falls through to
rule 9.

Cumulative accounting is what closes the chunked-read bypass. Without it, a main model
that reads a 1,400-line file in four `limit=349` calls pays the full token cost of the
file plus four round trips, which is strictly worse than having no plugin installed.

## 8. Delegation contract

The worker returns structured bullets. Each claim carries both a `path:line` anchor and
the verbatim line or lines the claim rests on, up to three.

Carrying the quoted evidence alongside the anchor is what makes the citation
checkable. An anchor alone is not verifiable: a wrong line number does not produce an
error, it produces real but unrelated content, and the main model then believes it has
confirmed a claim it has not. With the quoted text present, a mismatch is visible.

The worker prompt additionally requires:

- Negative claims, such as the absence of a check, must be marked as unverifiable by
  citation, since no line can be cited for an absence.
- Questions requiring files that were not supplied must be answered
  "not determinable from the given files" rather than inferred.
- No language-specific assumptions. The worker handles source in any language,
  configuration, structured data, logs, and prose.

## 9. Configuration

| Key | Type | Default | Notes |
| --- | --- | --- | --- |
| `min_lines` | number | 350 | Provisional. Inherited from `shunt`. Break-even recomputed at roughly 248 lines, not the 190 stated here, so 350 still sits above it but by less margin. |
| `min_bytes` | number | 40000 | Provisional. Guards line-dense files. |

Values reach the guard as `CLAUDE_PLUGIN_OPTION_MIN_LINES` and
`CLAUDE_PLUGIN_OPTION_MIN_BYTES`. Whether an unconfigured default is exported to the
hook process is undocumented, so the guard carries its own fallbacks and never assumes
the variables are present.

Both defaults are labelled provisional in the README until the benchmark in section 10
replaces them with measured values.

## 10. Measurement and the pass gate

The risk this design cannot resolve analytically is that the rule 4 toll degrades into
a habit: the main model learns to issue every oversized read twice and never delegates.
If that happens the plugin is not merely ineffective, it is a net cost.

Therefore measurement is a shipped deliverable with a threshold fixed before any data
is collected.

### 10.1 Counters

`SubagentStart` and `SubagentStop` hooks matching `skim:bulk-reader` record delegations
into the session state. The guard records denials, second strikes, and bypass
denials. `/skim:report` prints:

| Metric | Definition |
| --- | --- |
| Delegation rate | delegations divided by (delegations plus escapes) |
| Escape rate | escapes divided by denials |
| Bypass attempts | reads denied by cumulative accounting |
| Lines avoided | main-thread lines never read, less summary lines returned |

All counters are local. Nothing is transmitted. The README states this, because the
state file records file paths from the user's machine.

### 10.2 Threshold derivation

Let `D` be the cost of one direct read on the main model, `G` the cost of the delegated
path, and `T` the toll paid when a denial is followed by a second-strike read. Using
the cost model for a 350-line file with an expensive main model and Haiku as worker:
`D` is approximately 0.0225, `G` approximately 0.0182, and `T` approximately 0.004, in
US dollars.

With escape rate `E`, expected cost per oversized read is `E(D + T) + (1 - E)G`.
Setting that equal to `D` and solving gives `E` of approximately 0.52. At an escape
rate above roughly one half, the plugin costs more than doing nothing on token spend
alone.

> **Corrected.** The algebra is right; `T` is not. A denial plus a re-issued
> call costs about 0.0016, not 0.004, which puts the true break-even near 0.76.
> The error ran in the conservative direction: the 0.30 gate sits further below
> the real break-even than this section claims, so the gate stands.
>
> A larger omission: this section compares single reads, while section 1
> correctly identifies the recurring cache-read cost as the actual problem. Over
> a fifty-turn session a 350-line file costs roughly five times its initial
> read. On that horizon the saving is near 79 percent rather than the 19 percent
> a single-read comparison suggests. The design undersells itself.
>
> The whole model also assumes an expensive main model. The delegation prompt is
> billed at main-model output rates, so the margin narrows sharply as the main
> model gets cheaper.

The gate is set at **escape rate at or below 0.30**, a deliberate margin below the
break-even point. This ignores the context-preservation benefit, which makes the gate
conservative rather than generous.

### 10.3 Benchmark

Three corpora crossed with three task shapes, so that neither a single language nor a
single workflow determines the result:

| Corpora | Task shapes |
| --- | --- |
| A compiled-language service | Question answering |
| A TypeScript front end | Refactoring |
| A prose and configuration corpus | Debugging |

Three arms per cell:

1. Plain read on the main model.
2. The built-in `Explore` subagent. This is the real competitor. `Explore` inherits the
   main conversation's model, so it does not reduce cost, but it does return
   conclusions rather than file dumps.
3. `skim`.

> **Partly executed, and rescoped.** Twenty-five repetitions were run across
> three task shapes on one synthetic corpus; results are in
> [`docs/benchmark.md`](../../benchmark.md) and the harness in
> [`evals/`](../../../evals/README.md). The `Explore` arm has not been run, so
> open question 2 stays open.
>
> 27 hand-run cells is not a shippable deliverable, and scoping the gate out of
> existence would lose the best idea in this document. `claude plugin eval`
> supplies most of the harness off the shelf: `--ablation with-without` runs the
> plugin-on and plugin-off arms and reports the delta, `--runs` handles
> repetition, `--threshold` turns the pass gate into a CI exit code, and
> `--json` carries per-run cost. Only the `Explore` arm needs building by hand.

### 10.4 Reporting the outcome

If the escape rate exceeds 0.30, the README states that the plugin FAILED its own gate
and explains that the toll degrades to an expensive no-op. If `skim` does not beat
`Explore` combined with a project instruction to prefer it, the README states that too
and recommends the instruction instead of the plugin.

No savings percentage appears in the README until it is measured in this repository.
The figures from Spotify's article are not transferable: they were produced against a
different worker model, a different price ratio, and a single monorepo.

## 11. Testing

The guard is a pure function from JSON to JSON, so it is tested directly with fixtures
and no Claude Code process. Tests are written before the implementation.

| Case | Expected |
| --- | --- |
| Main-thread read of an oversized file | deny, `denials` incremented |
| Main-thread read of a small file | allow |
| Read with `limit` under budget | allow |
| Read with `limit` pushing cumulative over budget | deny |
| Four sequential `limit` reads of one large file | fourth denies |
| Read where `agent_type` is `skim:bulk-reader` | allow |
| Read of a previously edited path | allow |
| Second identical read after a denial | allow, `escapes` incremented |
| One-line file exceeding the byte threshold | deny |
| Binary file | allow |
| `cat` of an oversized file | deny |
| `cat` of an oversized file piped to `grep` | allow |
| `head -n 20` of an oversized file | allow |
| Nonexistent file | allow |
| Malformed JSON on stdin | allow |
| Unwritable state directory | allow |

**Built, and green.** `tests/run-tests.sh` implements every case above plus one
this table missed: a read whose `agent_type` is the bare `bulk-reader`, which
guards the deadlock described in section 5.2. Tests were written first and the
suite failed before the guard existed.

Continuous integration runs `shellcheck`, the fixture suite, and
`claude plugin validate . --strict`. It installs the current Claude Code rather
than a pinned one, which is deliberate: that is how the unquoted
`${CLAUDE_PLUGIN_ROOT}` in the hook wiring was caught, by a validator newer than
the local install.

## 12. Repository layout

```
claude-skim/
├── .claude-plugin/
│   ├── plugin.json
│   └── marketplace.json
├── agents/
│   └── bulk-reader.md
├── hooks/
│   ├── hooks.json
│   ├── guard-read.sh
│   └── count-delegation.sh
├── skills/
│   ├── reading-large-files/SKILL.md
│   └── report/SKILL.md
├── tests/
│   └── run-tests.sh
├── evals/
│   ├── gen-corpus.sh
│   ├── measure.py
│   ├── scenarios.md
│   └── README.md
├── docs/
│   ├── benchmark.md
│   ├── mechanisms.md
│   └── superpowers/specs/
├── .github/workflows/ci.yml
├── README.md
└── LICENSE
```

Two changes from the original layout. The reading skill is
`reading-large-files`, not `read`: a skill's directory name is its invocation
name, and `read` reads as a tool rather than a technique. The benchmark harness
lives in `evals/`, not under `tests/`: CI runs `tests/run-tests.sh` on every
push, and the benchmark dispatches subagents, which does not belong in a CI
step. `evals/` is also where `claude plugin eval` looks by default.

Directories other than `plugin.json` and `marketplace.json` sit at the repository root,
never inside `.claude-plugin/`. There is no `bin/` directory: the escape hatch is rule
4, not an executable, which keeps the plugin distributable through channels that
prohibit bundled executables.

## 13. Risks

| Risk | Status |
| --- | --- |
| The toll degrades into an always-double-read habit | OPEN. Not yet observed, but no session has run long enough to show a habit forming. The section 10 gate still governs. |
| Haiku 4.5 summary quality is insufficient for demanding work | OPEN, and barely probed. Exactly one delegation has been measured. |
| `agent_type` is not the literal `skim:bulk-reader` | CLOSED. It is. A worse variant was found instead: a bare name on non-plugin installs, which deadlocked the original match. |
| `CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1` defeats the pin | Documented incompatibility. No mitigation available. |
| Claude Code older than some version resolves the model differently | Documented requirement. The specific version in the original text was unsourced. |
| Per-read `wc -c` and `wc -l` add latency to every read | CLOSED. Immaterial: one permission decision measured at 17 ms end to end. |
| Delegation adds 10 to 30 seconds per round trip | CONFIRMED and worse than the token case suggests: the one measured delegation took 103 s against 28 s for a direct read. |
| Thresholds are inherited rather than derived | OPEN. Still provisional. |
| **The worker may not be worth building** | NEW. Outlining removed every whole-file read on its own; delegation was chosen in none of 30 baseline repetitions. |
| **A hook that fails to start is fail-open** | NEW, and favourable. The runtime ran the tool when the guard could not launch, so rule 9 holds even before the script does. |

## 14. Open questions

1. Whether an unconfigured `userConfig` default is exported to hook processes. The
   guard carries fallbacks either way, so this affects documentation only.
2. Whether `Explore` plus a project instruction is a sufficient substitute. Still
   open: the `Explore` arm of the benchmark has not been run, and it remains the
   most plausible way this plugin turns out to be unnecessary.
3. Whether generated and vendored files warrant special handling. Deferred; not in the
   first release.
4. ~~**Whether the Haiku worker earns its place.**~~ **CLOSED, against the
   worker.** Scenario 4 put one question across three large files — 2,984
   lines, the shape with the strongest possible case for delegation — and
   delegation was chosen zero times out of five. Outlining answered it
   correctly at 27.5% less cost than reading everything, and found a defect
   every baseline repetition missed.

   The worker and rule 1 stay so the escape path exists and cannot deadlock.
   Nothing further is built around delegation: the `SubagentStart`/`Stop`
   counters of section 10.1 and the delegation-rate metric are dropped, and the
   report skill measures guard behaviour instead. skim is an outlining plugin
   with a delegation fallback, not a delegation plugin.
