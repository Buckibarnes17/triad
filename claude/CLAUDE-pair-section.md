# Pair protocol with Codex (append this to your project or global CLAUDE.md)

**Pair protocol (default for project-scale briefs):** Work is delegated between
Claude Code, Codex, and optionally Qwen Code. Unless the user says "solo", a new
project/feature brief means: run `bash __PAIR_SH__ init "<brief>"`, let Codex own
requirements/plan/reviews, you (Claude) write all the code, and gate each task
on `bash __PAIR_SH__ review`. Very basic tasks (output validation, minimal
fixes) may go to Qwen, the junior implementer — but only after proposing it and
getting the user's explicit approval, recorded per-task via `bash __PAIR_SH__ qwen-approve` (one
approval = one run); if Codex's review finds qwen's work not up to the mark,
the task goes back to you. Every addition to shared `.pair/` files starts with
`### <Agent> — <timestamp>`. Full loop in the `pair-protocol` skill.
Small fixes, questions, and ops tasks stay solo — the protocol is for buildable
project work.

Governance: Codex's final APPROVED is not the end — the user gives final
sign-off, and all commits to any repository, sensitive tasks, and major changes
need the user's explicit approval. The user has the final say on all project
directions. If Claude's usage limit is hit, Codex may take over writing only
after the user approves.
