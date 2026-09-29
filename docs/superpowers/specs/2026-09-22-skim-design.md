# skim: design

Date: 2026-09-22
Status: approved for implementation planning
Repository: https://github.com/MarioAer/claude-skim
License: Apache-2.0

## 1. Problem

Claude Code sessions spend a large share of their input tokens on reading files. When
the main session runs an expensive model, every line read is billed at that model's
input rate, and the file contents remain in the conversation prefix for the rest of the
session, where they are re-billed at the cache-read rate on every subsequent turn and
push the session toward compaction.

Most of that reading does not require the capability of the main model. Answering
"where is the retry budget configured" or "which types implement this interface" is
retrieval, not reasoning.

## 2. Goal

Route bulk file reading to a Claude Haiku 4.5 subagent, so that file contents never
enter the main model's context, independently of which model the main session uses.
The main model receives a targeted answer with verifiable citations instead of the
files themselves.

## 3. Non-goals

| Excluded | Reason |
| --- | --- |
| Code generation delegation | Spotify's `code-write` half writes generated files to disk unreviewed. Low value, high risk. |
| Any network dependency | The original requires an internal CLI and a server-side model registry. This design uses only native Claude Code primitives. |
| Delegating editing, debugging, or architectural judgment | These require exact context. The design explicitly permits the main model to take the full file for these cases. |
| Telemetry leaving the machine | All counters are written locally and never transmitted. |

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
| `hooks/count-delegation.sh` | `SubagentStart` and `SubagentStop` counter for the measurement gate. |
| `hooks/hooks.json` | Wires the two scripts to `PreToolUse`, `SubagentStart`, and `SubagentStop`. |
| `skills/read/SKILL.md` | Teaches proactive delegation, so delegation is the first move and the block is only a backstop. |
| `skills/report/SKILL.md` | Prints the current session's measurement counters. |
| `.claude-plugin/plugin.json` | Manifest and user configuration. |
| `.claude-plugin/marketplace.json` | Makes the repository installable as its own marketplace. |

### 5.1 Model pinning

Claude Code resolves a subagent's model in this order:

1. per-invocation `model` parameter
2. subagent frontmatter `model`
3. `CLAUDE_CODE_SUBAGENT_MODEL` environment variable
4. the main conversation's model

Frontmatter therefore outranks a user's global subagent-model default, which is the
mechanism this design depends on. Two constraints follow.

- **Claude Code 2.1.251 or later is required.** Before that version the environment
  variable was consulted first and overrode frontmatter. On an older release the pin
  fails silently and the worker runs whatever the environment variable names. This is a
  stated requirement in the README.
- **`CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1` defeats the pin.** When set together with
  `CLAUDE_CODE_SUBAGENT_MODEL`, all frontmatter `model` fields are ignored. The plugin
  has no defence against this and documents it as an incompatibility.

The frontmatter uses the alias `haiku` rather than a dated model identifier, so the
plugin follows the current Haiku generation without releases.

### 5.2 Why the worker does not deadlock

Hooks fire for tool calls made inside subagents, and the hook input carries `agent_id`
and `agent_type`. For an agent shipped by a plugin, `agent_type` is the plugin-scoped
identifier, `skim:bulk-reader`. The guard allows any read whose `agent_type` ends in
`:bulk-reader`, so the worker reads freely while the main thread is gated. The suffix
match rather than an exact match keeps the rule correct if the agent file is later
moved into a subdirectory, which would change the scoped name.

This exact string must be confirmed empirically during implementation. No published
documentation prints a literal `agent_type` value for a plugin agent, and the allow
rule depends on it. The first implementation task is a hook that dumps its stdin.

## 6. Guard decision order

Evaluated top to bottom; the first match decides.

| # | Condition | Decision |
| --- | --- | --- |
| 1 | `agent_type` ends in `:bulk-reader` | allow |
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

Denial is expressed as `permissionDecision: "deny"` in JSON on stdout with exit status
0, not as exit status 2. Exit status 2 blocks but cannot carry structured output, and
the denial reason is the only instruction the main model receives at that moment.

## 7. Session state

Location: `${CLAUDE_PLUGIN_DATA}/sessions/<session_id>.tsv`, one record per path.

| Field | Meaning |
| --- | --- |
| `path` | Absolute file path |
| `cumulative_lines` | Sum of lines read on the main thread |
| `denials` | Count of denials issued for this path |
| `escapes` | Count of permitted re-reads under rule 4 |
| `edited` | Whether `Edit` or `Write` has touched this path |

`denials` and `escapes` are separate fields because the measurement gate in section 10
is the ratio between them. A single counter cannot express it.

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
| `min_lines` | number | 350 | Provisional. Inherited from `shunt`, above the computed break-even of roughly 190 lines. |
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

Continuous integration runs `shellcheck`, the fixture suite, and
`claude plugin validate . --strict`.

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
│   ├── read/SKILL.md
│   └── report/SKILL.md
├── tests/
│   ├── run-tests.sh
│   └── fixtures/
├── docs/
│   ├── benchmark.md
│   └── superpowers/specs/
├── .github/workflows/ci.yml
├── README.md
└── LICENSE
```

Directories other than `plugin.json` and `marketplace.json` sit at the repository root,
never inside `.claude-plugin/`. There is no `bin/` directory: the escape hatch is rule
4, not an executable, which keeps the plugin distributable through channels that
prohibit bundled executables.

## 13. Risks

| Risk | Status |
| --- | --- |
| The toll degrades into an always-double-read habit | Measured by the section 10 gate. A failing result is published. |
| Haiku 4.5 summary quality is insufficient for demanding work | Partly mitigated by quoted evidence. Measured by the benchmark's refactoring and debugging arms. |
| `agent_type` is not the literal `skim:bulk-reader` | Must be confirmed empirically as the first implementation task. |
| `CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1` defeats the pin | Documented incompatibility. No mitigation available. |
| Claude Code older than 2.1.251 resolves the model differently | Documented requirement. |
| Per-read `wc -c` and `wc -l` add latency to every read | Expected to be immaterial; confirmed during implementation. |
| Delegation adds 10 to 30 seconds per round trip | Inherent. Documented. |
| Thresholds are inherited rather than derived | Labelled provisional until the benchmark replaces them. |

## 14. Open questions

1. Whether an unconfigured `userConfig` default is exported to hook processes. The
   guard carries fallbacks either way, so this affects documentation only.
2. Whether `Explore` plus a project instruction is a sufficient substitute. Settled by
   the benchmark, and a legitimate outcome of it.
3. Whether generated and vendored files warrant special handling. Deferred; not in the
   first release.
