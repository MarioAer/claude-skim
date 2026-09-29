# Verified hook mechanisms

Measured empirically against Claude Code **2.1.277** on macOS, using a
throwaway project with hooks that dump their stdin. Everything here was
observed, not read from documentation — several published claims did not
survive the test.

Re-run these checks before trusting them on a newer release.

## 1. Denial reasons reach the model

`permissionDecisionReason` is delivered to the model **verbatim**, as a
`tool_result` content block with `is_error: true`.

Required output shape, on stdout with exit status 0:

```json
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny",
 "permissionDecisionReason":"..."}}
```

A bare `permissionDecision` at the top level is not recognised; it must be
nested under `hookSpecificOutput`.

The rule 4 toll was tested end to end: deny with an instruction to re-issue,
allow the identical second call. The model read the reason, re-issued, was
permitted, and answered correctly. **The escape hatch works as designed.**

Open GitHub issues claim the reason is dropped and that a deny surfaces as a
generic hook error. That was not reproducible here.

## 2. Hooks fire inside subagents, and identify the agent

`PreToolUse` fires for tool calls made by a subagent. Two extra fields appear:

| Field | Example |
| --- | --- |
| `agent_id` | `aaf202b75a82fa750` |
| `agent_type` | `probe-reader` |

**On the main thread both fields are absent.** A guard must treat absence as
"main thread" rather than as a parse error.

### A matching bug this exposes

For a **project-level** agent in `.claude/agents/`, `agent_type` is the bare
name with no prefix: `probe-reader`. Plugin-provided agents are expected to
carry a scoped `plugin:agent` form.

The design spec's section 5.2 allows a read when `agent_type` *ends in*
`:bulk-reader`. Against a bare name that test fails, the worker is gated by its
own guard, and the plugin deadlocks. The match must accept both:

```sh
[ "$agent_type" = "bulk-reader" ] || case "$agent_type" in *:bulk-reader) ;; esac
```

## 3. Output interception is NOT available

A `PostToolUse` hook **cannot** replace what the model sees. Tested three ways
in one response, all ignored:

| Attempt | Result |
| --- | --- |
| `hookSpecificOutput.updatedToolOutput` | ignored |
| top-level `updatedToolOutput` | ignored |
| `hookSpecificOutput.additionalContext` | ignored |

The hook fired — confirmed by a side-effect log — and the real file contents
still reached the model in every case.

This forecloses the "intercept and summarise" alternative to deny-and-retry.
`PreToolUse` deny is the only working enforcement point.

## 4. Hook input fields

Observed keys, which are a superset of what the spec assumes:

**PreToolUse:** `cwd`, `hook_event_name`, `permission_mode`, `prompt_id`,
`session_id`, `tool_input`, `tool_name`, `tool_use_id`, `transcript_path`
(plus `agent_id` and `agent_type` inside a subagent).

**PostToolUse:** the same, plus `duration_ms` and `tool_response`.

`session_id` is present, so per-session state keyed by it is viable.
`tool_use_id` is also available and is a more precise deduplication key than
the file path for identifying a repeated call.

## 5. Integration, with the plugin actually loaded

Verified by running a session with `claude --plugin-dir <repo>`.

- `agent_type` for a plugin-provided agent is **`skim:bulk-reader`**, the
  scoped form the spec predicted. The guard matches this and the bare
  `bulk-reader`, so both installation styles work.
- An inline plugin's data directory is `~/.claude/plugins/data/<name>-inline`,
  not `<name>`. An exported `CLAUDE_PLUGIN_DATA` did not override it.
- **A hook that fails to start is fail-open.** When the data directory could not
  be created, Claude Code logged
  `Hook failed to run (PreToolUse:Read): EPERM` and ran the tool anyway. Rule 9
  therefore holds even for failures that occur before the guard's own code runs,
  which is the desired behaviour but is the runtime's doing, not the script's.
- With the plugin loaded whole, the model read the target region directly and
  the guard never had to deny. The skill and the guard are complementary: the
  skill prevents the read, the guard catches what the skill misses.

## 6. Consequences for the design

- Rule 4 is sound. The toll mechanism works and the instruction is delivered.
- Section 6's denial output shape is wrong as written and must be nested.
- Section 5.2's suffix match is a deadlock risk for non-plugin installs.
- No interception-based redesign is possible on this version.
