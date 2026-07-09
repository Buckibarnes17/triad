# Skill: Pair protocol — you implement, the architect orchestrates and reviews, a junior assists

**When to use:** The user gives a project/feature brief and hasn't said "solo" — the default for project-scale work is to run it as a pair with an architect agent (Codex by default) via `__PAIR_SH__`.

## Roles (enforced, not aspirational)

Roles are held by agents named in `.pair/state.json` (`.roles`); the defaults
are architect=Codex, implementer=you (Claude), junior=Qwen. The rules below
are about the ROLE, whoever holds it.

- **The architect** (persistent read-only session — it *cannot* edit files): owns requirements, task plan, reviews, bug-hunting, and rulings on suggestions.
- **You, the implementer**: write ALL non-trivial code, run all commands, verify everything, and transcribe the architect's plan amendments into `.pair/plan.md` (the architect can't write).
- **The junior implementer** (optional; typically a small local model — free but limited): ONLY very basic tasks — output validation, minimal mechanical fixes, very basic coding. **Every junior delegation needs the user's explicit approval first, every time.** Propose it, wait for the go-ahead, record it (`bash __PAIR_SH__ junior-approve "<exact task>" "<approval note>"`), then run `bash __PAIR_SH__ junior "<exact task>"`. One approval = one attempted run; no standing approvals. If the architect's review finds the junior's work not up to the mark, YOU redo the task — the junior gets no retry.
- **Exception — implementer usage limit hit:** the architect may take over writing code, but **only after the user explicitly approves the takeover**. Ask first; never hand the writer role over on your own.
- **The user has the final say on all project directions.** All assistants must get explicit approval for: any commit to any repository, any sensitive task, and any major change (architecture shifts, scope changes, dependency swaps, deletions).

## Attribution rule (all shared .pair/ files)

Every addition to `.pair/log.md`, `.pair/plan.md`, `.pair/suggestions/NNN.md`, `.pair/reviews/NNN.md` starts with `### <Agent> — <YYYY-MM-DD HH:MM:SS>` (Agent = the agent's display name or the user's name). `pair.sh` writes this automatically for everything it produces; when you transcribe plan amendments or add notes by hand, prepend your own `### Claude — <timestamp>` header.

## Steps, in order

1. From the project root, initialize: `bash __PAIR_SH__ init "<the brief, verbatim + relevant context>"`. This git-inits if needed, creates `.pair/`, and has the architect write `requirements.md` + `plan.md` (tasks T1, T2, … with done-conditions). Read both files fully. (A different lineup is chosen here too, e.g. `PAIR_ARCHITECT=claude PAIR_JUNIOR= bash __PAIR_SH__ init ...` — roles then persist in `state.json`.)
2. If requirements look wrong or underspecified, challenge before coding: `bash __PAIR_SH__ ask "<question>"`. Surface real ambiguities to the user — the architect rules on design, the user rules on scope.
3. Implement **one task at a time** from `plan.md`, following the project's normal conventions. Verify it yourself first — run the code/tests. Do not present unverified work for review.
   - **Junior lane (optional):** if a task is genuinely trivial (output validation, a minimal mechanical fix), you may *propose* delegating it to the junior — say which task and why the junior suffices, and **wait for the user's explicit yes**. Then `junior-approve` + `junior` as above. Never invoke the junior without a fresh recorded approval; never split a real task into "basic" pieces to route around the gate. The junior's output goes through the same review gate as yours.
4. Review gate after each task: `bash __PAIR_SH__ review "current task: T<n>"`. Read `.pair/reviews/NNN.md`:
   - `VERDICT: CHANGES_REQUIRED` → verify each finding against the code, fix valid ones, re-review.
   - Disagree with a finding → `bash __PAIR_SH__ suggest "<your counter-argument>"` and follow the ruling (or escalate to the user if it's a scope question).
5. Have a better idea than the plan? `bash __PAIR_SH__ suggest "<idea + why>"`. If the architect ACCEPTs, update `.pair/plan.md` with its amended section, then continue.
6. After each APPROVED task, *propose* a commit (branch first; suggest names) — **no commit to any repository without the user's explicit approval**.
7. Loop until the final `bash __PAIR_SH__ review` returns APPROVED on the whole diff — **then present to the user for final sign-off; the architect's APPROVED is necessary but not sufficient**. Report: what was built (paths), the review trail (`.pair/reviews/`), anything the architect and you disagreed on, and wait for the go-ahead before committing/shipping.

## Example of a good final state (shape of a completed exchange in `.pair/`)

```
.pair/
  state.json           {"roles":{"architect":"codex","implementer":"claude","junior":"qwen"},
                        "sessions":{"architect":{"agent":"codex","id":"019f4055-..."}},"phase":"implement",...}
  requirements.md      goals, constraints, acceptance criteria (architect intake)
  plan.md              T1 scaffold CLI (done) · T2 core parser (done) · T3 eval script
  reviews/001.md       VERDICT: CHANGES_REQUIRED — 1. parser.py:42 HIGH off-by-one...
  reviews/002.md       VERDICT: APPROVED
  suggestions/001.md   Claude: "sqlite instead of json store, because..." → Codex: ACCEPT, plan amended
  log.md               full timeline, every exchange timestamped
```

Report to the user: "T1–T3 done, final review APPROVED (reviews/004.md). One design change vs the original plan: sqlite store (suggestions/001.md). Code in src/, tests pass 12/12. Awaiting your sign-off before commit."

## Mistakes to avoid

- **Don't treat the architect's APPROVED as authorization to commit or ship** — the user approves all commits, sensitive tasks, and major changes; they have the final say on direction.
- **Don't let the architect write code just because you are rate-limited** — the takeover needs the user's explicit approval first.
- **Don't skip the review gate** because the change "is small" — the whole point is the architect checking relevance against requirements the user gave once.
- **Don't apply review findings blindly** — verify each against the code; fix or push back with evidence.
- **Don't let the plan go stale**: transcribe every ACCEPTed amendment into `plan.md` immediately — it's the shared source of truth if any session dies.
- **Don't review per-file-save.** Review per completed task; every architect call costs quota.
- **Don't run `pair.sh init` twice** — resume the existing session (`state.json` has the ids); if the architect session is lost, start a fresh intake pointing it at the existing `.pair/` files.
- **Don't invoke the junior without the user's fresh, recorded approval** — `pair.sh junior` enforces this mechanically (exact task match, one-shot), but the proposal + wait is on you.
- **Don't send a failed-review task back to the junior** — it returns to you. The junior is only for *different* future tasks, each with a new approval.
- **Don't write to shared `.pair/` files without the `### <Agent> — <timestamp>` attribution header.**
