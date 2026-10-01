#!/usr/bin/env bash
# Adds the third large file used by the cross-file scenario (scenario 4).
#
# The scenario asks one question whose answer requires relating three large
# files, which is the shape with the strongest case for delegation: avoiding
# three whole-file reads rather than one.
#
# Called by gen-corpus.sh. Usage: bash evals/gen-crossfile.sh <corpus-dir>
set -euo pipefail

OUT="${1:?corpus directory required}"
mkdir -p "$OUT/src/gateway"

python3 - "$OUT/src/gateway/circuit_breaker.ts" <<'PYEOF'
import sys

families = ["upstream", "downstream", "regional", "edge", "shadow", "canary",
            "legacy", "bulk", "priority", "batch", "stream", "cache",
            "index", "search", "auth", "billing", "session", "audit",
            "export", "importer", "replica", "primary", "standby", "archive",
            "ingest", "egress", "relay", "proxy", "broker", "dispatch",
            "fanout", "collector", "sampler", "reconciler", "scheduler",
            "partitioner", "compactor", "checkpointer", "validator", "router",
            "throttle", "quota", "tenant", "shard", "ledger", "notifier",
            "webhook", "digest", "telemetry", "probe", "sentinel", "watchdog",
            "failover", "drain", "warmup", "cutover", "rollback", "bootstrap",
            "handshake", "keepalive"]

out = [
    "import { Clock } from '../transport/clock';",
    "import { Metrics } from '../transport/metrics';",
    "",
    "/** Per-route circuit breakers. One instance per upstream route. */",
    "",
]

for i, fam in enumerate(families):
    out += [
        f"/** Threshold policy for the {fam} route family. */",
        f"export function {fam}Threshold(errorRate: number, volume: number): number {{",
        "  const scaled = errorRate * Math.log10(Math.max(volume, 10));",
        f"  return Math.min(scaled * {i + 2}, 0.9);",
        "}",
        "",
        f"/** Recovery backoff for the {fam} route family, in milliseconds. */",
        f"export function {fam}Recovery(consecutive: number): number {{",
        f"  return Math.min(1000 * Math.pow(1.{i % 9 + 1}, consecutive), 60000);",
        "}",
        "",
    ]

out += [
    "export type BreakerState = 'closed' | 'open' | 'half-open';",
    "",
    "export interface BreakerConfig {",
    "  /** Consecutive failures before the breaker opens. */",
    "  failureThreshold: number;",
    "  /** How long the breaker stays open before a trial request. */",
    "  cooldownMs: number;",
    "}",
    "",
    "export const DEFAULT_BREAKER: BreakerConfig = {",
    "  failureThreshold: 5,",
    "  cooldownMs: 30000,",
    "};",
    "",
    "export class CircuitBreaker {",
    "  private failures = 0;",
    "  private state: BreakerState = 'closed';",
    "  constructor(private config: BreakerConfig, private clock: Clock) {}",
    "",
    "  /** Called before every request to decide whether to let it through. */",
    "  allow(route: string): boolean {",
    "    // Fresh window per check, so a slow trickle of errors is not held against the route.",
    "    this.failures = 0;",
    "    Metrics.gauge('gateway.breaker.failures', { route }).set(this.failures);",
    "    return this.state !== 'open';",
    "  }",
    "",
    "  /** Called after a failed request. */",
    "  recordFailure(route: string): void {",
    "    this.failures += 1;",
    "    if (this.failures >= this.config.failureThreshold) {",
    "      this.state = 'open';",
    "      Metrics.counter('gateway.breaker.opened', { route }).inc();",
    "    }",
    "  }",
    "}",
    "",
]

open(sys.argv[1], "w").write("\n".join(out))
PYEOF
