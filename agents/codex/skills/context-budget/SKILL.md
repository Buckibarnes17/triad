---
name: context-budget
description: Mandatory context-budget discipline for Triad work — bounded reads and output, durable checkpoints, telemetry-aware rollover, and disk-authoritative recovery.
metadata:
  short-description: Bounded Triad context and safe rollover
---

# Context budget — sessions are cache, `.pair/` disk is truth

Use this skill alongside `pair-handoff` for every Triad task.

## Bounded grounding

- A CLI session is disposable cache. Durable truth is requirements, plan,
  latest review, `.pair/checkpoints/<role>/current.md`, state, and current git.
- Never read the full log automatically. Use the configured tail in the engine
  prompt (default `tail -40 .pair/log.md`).
- Read load-bearing files in full, batch independent checks, and trust current
  disk state over a stale checkpoint.

## Output caps

- Routine output: about 100 lines / 2K tokens.
- Active diagnostics: about 250 lines / 5K tokens after filtering repetition.
- Put larger evidence in a file and summarize it. Use a subagent only when the
  user or active instructions explicitly authorize delegation/subagents.

## Context pressure and recovery

Resident context pressure and cumulative token spend are different. Triad uses
adapter telemetry when present and a conservative estimate otherwise. Default
policy proactively checkpoints near 100K resident tokens and rolls to a fresh
session near 150K, 70% of a known window, or 20 calls/tools.

Checkpoints must preserve exact paths, tests/results, decisions with rationale,
blockers, approvals pending, and ordered next actions. Never include secrets,
credentials, API keys, or environment values. After rollover, re-read the
handoff and canonical files; on digest mismatch, trust current disk.

The junior is exempt from automatic checkpoint calls, rollover, and retry.
Its approval remains one approval = one attempted run.

## The driver lane is YOU

When you are the interactive session invoking pair.sh, the engine meters you
as `.context.driver` (estimate, or your CLI's own local telemetry) but cannot
roll you over. pair.sh output will carry a `DRIVER CONTEXT NOTE` near the
soft threshold and a `DRIVER CONTEXT ALERT` past rollover. On ALERT: run
`pair.sh driver-rollover`, append your semantic handoff to the numbered
`.pair/checkpoints/driver/` file (attribution header first), end the session,
and continue fresh from the canonical `.pair/` files. Do not keep working
past an ALERT or wait for your CLI's auto-compaction.
