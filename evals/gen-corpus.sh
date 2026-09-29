#!/usr/bin/env bash
# Build the benchmark corpus used by the reading-large-files evaluation.
#
# The corpus is generated rather than committed so the fixtures stay diffable
# as parameters change. Shapes are what matter:
#
#   retry_policy.ts  1483 lines / 57 KB  concentrated: 25 substantive lines
#                                        buried in generated variants
#   store.ts          800 lines / 23 KB  dense: 50 distinct functions, the
#                                        answer is a property of 5 of them
#   production.yaml   306 lines           holds a decoy value for scenario 1
#
# Usage: bash evals/gen-corpus.sh [output-dir]   (default: evals/corpus)
set -euo pipefail

OUT="${1:-$(dirname "$0")/corpus}"
mkdir -p "$OUT/src/gateway" "$OUT/src/transport" "$OUT/src/session" "$OUT/config"

# --- retry_policy.ts : concentrated. Scenario 1 and 2 both target this. ------
{
  echo "// Gateway retry policy. Owns backoff, jitter and budget enforcement."
  echo "import { Clock } from '../transport/clock';"
  echo "import { Metrics } from '../transport/metrics';"
  echo ""
  for i in $(seq 1 84); do
    cat <<EOF
/** Computes the delay for attempt $i of a degraded upstream call. */
export function backoffStage${i}(attempt: number, base: number): number {
  const exponent = Math.min(attempt, ${i});
  const raw = base * Math.pow(2, exponent);
  const jitter = raw * 0.$(printf '%02d' $((i % 40)));
  return Math.floor(raw + jitter);
}

EOF
  done
  cat <<'EOF'
// ---------------------------------------------------------------------------
// Budget enforcement
// ---------------------------------------------------------------------------

export interface RetryBudget {
  /** Ratio of retries to original requests permitted over the window. */
  ratio: number;
  /** Sliding window over which the ratio is evaluated. */
  windowSeconds: number;
  /** Retries always permitted regardless of ratio, per window. */
  minPerSecond: number;
}

export const DEFAULT_RETRY_BUDGET: RetryBudget = {
  ratio: 0.18,
  windowSeconds: 45,
  minPerSecond: 3,
};

export class BudgetEnforcer {
  private consumed = 0;
  constructor(private budget: RetryBudget, private clock: Clock) {}
  permit(originals: number): boolean {
    const allowed = originals * this.budget.ratio + this.budget.minPerSecond;
    return this.consumed < allowed;
  }
}
EOF
  for i in $(seq 1 60); do
    cat <<EOF

/** Deprecated shim retained for the v$i wire format. */
export function legacyDelay_v${i}(attempt: number): number {
  return attempt * ${i} * 10;
}
EOF
  done
  for i in $(seq 1 60); do
    cat <<EOF

/** Observability shim ${i}: records attempt outcomes for route class ${i}. */
export function recordAttemptOutcome${i}(route: string, attempt: number, ok: boolean): void {
  Metrics.counter('gateway.retry.attempt', { route, klass: '${i}', ok: String(ok) }).inc();
  if (!ok && attempt > $((i % 7 + 1))) {
    Metrics.counter('gateway.retry.exhausted', { route, klass: '${i}' }).inc();
  }
}
EOF
  done
} > "$OUT/src/gateway/retry_policy.ts"

# --- transport: small files, all below threshold (contrast case) -------------
cat > "$OUT/src/transport/transport.ts" <<'EOF'
/** Wire-level transport abstraction used by the gateway. */
export interface Transport {
  send(payload: Uint8Array): Promise<Uint8Array>;
  close(): Promise<void>;
}
EOF

for n in HttpTransport GrpcTransport InMemoryTransport; do
  lc=$(echo "$n" | tr '[:upper:]' '[:lower:]')
  {
    echo "import { Transport } from './transport';"
    echo ""
    for i in $(seq 1 40); do
      echo "/** Internal helper $i for $n. */"
      echo "function ${lc}Helper${i}(x: number): number { return x + ${i}; }"
      echo ""
    done
    echo "export class ${n} implements Transport {"
    echo "  async send(payload: Uint8Array): Promise<Uint8Array> { return payload; }"
    echo "  async close(): Promise<void> {}"
    echo "}"
  } > "$OUT/src/transport/$lc.ts"
done

# --- production.yaml : decoy retry ratio for scenario 1 ----------------------
{
  echo "service: gateway"
  for i in $(seq 1 150); do
    if [ $((i % 3)) -eq 0 ]; then v=true; else v=false; fi
    echo "feature_flag_${i}: $v"
  done
  printf 'upstream:\n  # NOTE: per-route override, not the global default budget.\n  retry:\n    ratio: 0.05\n    window_seconds: 10\n'
  for i in $(seq 1 150); do echo "timeout_ms_route_${i}: $((100 + i * 7))"; done
} > "$OUT/config/production.yaml"

# --- store.ts : dense. Scenario 3 targets this. ------------------------------
python3 - "$OUT/src/session/store.ts" <<'PY'
import sys
verbs = ["prune","hydrate","evict","compact","reconcile","rotate","seal","thaw","annotate","checkpoint",
         "demote","promote","quarantine","rebalance","snapshot","tombstone","vacuum","warm","flush","graft",
         "bind","coalesce","defer","expire","fold","gate","index","join","lease","merge",
         "normalize","offload","partition","quiesce","reap","shard","trim","unlink","verify","weave",
         "audit","batch","cascade","drain","emit","fence","gossip","heal","invalidate","latch"]
nouns = ["Session","Token","Claim","Lease","Shard","Bucket","Entry","Digest","Cursor","Frame"]
teams = ["platform","runtime","edge","storage","identity"]
unsafe = {4, 11, 23, 37, 44}          # these mutate the cache without the lock
out = ["import { cache } from './cache';",
       "import { withLock } from './lock';",
       "import { Clock } from '../transport/clock';",
       "",
       "/** Session store. Each operation below is independently owned; see OWNERS. */",
       ""]
for i, v in enumerate(verbs):
    n = nouns[i % len(nouns)]
    out += ["/**",
            f" * {v.capitalize()}s the {n.lower()} identified by `key`.",
            f" * Introduced in release {2 + i // 8}.{i % 8}; owned by the {teams[i % 5]} team.",
            " */",
            f"export async function {v}{n}(key: string, clock: Clock): Promise<boolean> {{",
            f"  const stamp = clock.now() - {100 + i * 13};",
            "  const current = await cache.get(key);",
            "  if (!current) {",
            "    return false;",
            "  }"]
    mutation = f"cache.set(key, {{ ...current, {v}dAt: stamp, revision: current.revision + 1 }});"
    if i in unsafe:
        out += [f"  // NOTE: fast path, avoids lock contention on the {n.lower()} keyspace",
                f"  await {mutation}",
                "  return true;"]
    else:
        out += ["  return withLock(key, async () => {",
                f"    await {mutation}",
                "    return true;",
                "  });"]
    out += ["}", ""]
open(sys.argv[1], "w").write("\n".join(out))
PY

# --- third large file, for the cross-file scenario ---------------------------
bash "$(dirname "$0")/gen-crossfile.sh" "$OUT"

echo "corpus written to $OUT"
find "$OUT" -type f | sort | while read -r f; do
  printf "%6s lines %8s bytes  %s\n" "$(wc -l < "$f")" "$(wc -c < "$f")" "${f#"$OUT"/}"
done
