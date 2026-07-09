# pair-kit — a role-based pair-programming protocol for assistant CLIs

A portable, battle-tested setup where coding assistants collaborate on a
project automatically. The protocol has three fixed **roles**; any assistant
with an adapter (`adapters/<name>.sh`) can fill any role:

- **Architect / orchestrator / reviewer** (default: **Codex**). Understands
  requirements, writes the task plan, hunts bugs, reviews every diff. Runs
  read-only — it never edits files.
- **Implementer** (default: **Claude Code**). Writes ALL non-trivial code, runs
  and verifies everything, can push back with suggestions the architect rules on.
- **Junior implementer** (default: **Qwen Code**, optional). Very basic tasks
  ONLY (output validation, minimal fixes, very basic coding). Every junior
  delegation needs the human's explicit approval first — one approval, one run,
  recorded via `pair.sh junior-approve`. If the architect's review finds the
  junior's work not up to the mark, the task goes back to the implementer —
  the junior gets no retry loop.
- **You (the human)** = final authority. All commits, sensitive tasks, and
  major changes need your explicit approval; the architect's APPROVED verdict
  is followed by your sign-off.

Give a project brief to *either* CLI and the collaboration starts by itself:
all sides keep persistent sessions (resumable by ID) and exchange everything
through an auditable `.pair/` directory in the project root.

## How it works

```
you ──brief──▶ implementer ──pair.sh init──▶ architect writes requirements.md + plan.md
                    │                              ▲
                    ├── implements task T<n>       │ persistent session
                    ├── pair.sh review ────────────┤ (resumed by stored id)
                    ├── fixes findings / suggests ─┘
                    └── final APPROVED ──▶ you sign off ──▶ commit (with your approval)

you ──brief──▶ architect ── writes .pair/ itself ──▶ pair.sh implement "T1: ..." ──▶ implementer
                    └── reviews each diff, loops, final APPROVED ──▶ you sign off

very basic task? ──▶ propose junior ──▶ YOU approve ──▶ pair.sh junior-approve + pair.sh junior
                                                            │
                          architect review: up to the mark? ── no ──▶ back to the implementer
```

All state lives in `<project>/.pair/`:

```
state.json          # roles, human, per-role sessions {agent, id}, phase, junior_approval
requirements.md     # the architect's understanding of the project
plan.md             # task list T1,T2,... with done-conditions
reviews/NNN.md      # each review verdict (VERDICT: APPROVED / CHANGES_REQUIRED)
suggestions/NNN.md  # implementer suggestions + architect rulings
log.md              # append-only timeline of every exchange
```

`state.json` shape (roles are fixed at `pair.sh init` and live here — edit
`.roles` to reassign mid-project; a reassigned role gets a fresh session):

```json
{
  "roles":    {"architect": "codex", "implementer": "claude", "junior": "qwen"},
  "human":    "you",
  "sessions": {"architect": {"agent": "codex", "id": "019f..."},
               "implementer": {"agent": "claude", "id": "..."}},
  "phase":    "implement",
  "junior_approval": {"task": "...", "note": "...", "approver": "you",
                      "approved_at": "...", "consumed": false}
}
```

**Attribution rule:** every addition to the shared `.pair/` files (log, plan,
suggestions, reviews) starts with an agent-first header:
`### <Agent> — <YYYY-MM-DD HH:MM:SS>` where Agent is the agent's display name
(Codex / Claude / Qwen / ...) or the human's name. `pair.sh` writes this
automatically for everything it produces; agents editing `.pair/` files by
hand must do the same.

### Junior delegation (human-gated)

```
bash pair.sh junior-approve "<exact task text>" "<the human's approval note>"
bash pair.sh junior "<exact same task text>"
bash pair.sh review          # architect judges; not up to the mark -> back to the implementer
```

`pair.sh junior` refuses to run if there is no recorded approval, if the task
text doesn't exactly match the approved one, or if the approval was already
consumed. The approval is consumed at launch (one approval = one attempted
run) — a failed run does not make it reusable, and there is no standing
approval.

## Contents of this kit

| Path | What it is | Installs to |
|---|---|---|
| `scripts/pair.sh` | The engine: init / ask / suggest / review / implement / junior / status | anywhere on PATH-reachable disk |
| `adapters/<name>.sh` | One adapter per assistant CLI (codex, claude, qwen) | `<scripts-dir>/pair-adapters/` |
| `agents/claude/skills/pair-protocol.md` | Implementer-side playbook (the full loop) | your skills folder |
| `agents/claude/CLAUDE-pair-section.md` | Snippet to append to a project or global CLAUDE.md | `CLAUDE.md` |
| `agents/codex/AGENTS-pair.md` | Architect-side instructions | `~/.codex/AGENTS.md` |
| `agents/codex/skills/pair-handoff/SKILL.md` | Codex skill: roles, `.pair/` layout, handoff recognition | `~/.codex/skills/pair-handoff/` |
| `install.sh` | Automated setup + prerequisite checks (adapter-driven) | — |
| `tests/` | Mock agent CLIs + `smoke.sh` end-to-end test (no real CLIs needed) | — |
| `TROUBLESHOOTING.md` | Every failure hit while building this, with fixes | — |

## Prerequisites

- `jq`, `git` (always)
- The CLI for each agent you enable, with its adapter's expectations:
  - `codex` (Codex CLI ≥ 0.13x) — logged in; supports `exec`, `exec resume`,
    `review`, execpolicy rules. Linux: unprivileged user namespaces enabled
    (bubblewrap sandbox — see TROUBLESHOOTING #1)
  - `claude` (Claude Code CLI) — logged in; supports `-p`, `--resume`,
    `--output-format json`
  - `qwen` (Qwen Code CLI ≥ 0.19.x, junior lane only) — configured
    (`~/.qwen/settings.json`); supports `-p`, `-r <session>`, `-o json`,
    `--approval-mode`. Not assumed to be on PATH: called by absolute path
    (default `~/.local/bin/qwen`, override with `PAIR_QWEN_BIN`)

## Install

```bash
./install.sh                        # interactive, shows every change before making it
./install.sh --scripts-dir ~/bin    # choose where pair.sh + adapters live
./install.sh --agents "codex claude"   # only these agents (skip the junior lane)
```

The installer never edits kernel settings itself — it detects the problem and
prints the exact sudo commands for you to run.

## Verify (60 seconds)

```bash
mkdir /tmp/pairtest && cd /tmp/pairtest
bash <scripts-dir>/pair.sh init "tiny test: a hello.py printing hello"
cat .pair/requirements.md .pair/plan.md      # architect intake worked
echo 'print("hello")' > hello.py
bash <scripts-dir>/pair.sh review "T1"       # review gate works
bash <scripts-dir>/pair.sh implement "Reply with exactly: pair-network-ok"  # architect->implementer direction
```

Offline check of the kit itself: `bash tests/smoke.sh` (runs the whole
protocol against mock CLIs — no real agents, no quota).

## Usage

- **Start from the implementer** (e.g. Claude Code): give it a project brief
  in a repo. Its CLAUDE.md section triggers the protocol: `pair.sh init` →
  implement → `pair.sh review` gates → your final sign-off.
- **Start from the architect** (e.g. Codex): give it the brief. Its AGENTS.md
  tells it to bootstrap `.pair/`, delegate tasks via
  `pair.sh implement "T1: ..."`, and review each diff.
- Say **"solo"** in the brief to skip the protocol.

## Configuration (env vars, no script edits needed)

Role assignment (read at `pair.sh init`, then persisted in `state.json`):

| Variable | Default | Effect |
|---|---|---|
| `PAIR_ARCHITECT` | `codex` | Agent holding the architect role |
| `PAIR_IMPLEMENTER` | `claude` | Agent holding the implementer role |
| `PAIR_JUNIOR` | `qwen` | Agent holding the junior role; set empty (`PAIR_JUNIOR=`) to disable the lane |
| `PAIR_HUMAN` | `git config user.name`, else `$USER` | The human's name (attribution, approvals) |
| `PAIR_ADAPTERS_DIR` | `<pair.sh dir>/pair-adapters`, else `../adapters` | Where adapters are loaded from |
| `PAIR_DRIVER` | per-subcommand | Who is logged as delegating (`implement` defaults to the architect, `junior` to the implementer) |

Adapter-specific:

| Variable | Default | Effect |
|---|---|---|
| `PAIR_CLAUDE_MODEL` | `opus` | Model for delegated Claude sessions |
| `PAIR_CLAUDE_EFFORT` | `high` | Effort level for those sessions |
| `PAIR_CODEX_MODEL` | (codex default) | Model for Codex calls (`-m` passthrough) |
| `PAIR_QWEN_BIN` | `~/.local/bin/qwen` | Absolute path to the qwen CLI (not on non-login-shell PATH) |
| `PAIR_QWEN_APPROVAL` | `yolo` | qwen `--approval-mode`; headless `default` denies edits/shell, `yolo` mirrors Claude's acceptEdits+Bash grant |

Example: `PAIR_CLAUDE_MODEL=sonnet PAIR_CLAUDE_EFFORT=medium bash pair.sh implement "T2: ..."`

Legacy subcommand aliases still work: `pair.sh claude` → `implement`,
`pair.sh qwen` → `junior`, `pair.sh qwen-approve` → `junior-approve`.

## Adding an assistant

One file: `adapters/<name>.sh` (name must match `^[a-z][a-z0-9_]*$`; all
symbols prefixed with the name). It is sourced by both `pair.sh` and
`install.sh`, so it must be side-effect-free at source time.

| Symbol | Required for | Contract |
|---|---|---|
| `<name>_display` (var) | always | Display name for attribution, e.g. `gemini_display="Gemini"` |
| `<name>_check` | always | CLI present/usable; print version info; nonzero if not |
| `<name>_consult OUTFILE SESSION_ID PROMPT` | architect role | Read-only call. Empty `SESSION_ID` = fresh, else resume. Write the reply to `OUTFILE`; print ONLY the (possibly new) session id on stdout — all CLI noise goes to files or /dev/null |
| `<name>_implement OUTFILE SESSION_ID PROMPT` | implementer / junior role | Same convention, write-capable |
| `<name>_review OUTFILE SESSION_ID PROMPT` | optional | Native review of uncommitted changes (append to OUTFILE, return the CLI's exit code). Without it, `pair.sh review` falls back to `_consult` with the git diff embedded in the prompt |
| `<name>_install KIT_DIR PAIR_SH` | optional | Install hook (skills, config appends, sandbox checks); may use install.sh's `say/ok/warn/confirm/render` helpers |

Then: assign it a role (`PAIR_ARCHITECT=gemini bash pair.sh init ...`), and
test against the mocks pattern in `tests/` (copy a mock, emit your CLI's JSON
shape, extend `tests/smoke.sh`). Optional per-agent install assets (skills,
instruction snippets) go under `agents/<name>/`.

## Governance (encoded in every installed file)

1. The architect never writes code. Sole exception: the implementer's usage
   limit is hit AND the human explicitly approves the takeover.
2. Loop until the architect returns APPROVED — then the human gives final sign-off.
3. Human approval required for: any commit to any repository, sensitive tasks,
   major changes (architecture/scope/dependency shifts), destructive actions.
4. The human has the final say on all project directions.
5. The junior is junior-only: very basic tasks, each delegation individually
   pre-approved by the human (`junior-approve`, consumed at launch, never
   standing). Neither the implementer nor the architect decides alone to use
   the junior, and the junior never decides task suitability itself.
6. Failed junior review = the task returns to the implementer. The junior may
   only be used again for a different task, with a fresh approval.
7. Every agent addition to shared `.pair/` files carries agent-first
   attribution: `### <Agent> — <timestamp>`.

## Cost note

Every `pair.sh init/ask/suggest/review` call burns the architect's quota;
every `pair.sh implement` call burns the implementer's (at opus/high-effort
rates by default — see Configuration to dial down). Review per completed task,
not per file-save. A locally-served junior (the default qwen setup) costs
nothing — but it is a small model; that is exactly why it only gets junior
tasks.
