# pair-kit — Claude Code ↔ Codex (+ Qwen) pair-programming protocol

A portable, battle-tested setup where coding assistants collaborate on a
project automatically:

- **Codex** = architect / orchestrator / reviewer. Understands requirements,
  writes the task plan, hunts bugs, reviews every diff. Runs read-only — it
  never edits files.
- **Claude Code** = primary implementer. Writes ALL non-trivial code, runs and
  verifies everything, can push back with suggestions that Codex rules on.
- **Qwen Code** = optional junior implementer, for very basic tasks ONLY
  (output validation, minimal fixes, very basic coding). Every qwen delegation
  needs the human's explicit approval first — one approval, one run, recorded
  via `pair.sh qwen-approve`. If Codex's review finds qwen's work not up to
  the mark, the task goes back to Claude — qwen gets no retry loop.
- **You (the human)** = final authority. All commits, sensitive tasks, and
  major changes need your explicit approval; Codex's APPROVED verdict is
  followed by your sign-off.

Give a project brief to *either* CLI and the collaboration starts by itself:
both sides keep persistent sessions (resumable by ID) and exchange everything
through an auditable `.pair/` directory in the project root.

## How it works

```
you ──brief──▶ Claude Code ──pair.sh init──▶ Codex writes requirements.md + plan.md
                    │                              ▲
                    ├── implements task T<n>       │ persistent session
                    ├── pair.sh review ────────────┤ (codex exec resume <id>)
                    ├── fixes findings / suggests ─┘
                    └── final APPROVED ──▶ you sign off ──▶ commit (with your approval)

you ──brief──▶ Codex ── writes .pair/ itself ──▶ pair.sh claude "T1: ..." ──▶ Claude implements
                    └── reviews each diff, loops, final APPROVED ──▶ you sign off

very basic task? ──▶ propose qwen ──▶ YOU approve ──▶ pair.sh qwen-approve + pair.sh qwen
                                                          │
                              Codex review: up to the mark? ── no ──▶ back to Claude
```

All state lives in `<project>/.pair/`:

```
state.json          # codex/claude/qwen session ids, phase, qwen_approval record
requirements.md     # Codex's understanding of the project
plan.md             # task list T1,T2,... with done-conditions
reviews/NNN.md      # each review verdict (VERDICT: APPROVED / CHANGES_REQUIRED)
suggestions/NNN.md  # implementer suggestions + Codex rulings
log.md              # append-only timeline of every exchange
```

**Attribution rule:** every addition to the shared `.pair/` files (log, plan,
suggestions, reviews) starts with an agent-first header:
`### <Agent> — <YYYY-MM-DD HH:MM:SS>` where Agent ∈ Codex / Claude / Qwen /
Keshav. `pair.sh` writes this automatically for everything it produces; agents
editing `.pair/` files by hand must do the same.

### Qwen delegation (junior lane, human-gated)

```
bash pair.sh qwen-approve "<exact task text>" "<the human's approval note>"
bash pair.sh qwen "<exact same task text>"
bash pair.sh review          # Codex judges; not up to the mark -> back to Claude
```

`pair.sh qwen` refuses to run if there is no recorded approval, if the task
text doesn't exactly match the approved one, or if the approval was already
consumed. The approval is consumed at launch (one approval = one attempted
run) — a failed run does not make it reusable, and there is no standing
approval.

## Contents of this kit

| Path | What it is | Installs to |
|---|---|---|
| `scripts/pair.sh` | The wrapper: init / ask / suggest / review / claude / status | anywhere on PATH-reachable disk |
| `claude/skills/pair-protocol.md` | Claude-side playbook (the full loop) | your skills folder |
| `claude/CLAUDE-pair-section.md` | Snippet to append to a project or global CLAUDE.md | `CLAUDE.md` |
| `codex/AGENTS-pair.md` | Codex-side instructions | `~/.codex/AGENTS.md` |
| `codex/skills/pair-handoff/SKILL.md` | Codex skill: roles, `.pair/` layout, handoff recognition | `~/.codex/skills/pair-handoff/` |
| `install.sh` | Automated setup + prerequisite checks | — |
| `TROUBLESHOOTING.md` | Every failure hit while building this, with fixes | — |

## Prerequisites

- `claude` (Claude Code CLI) — logged in; supports `-p`, `--resume`,
  `--output-format json`
- `codex` (Codex CLI ≥ 0.13x) — logged in; supports `exec`, `exec resume`,
  `review`, execpolicy rules
- `qwen` (Qwen Code CLI ≥ 0.19.x, optional — only for the junior lane) —
  configured (`~/.qwen/settings.json`); supports `-p`, `-r <session>`,
  `-o json`, `--approval-mode`. Not assumed to be on PATH: `pair.sh` calls it
  by absolute path (default `/home/keshav/.local/bin/qwen`, override with
  `PAIR_QWEN_BIN`)
- `jq`, `git`
- Linux only: unprivileged user namespaces enabled (Codex's bubblewrap sandbox
  needs them — see TROUBLESHOOTING #1)

## Install

```bash
./install.sh                 # interactive, shows every change before making it
./install.sh --scripts-dir ~/bin   # choose where pair.sh lives
```

The installer never edits kernel settings itself — it detects the problem and
prints the exact sudo commands for you to run.

## Verify (60 seconds)

```bash
mkdir /tmp/pairtest && cd /tmp/pairtest
bash <scripts-dir>/pair.sh init "tiny test: a hello.py printing hello"
cat .pair/requirements.md .pair/plan.md      # Codex intake worked
echo 'print("hello")' > hello.py
bash <scripts-dir>/pair.sh review "T1"       # review gate works
bash <scripts-dir>/pair.sh claude "Reply with exactly: pair-network-ok"  # Codex->Claude direction
```

## Usage

- **Start from Claude Code:** give it a project brief in a repo. Its CLAUDE.md
  section triggers the protocol: `pair.sh init` → implement → `pair.sh review`
  gates → your final sign-off.
- **Start from Codex:** give it the brief. Its AGENTS.md tells it to bootstrap
  `.pair/`, delegate tasks via `pair.sh claude "T1: ..."`, and review each diff.
- Say **"solo"** in the brief to skip the protocol.

## Configuration (env vars, no script edits needed)

| Variable | Default | Effect |
|---|---|---|
| `PAIR_CLAUDE_MODEL` | `opus` | Model for Claude sessions delegated via `pair.sh claude` |
| `PAIR_CLAUDE_EFFORT` | `high` | Effort level for those sessions |
| `PAIR_CODEX_MODEL` | (codex default) | Model for Codex intake/ask/review calls (`-m` passthrough) |
| `PAIR_QWEN_BIN` | `/home/keshav/.local/bin/qwen` | Absolute path to the qwen CLI (not on non-login-shell PATH) |
| `PAIR_QWEN_APPROVAL` | `yolo` | qwen `--approval-mode`; headless `default` denies edits/shell, `yolo` mirrors Claude's acceptEdits+Bash grant |
| `PAIR_DRIVER` | per-subcommand | Who is logged as delegating (`claude` defaults to Codex, `qwen` to Claude) |

Example: `PAIR_CLAUDE_MODEL=sonnet PAIR_CLAUDE_EFFORT=medium bash pair.sh claude "T2: ..."`

## Governance (encoded in every installed file)

1. Codex never writes code. Sole exception: Claude's usage limit is hit AND the
   human explicitly approves the takeover.
2. Loop until Codex returns APPROVED — then the human gives final sign-off.
3. Human approval required for: any commit to any repository, sensitive tasks,
   major changes (architecture/scope/dependency shifts), destructive actions.
4. The human has the final say on all project directions.
5. Qwen is junior-only: very basic tasks, each delegation individually
   pre-approved by the human (`qwen-approve`, consumed at launch, never
   standing). Neither Claude nor Codex decides alone to use qwen, and qwen
   never decides task suitability itself.
6. Failed qwen review = the task returns to Claude. Qwen may only be used
   again for a different task, with a fresh approval.
7. Every agent addition to shared `.pair/` files carries agent-first
   attribution: `### <Agent> — <timestamp>`.

## Cost note

Every `pair.sh init/ask/suggest/review` call burns OpenAI quota; every
`pair.sh claude` call burns Anthropic quota (at opus/high-effort rates by
default — see Configuration to dial down). Review per completed task, not per
file-save. `pair.sh qwen` costs nothing (local vLLM endpoint) — but it is a
small model; that is exactly why it only gets junior tasks.
