# Skill: Context budget — sessions are cache, `.pair/` disk is truth

**When to use:** Every Triad task, alongside `pair-protocol.md`.

## Durable truth and bounded grounding

- Treat a CLI session as disposable working memory. Durable truth is
  `.pair/requirements.md`, `.pair/plan.md`, the latest `.pair/reviews/`,
  `.pair/checkpoints/<role>/current.md`, and `.pair/state.json`.
- Never read all of `.pair/log.md` automatically. Use the configured tail
  shown in engine prompts (default `tail -40 .pair/log.md`).
- Read requirements, plan, the latest review, and current checkpoint in full;
  compare them with current `git status --short` and trust disk on conflict.
- Batch independent reads and commands.

## Output discipline

- Routine output: about 100 lines / 2K tokens.
- Active diagnostics: about 250 lines / 5K tokens, with repeated noise removed.
- Write larger output to a file and return a bounded summary. Do not use a
  subagent unless the user or active instructions explicitly authorize it.

## Checkpoint and rollover

The engine tracks resident context pressure separately from cumulative spend.
Adapter telemetry is used when available; otherwise it uses a conservative
prompt/reply-size estimate. Default policy checkpoints near 100K resident
tokens and rolls over near 150K, 70% of a known window, or 20 calls/tools.

Before a rollover, the engine writes an immutable checkpoint containing exact
paths, tests/results, decisions with rationale, blockers, pending approvals,
and ordered next actions. It then starts a fresh session and injects the
handoff. If the working-tree digest changed, re-verify against disk.

Never put credentials, API keys, secrets, or environment values in a
checkpoint. Never retry or roll over the junior lane; one approval remains one
attempted run.

## The driver lane is YOU

When you are the interactive session invoking pair.sh, the engine meters you
as `.context.driver` but cannot roll your session over. pair.sh output carries
a `DRIVER CONTEXT NOTE` near the soft threshold and a `DRIVER CONTEXT ALERT`
past rollover. On ALERT: run `pair.sh driver-rollover`, append your semantic
handoff to the numbered `.pair/checkpoints/driver/` file (attribution header
first), end the session, and continue fresh from the canonical `.pair/`
files. Never keep orchestrating past an ALERT.

