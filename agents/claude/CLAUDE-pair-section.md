# Triad Protocol (append this to your project or global CLAUDE.md)

**Triad Protocol (default for project-scale briefs):** Work is delegated between
role-holding assistants — an architect (Codex by default), you (Claude) as the
implementer, and optionally a junior implementer (Qwen by default); the lineup
lives in `.pair/state.json`. Unless the user says "solo", a new project/feature
brief means: run `bash __PAIR_SH__ init "<brief>"`, let the architect own
requirements/plan/reviews, you write all the code, and gate each task on
`bash __PAIR_SH__ review`. Very basic tasks (output validation, minimal fixes)
may go to the junior — but only after proposing it and getting the user's
explicit approval, recorded per-task via `bash __PAIR_SH__ junior-approve` (one
approval = one run); if the architect's review finds the junior's work not up
to the mark, the task goes back to you. Every addition to shared `.pair/`
files starts with `### <Agent> — <timestamp>`. Full loop in the
`pair-protocol` skill. Small fixes, questions, and ops tasks stay solo — the
protocol is for buildable project work.

Governance: the architect's final APPROVED is not the end — the user gives
final sign-off, and all commits to any repository, sensitive tasks, and major
changes need the user's explicit approval. The user has the final say on all
project directions. If your usage limit is hit, the architect may take over
writing only after the user approves.
