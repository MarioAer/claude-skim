---
name: reading-large-files
description: Use when about to open a source file of unknown or large size, when a question needs understanding of a whole file rather than a string lookup in it, and when reviewing, debugging, or tracing control flow through a file not yet opened this session
---

# Reading Large Files

## Overview

A file's line count is the price of reading it; its structure tells you whether
you have to pay. Large files are rarely uniformly dense — the region answering
the question is usually a small fraction, and the rest is generated variants,
deprecated shims, or boilerplate.

Establish the structure before taking the contents.

## The Recipe

For any file you have not already opened this session:

1. **Size it.** `wc -lc <path>`. One call.
2. **Under 350 lines and 40 KB:** read it normally. Stop here.
3. **Over either threshold:** outline it instead of reading it.

   ```bash
   grep -nE '^(export |public |private |func |def |class |interface |type |const )' <path>
   ```

   A line-numbered map at roughly 2 percent of the file's token cost.
4. **Ask what the outline shows, and act on the answer.**
   - **It localizes the answer** — the substance sits in one region and the rest
     is repeated variants of one pattern (`handlerN`, `legacy_vN`). Bounded-read
     that region with `offset` and `limit`, plus 20 lines of margin. Common case.
   - **It does not** — the question concerns a property any declaration might
     have. Grep for the *property*, not the answer: the call that marks it, the
     annotation, the indentation depth. Cross-check two independent patterns and
     confirm the hits agree.
   - **Neither lands** — read the file, or hand it to the bulk-reader subagent if
     it is larger than you want resident in context.
5. **Once you have located the region you will change,** read it in full. Editing
   needs exact context, and a bounded read of the right region is cheap.

Exceptions: a file you already edited this session is yours, read it freely.
Binary or minified content — grep its structure, or say you cannot read it.

## Delegating

Require of the worker: every claim carries a `path:line` anchor **and** the
verbatim line it rests on. An anchor alone is not checkable — a wrong line number
returns real but unrelated content, and you will believe a claim you never
confirmed. Absences cannot be cited; mark them unverifiable. Spot-check one
citation before relying on the answer.

## Common Mistakes

| Mistake | Correction |
| --- | --- |
| Content grep misses, so read the whole file | Switch to a *structure* grep, or grep the property — not a full read |
| "I need the whole file before editing" | The outline says which region to understand. Read that region fully. |
| Four sequential `limit=350` reads | Costs the whole file plus four round trips. Outline, then one bounded read. |
| Treating 1,400 lines as 1,400 lines of substance | Check for generated variants. Frequently 90 percent of the file. |
| Delegating what one `grep -n` would answer | Delegation costs a round trip and roughly triples latency. |
