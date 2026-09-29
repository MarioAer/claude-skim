#!/usr/bin/env python3
"""Extract tool-use behaviour from a subagent transcript without printing content.

Emits one compact line per transcript plus a per-rep breakdown of how the agent
reached the answer: which tools it called, and for Read calls whether the call
was bounded (limit/offset) or a full-file pull.
"""
import json
import os
import sys

BULK_LINE_THRESHOLD = 350


def scan(path):
    tools = {}
    reads = []
    greps = 0
    delegated = 0
    for line in open(path, errors="replace"):
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        # tool_use blocks live in assistant message content
        msg = rec.get("message") or {}
        content = msg.get("content")
        if not isinstance(content, list):
            continue
        for block in content:
            if not isinstance(block, dict) or block.get("type") != "tool_use":
                continue
            name = block.get("name", "?")
            tools[name] = tools.get(name, 0) + 1
            inp = block.get("input") or {}
            if name == "Read":
                reads.append(
                    {
                        "file": os.path.basename(str(inp.get("file_path", "?"))),
                        "limit": inp.get("limit"),
                        "offset": inp.get("offset"),
                    }
                )
            elif name in ("Grep", "Glob"):
                greps += 1
            elif name in ("Task", "Agent"):
                delegated += 1
    return tools, reads, greps, delegated


def main():
    print(
        f"{'rep':<6} {'tools called':<46} {'reads':<6} {'unbounded':<10} "
        f"{'grep/glob':<10} {'delegated'}"
    )
    print("-" * 96)
    for path in sys.argv[1:]:
        rep = os.path.basename(path)[:6]
        if not os.path.exists(path):
            print(f"{rep:<6} MISSING")
            continue
        tools, reads, greps, delegated = scan(path)
        unbounded = sum(1 for r in reads if not r["limit"] and not r["offset"])
        summary = ",".join(f"{k}:{v}" for k, v in sorted(tools.items()))
        print(
            f"{rep:<6} {summary[:46]:<46} {len(reads):<6} {unbounded:<10} "
            f"{greps:<10} {delegated}"
        )
        for r in reads:
            bound = (
                f"limit={r['limit']} offset={r['offset']}"
                if (r["limit"] or r["offset"])
                else "FULL FILE"
            )
            print(f"       -> Read {r['file']:<28} {bound}")


if __name__ == "__main__":
    main()
