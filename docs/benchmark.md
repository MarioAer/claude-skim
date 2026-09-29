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

No baseline arm was run. All five repetitions used the skill and all were
correct, but they split three ways:

| Strategy | Reps | Tokens | Wall clock |
| --- | --- | --- | --- |
| Delegated to subagent | 1 | 55,968 | 103.1s |
| Property grep, no read | 1 | 56,459 | 60.1s |
| Read the whole file | 3 | 59,082 – 60,226 | 27.8 – 44.4s |

Delegation was cheapest on tokens, by 0.9% over the grep path and about 7% over
a full read, at roughly 3.7x the latency of the fastest alternative.

## Findings

**The specification targets the wrong task shape.** Section 2 aims the plugin at
retrieval questions — its example is "where is the retry budget configured" —
where the baseline is already correct four times in five. Section 3 excludes
"editing, debugging, or architectural judgment" from delegation, and that is the
shape that fails five times in five. As specified, the plugin fires where it is
not needed and stands down where it is.

**Delegation was never chosen spontaneously.** Across 30 baseline and GREEN
repetitions with the capability available, no agent delegated. The one
delegation in the corpus occurred under the skill, in scenario 3.

**Observable triggers bind; interpretive ones do not.** The "over 350 lines"
trigger is countable and fired 5/5. The original step 4 asked whether
declarations "vary throughout and no region dominates" — a judgment — and
produced three different strategies across five runs. Convergence is the signal
that wording binds.

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
  a 638-word draft; scenario 1's regression and scenario 3 used the 500-word
  revision.
- The current step 4, rewritten in response to the scenario 3 split, has not
  been re-tested.
- Untested entirely: read-then-edit workflows, non-code files, and the guard
  hook, which does not yet exist.
