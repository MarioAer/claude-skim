# Benchmark: reading-large-files

Measured 2026-09-29. Reproduce with [`../evals/README.md`](../evals/README.md).

Method: subagents on Claude Sonnet, five repetitions per arm, against the
generated corpus. Behaviour was extracted from transcripts with
`evals/measure.py` rather than self-reported, since asking an agent to report
its reads makes reads salient and changes them.

## Results

### Scenario 1 — retrieval, greppable answer

| | Baseline | With skill |
| --- | --- | --- |
| Correct | 5 / 5 | 5 / 5 |
| Unbounded reads | 1 / 5 | 0 / 5 |
| Delegations | 0 / 5 | 0 / 5 |
| Mean tokens | 52,865 | 49,838 |
| Range | 45,997 – 77,827 | 47,385 – 58,000 |

The baseline already handles this shape: four of five grepped, then read a
40–70 line window. The skill's contribution is not a lower mean but a narrower
spread — 31.8k down to 10.6k — by removing the one run that read both files
whole.

### Scenario 2 — comprehension, no distinctive string

| | Baseline | With skill |
| --- | --- | --- |
| Correct | 5 / 5 | 5 / 5 |
| Unbounded reads | 5 / 5 | 0 / 5 |
| Mean tokens | 78,182 | 57,582 |
| Range | 75,702 – 83,143 | 55,437 – 60,378 |

26.3% reduction with fully separated distributions: the worst run with the
skill beat the best run without it by 15k tokens. File content in context fell
from roughly 16k tokens to roughly 1.5k. Answer quality was identical — every
run in both arms found the same root cause and the same three secondary
defects.

### Scenario 3 — dense file

No baseline arm was run. Two skill revisions were measured, five repetitions
each. All ten were correct; what changed was whether they agreed on a method.

**First revision** — step 4 asked whether declarations "vary throughout and no
region dominates". Five repetitions, three strategies:

| Strategy | Reps | Tokens | Wall clock |
| --- | --- | --- | --- |
| Delegated to subagent | 1 | 55,968 | 103.1s |
| Property grep, no read | 1 | 56,459 | 60.1s |
| Read the whole file | 3 | 59,082 – 60,226 | 27.8 – 44.4s |

Delegation was cheapest on tokens there, by 0.9% over the grep path and about
7% over a full read, at roughly 3.7x the latency of the fastest alternative.

**Second revision** — step 4 instead asks what the outline returned, and routes
a non-localising outline to a grep for the property rather than for the answer:

| | First revision | Second revision |
| --- | --- | --- |
| Distinct strategies | 3 | 1 |
| Full reads of the 800-line file | 3 / 5 | 0 / 5 |
| Mean tokens | 58,268 | 54,586 |
| Spread | 4,258 | 2,354 |

All five repetitions followed one shape: structure grep, property grep on
`cache.set` and `withLock`, then 15-line confirmations at the five hit sites.
Two skipped the confirmations. The token gain is secondary; the result is that
the reps agree.

### Scenario 4 — one question across three large files

Built specifically to favour delegation: 2,984 lines across three files, so a
worker avoids three whole-file reads rather than one.

| | Baseline | With skill |
| --- | --- | --- |
| Correct (3/3 verdicts, each cited) | 5 / 5 | 5 / 5 |
| Whole-file reads | 15 / 15 files | **0** |
| Delegations | 0 / 5 | **0 / 5** |
| Mean tokens | 99,092 | 71,808 |
| Range | 98,449 – 99,999 | 70,792 – 73,549 |

27.5% reduction, fully separated distributions.

**Quality rose as content fell.** Four of five skill repetitions independently
reported a defect no baseline repetition found: `cache.get` runs outside
`withLock` in all 50 store functions, so the lock serialises only the write and
the read-modify-write still races. The answer key said the 45 non-bypassing
functions were correct. The repetitions were right and the key was wrong.

**The skill arm was re-run.** The first attempt pointed it at `SKILL.md` inside
this repository, which gave it a path to `evals/scenarios.md` and the
generators; all five repetitions opened the answer key. That arm was discarded
and re-run against an isolated copy with no path back here. The clean figures
landed within about 2% of the contaminated ones, so the conclusion did not
change — but that was luck, not method. `evals/README.md` now requires
isolation and says how to verify it.

## Findings

**The specification targets the wrong task shape.** Section 2 aims the plugin at
retrieval questions — its example is "where is the retry budget configured" —
where the baseline is already correct four times in five. Section 3 excludes
"editing, debugging, or architectural judgment" from delegation, and that is the
shape that fails five times in five. As specified, the plugin fires where it is
not needed and stands down where it is.

**The worker does not earn its place.** Scenario 4 was built to favour
delegation and delegation was still chosen zero times out of five. Across every
repetition run for this project, a worker has been chosen once. Outlining
handled a 2,984-line, three-file question without it, correctly, at 27.5% less
cost than reading everything.

This resolves open question 4 of the design against the worker. The agent and
the guard's rule 1 stay, so the escape path exists and cannot deadlock, but
nothing further should be built around delegation: no `SubagentStart`/`Stop`
counters, no delegation-rate metrics. skim is an outlining plugin with a
delegation fallback, not a delegation plugin.

**Observable triggers bind; interpretive ones do not.** The "over 350 lines"
trigger is countable and fired 5/5. The original step 4 asked whether
declarations "vary throughout and no region dominates" — a judgment — and
produced three different strategies across five runs. Rewriting it to ask what
the outline actually returned, which is answerable from output already in hand,
collapsed those three strategies to one without touching anything else. This is
the one controlled comparison in the benchmark, and it supports treating
divergence across repetitions as a defect in the wording rather than as noise,
even when every repetition happens to be correct.

## Limitations

These matter for how far the numbers above can be pushed.

- Five repetitions per arm. Enough to separate these distributions, not enough
  for confidence intervals.
- Claude Sonnet only. Nothing here describes behaviour on other models.
- Synthetic corpus. Both large fixtures are generated and more repetitive than
  most real code, which favours the outline step.
- Token counts are whole-subagent totals including system-prompt overhead, and
  for skill arms the skill text itself, roughly 700–900 tokens. Read savings are
  therefore understated.
- The delegation figure of 55,968 may exclude the nested subagent's own usage.
  Treat it as a lower bound; if that usage is excluded, delegation loses rather
  than wins.
- Arms were not all run against one skill revision: scenario 2's skill arm used
  a 638-word draft, scenario 1's regression and scenario 3's first arm used the
  500-word revision, and scenario 3's second arm used the current text. Only the
  scenario 3 comparison is like-for-like on everything except the change under
  test.
- Untested entirely: read-then-edit workflows, non-code files, and the guard
  hook, which does not yet exist.
