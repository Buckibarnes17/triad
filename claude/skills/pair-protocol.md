# Skill: Pair protocol — Claude implements, Codex orchestrates and reviews, Qwen assists

**When to use:** The user gives a project/feature brief and hasn't said "solo" — the default for project-scale work is to run it as a pair with Codex (architect/reviewer) via `__PAIR_SH__`.

## Roles (enforced, not aspirational)

- **Codex** (persistent `codex exec` session, `read-only` sandbox — it *cannot* edit files): owns requirements, task plan, reviews, bug-hunting, and rulings on suggestions.
- **Claude Code (you)**: the PRIMARY implementer — write ALL non-trivial code, run all commands, verify everything, and transcribe Codex's plan amendments into `.pair/plan.md` (Codex can't write).
- **Qwen Code** (junior implementer; local endpoint, free but a small model): ONLY very basic tasks — output validation, minimal mechanical fixes, very basic coding. **Every qwen delegation needs the user's explicit approval first, every time.** Propose it, wait for the go-ahead, record it (`bash __PAIR_SH__ qwen-approve "<exact task>" "<approval note>"`), then run `bash __PAIR_SH__ qwen "<exact task>"`. One approval = one attempted run; no standing approvals. If Codex's review finds qwen's work not up to the mark, YOU redo the task — qwen gets no retry.
- **Exception — Claude usage limit hit:** Codex may take over writing code, but **only after the user explicitly approves the takeover**. Ask first; never hand the writer role to Codex on your own.
- **The user has the final say on all project directions.** Both assistants must get explicit approval for: any commit to any repository, any sensitive task, and any major change (architecture shifts, scope changes, dependency swaps, deletions).

## Attribution rule (all shared .pair/ files)

Every addition to `.pair/log.md`, `.pair/plan.md`, `.pair/suggestions/NNN.md`, `.pair/reviews/NNN.md` starts with `### <Agent> — <YYYY-MM-DD HH:MM:SS>` (Agent ∈ Codex/Claude/Qwen/the user's name). `pair.sh` writes this automatically for everything it produces; when you transcribe plan amendments or add notes by hand, prepend your own `### Claude — <timestamp>` header.

## Steps, in order

1. From the project root, initialize: `bash __PAIR_SH__ init "<the brief, verbatim + relevant context>"`. This git-inits if needed, creates `.pair/`, and has Codex write `requirements.md` + `plan.md` (tasks T1, T2, … with done-conditions). Read both files fully.
2. If requirements look wrong or underspecified, challenge before coding: `bash __PAIR_SH__ ask "<question>"`. Surface real ambiguities to the user — Codex rules on design, the user rules on scope.
3. Implement **one task at a time** from `plan.md`, following the project's normal conventions. Verify it yourself first — run the code/tests. Do not present unverified work for review.
   - **Qwen lane (optional):** if a task is genuinely trivial (output validation, a minimal mechanical fix), you may *propose* delegating it to qwen — say which task and why qwen suffices, and **wait for the user's explicit yes**. Then `qwen-approve` + `qwen` as above. Never invoke qwen without a fresh recorded approval; never split a real task into "basic" pieces to route around the gate. Qwen's output goes through the same review gate as yours.
4. Review gate after each task: `bash __PAIR_SH__ review "current task: T<n>"`. Read `.pair/reviews/NNN.md`:
   - `VERDICT: CHANGES_REQUIRED` → verify each finding against the code, fix valid ones, re-review.
   - Disagree with a finding → `bash __PAIR_SH__ suggest "<your counter-argument>"` and follow the ruling (or escalate to the user if it's a scope question).
5. Have a better idea than the plan? `bash __PAIR_SH__ suggest "<idea + why>"`. If Codex ACCEPTs, update `.pair/plan.md` with its amended section, then continue.
6. After each APPROVED task, *propose* a commit (branch first; suggest names) — **no commit to any repository without the user's explicit approval**.
7. Loop until the final `bash __PAIR_SH__ review` returns APPROVED on the whole diff — **then present to the user for final sign-off; Codex's APPROVED is necessary but not sufficient**. Report: what was built (paths), the review trail (`.pair/reviews/`), anything Codex and you disagreed on, and wait for the go-ahead before committing/shipping.

## Example of a good final state (shape of a completed exchange in `.pair/`)

```
.pair/
  state.json           {"codex_session_id":"019f4055-...","phase":"implement",...}
  requirements.md      goals, constraints, acceptance criteria (Codex intake)
  plan.md              T1 scaffold CLI (done) · T2 core parser (done) · T3 eval script
  reviews/001.md       VERDICT: CHANGES_REQUIRED — 1. parser.py:42 HIGH off-by-one...
  reviews/002.md       VERDICT: APPROVED
  suggestions/001.md   Claude: "sqlite instead of json store, because..." → Codex: ACCEPT, plan amended
  log.md               full timeline, every exchange timestamped
```

Report to the user: "T1–T3 done, final review APPROVED (reviews/004.md). One design change vs the original plan: sqlite store (suggestions/001.md). Code in src/, tests pass 12/12. Awaiting your sign-off before commit."

## Mistakes to avoid

- **Don't treat Codex's APPROVED as authorization to commit or ship** — the user approves all commits, sensitive tasks, and major changes; they have the final say on direction.
- **Don't let Codex write code just because Claude is rate-limited** — the takeover needs the user's explicit approval first.
- **Don't skip the review gate** because the change "is small" — the whole point is Codex checking relevance against requirements the user gave once.
- **Don't apply review findings blindly** — verify each against the code; fix or push back with evidence.
- **Don't let Codex's plan go stale**: transcribe every ACCEPTed amendment into `plan.md` immediately — it's the shared source of truth if either session dies.
- **Don't review per-file-save.** Review per completed task; every Codex call costs OpenAI quota.
- **Don't run `pair.sh init` twice** — resume the existing session (`state.json` has the id); if the Codex session is lost, start a fresh intake pointing it at the existing `.pair/` files.
- **Don't invoke qwen without the user's fresh, recorded approval** — `pair.sh qwen` enforces this mechanically (exact task match, one-shot), but the proposal + wait is on you.
- **Don't send a failed-review task back to qwen** — it returns to you. Qwen is only for *different* future tasks, each with a new approval.
- **Don't write to shared `.pair/` files without the `### <Agent> — <timestamp>` attribution header.**
