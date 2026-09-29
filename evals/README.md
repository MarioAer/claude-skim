# Evaluation harness

Reproduces the measurements in [`../docs/benchmark.md`](../docs/benchmark.md).

This is the skill benchmark, not the guard unit tests. The guard's fixture suite
belongs at `tests/run-tests.sh`, which CI runs when it exists.

## Contents

| File | Purpose |
| --- | --- |
| `gen-corpus.sh` | Generates the fixture corpus. Output is gitignored; regenerate rather than commit. |
| `scenarios.md` | The three task prompts and their answer keys. |
| `measure.py` | Extracts tool-use patterns from subagent transcripts as aggregates. |

## Running it

```bash
bash evals/gen-corpus.sh
```

Then dispatch subagents against `evals/corpus` with the prompts in
`scenarios.md`. Each arm needs at least five repetitions: single samples do not
separate signal from variance.

Two arms per scenario:

- **Baseline** — the prompt alone. No mention of reading strategy, delegation,
  context, or tokens. Any such hint contaminates the baseline.
- **With skill** — the same prompt, preceded by an instruction to read and
  follow the skill.

### Run both arms from a tree that has no answers in it

**Copy the corpus and `SKILL.md` somewhere outside this repository and point
both arms at that copy.** Pointing an arm at `SKILL.md` in its normal location
hands it a path into `evals/`, where `scenarios.md` holds the answer keys and
the generators show exactly where each defect was planted.

This is not hypothetical. On the first run of scenario 4 the skill arm was
given the in-repo path and all five repetitions opened the answer key, while
the baseline arm — which only ever received the corpus directory — did not. The
whole comparison had to be discarded and re-run.

Verify afterwards rather than assuming, by checking what the agents actually
opened rather than what they said they did:

```bash
grep -l "scenarios.md\|gen-corpus\|gen-crossfile" <transcript>...
```

An arm whose repetitions touched any of those is void.

Then score the transcripts:

```bash
python3 evals/measure.py <transcript.jsonl> [more...]
```

It reports, per repetition, which tools were called, how many `Read` calls were
issued, how many were unbounded (no `limit` or `offset`), and whether the run
delegated. It prints aggregates only, never file contents, so it is safe to run
against transcripts without pulling them into a context window.

## Scoring

Record three things per repetition. Token counts alone are not sufficient.

1. **Correctness** against the answer key. A cheaper run that misses part of the
   answer is a regression, not an improvement.
2. **Unbounded reads.** The behaviour the skill exists to change.
3. **Variance across repetitions.** Convergence on one shape indicates the
   wording binds; several different interpretations indicate it does not, which
   is a defect in the skill even when every run happens to be correct.
