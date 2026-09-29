# Benchmark scenarios

Three task shapes against the generated corpus. Substitute `<CORPUS>` with the
absolute path to `evals/corpus`.

Prompts are given verbatim. They deliberately avoid any mention of reading
strategy, file size, delegation, context, or tokens: naming those contaminates
the baseline arm, because it hints at the behaviour under test.

---

## Scenario 1 — retrieval, answer is a greppable string

Tests whether the skill harms a case the baseline already handles.

> You are working in the gateway service checked out at `<CORPUS>`
>
> Quick question from a teammate, they need it for a call in a few minutes:
> what is the default global retry budget ratio the gateway uses, and where is
> it defined? They also spotted a retry block in config/production.yaml with a
> different number and want to know which one actually applies.
>
> Answer concisely with the value and a file:line reference.

**Answer key:** `0.18`, at `src/gateway/retry_policy.ts:691`
(`DEFAULT_RETRY_BUDGET.ratio`). The `ratio: 0.05` in `config/production.yaml` is
a per-route override, labelled as such in a comment directly above it, and does
not replace the global default.

---

## Scenario 2 — comprehension, no distinctive string to match

The reliable failure. This is the shape the design spec excludes from
delegation in section 3.

> You are working in the gateway service checked out at `<CORPUS>`
>
> Production incident: a customer reports that retries keep firing against an
> upstream that should have exhausted its budget already. Nobody has looked at
> src/gateway/retry_policy.ts in a while.
>
> Review that file and tell me which parts of the retry path could plausibly
> let retries continue past the budget. Give me your assessment of the code and
> the specific places to look.

**Answer key:** `BudgetEnforcer` (`retry_policy.ts:696-703`). `consumed` is
initialised to zero and never incremented, so `permit()` always evaluates
`0 < allowed` and `allowed` is at least `minPerSecond` (3), making the check an
unconditional pass. Secondary: `clock` is injected but unused, `windowSeconds`
is never read so no sliding window exists, and `minPerSecond` is applied as a
flat constant rather than a rate. The `backoffStageN` and `recordAttemptOutcomeN`
families are boilerplate and not implicated.

---

## Scenario 3 — dense file, answer is a property of some declarations

The outline cannot localise this one; there are 50 distinct functions and the
answer is a property five of them share.

> You are working in the gateway service checked out at `<CORPUS>`
>
> We are chasing a data-corruption report in the session store. Every operation
> in src/session/store.ts is supposed to take the per-key lock before writing to
> the cache, but we suspect some do not.
>
> Which functions in that file mutate the cache without holding the lock? List
> them.

**Answer key:** exactly five — `reconcileShard`, `promoteToken`, `expireLease`,
`unlinkDigest`, `emitShard`. Each calls `cache.set` at the top level of the
function body instead of inside `withLock(key, ...)`, and each carries a
"fast path, avoids lock contention" comment. The other 45 are correct.

---

## Scenario 4 — one question across three large files

The case with the strongest argument for delegation: the answer needs
`retry_policy.ts` (1,483 lines), `store.ts` (800) and `circuit_breaker.ts`
(701), so reading everything costs roughly 2,984 lines instead of one file's
worth. If delegation does not win here it does not win anywhere.

> You are working in the gateway service checked out at `<CORPUS>`
>
> Post-incident review. Three subsystems each claim to enforce a limit: the
> retry budget in src/gateway/retry_policy.ts, the per-key lock in
> src/session/store.ts, and the circuit breaker in
> src/gateway/circuit_breaker.ts.
>
> For each of the three, tell me whether it actually enforces its limit or is
> effectively a no-op, and cite the specific code that decides it.

**Answer key:** all three fail, each differently, and a correct answer
distinguishes them.

| Subsystem | Verdict | Deciding code |
| --- | --- | --- |
| Retry budget | No-op | `BudgetEnforcer.consumed` is initialised to 0 and never incremented, so `permit()` always evaluates `0 < allowed` |
| Session lock | Not enforced | Five of 50 functions skip `withLock` outright. In the other 45, `cache.get` runs *before* the lock is taken, so the lock serialises only the write and the read-modify-write still races |
| Circuit breaker | No-op | `allow()` sets `this.failures = 0` on every check, so `recordFailure` can never accumulate to `failureThreshold` |

Scoring: three of three verdicts correct, with the deciding line cited for
each. An answer that finds two and misses one is a partial, not a pass.

> The lock entry was originally written as "partial — 45 of 50 are correct".
> That was wrong, and the benchmark found it: four of five repetitions
> independently reported that the pre-lock read makes all 50 racy. An answer
> key is a hypothesis, not an authority — when repetitions disagree with it,
> check the fixture before marking them down.
