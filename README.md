# Triad — agent-agnostic pair-programming protocol for assistant CLIs

Triad lets coding assistants collaborate on a project **through explicit
roles, not hardcoded model names**. Any assistant CLI can be plugged into any
role by writing one adapter file — and swapped out again without touching the
engine. It ships with adapters for Codex, Claude Code, and Qwen Code, plus a
template for adding your own.

The three roles (hence the name):

| Role | Does | Cannot | Default agent |
|---|---|---|---|
| **Architect** | Requirements intake, task plan, rulings on suggestions, reviews every diff | Create/edit/delete files — runs read-only | Codex |
| **Implementer** | Writes ALL non-trivial code, runs and verifies everything, pushes back with suggestions | Commit without the human | Claude Code |
| **Junior** (optional) | Very basic tasks only: output validation, minimal mechanical fixes | Run without a fresh human approval; retry after a failed review | Qwen Code |

**You, the human, are the fourth party and final authority**: every commit,
sensitive task, and major change needs your explicit approval, and the
architect's APPROVED verdict is always followed by your sign-off.

Give a project brief to either the implementer or the architect and the
collaboration starts by itself: each agent keeps a persistent session
(resumable by id), and everything they exchange is written to an auditable
`.pair/` directory in your project root.

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

---

## Setup — from zero to a running Triad

### Step 1 — prerequisites

Always required: `jq`, `git`, bash ≥ 4.4, Linux (macOS needs coreutils for
`readlink -f`).

Plus the CLI for each agent you enable (only the roles you use):

- `codex` (Codex CLI ≥ 0.13x) — logged in; needs `exec`, `exec resume`,
  `review`. On Linux, unprivileged user namespaces must be enabled for its
  sandbox (the installer detects this and prints the fix —
  see [TROUBLESHOOTING #4](TROUBLESHOOTING.md)).
- `claude` (Claude Code CLI) — logged in; needs `-p`, `--resume`,
  `--output-format json`.
- `qwen` (Qwen Code CLI ≥ 0.19.x) — configured (`~/.qwen/settings.json`);
  needs `-p`, `-r`, `-o json`. Not assumed to be on PATH — it is called by
  absolute path (default `~/.local/bin/qwen`, override `PAIR_QWEN_BIN`).

Using a different assistant? See [Swapping agents in and out](#swapping-agents-in-and-out).

### Step 2 — clone and self-test

```bash
git clone <this-repo> triad && cd triad
bash tests/smoke.sh        # full protocol run against mock CLIs — no real agents, no quota
```

Every test must print `ok`. This proves the engine and adapters work on your
machine before any real agent or quota is involved.

### Step 3 — install

```bash
./install.sh                          # interactive; shows every change before making it
./install.sh --scripts-dir ~/bin      # choose where pair.sh + adapters live (default ~/.local/bin)
./install.sh --agents "codex claude"  # set up only these agents (default: all three)
./install.sh --yes                    # non-interactive
```

This copies `pair.sh` to `<scripts-dir>/pair.sh`, the adapters to
`<scripts-dir>/pair-adapters/`, then runs each enabled agent's own setup hook
(Codex: sandbox check, `config.toml` network access, execpolicy allow-rule,
AGENTS.md section + skill; Claude: skill + CLAUDE.md section). Everything
machine-level is behind a y/N prompt, and the installer never edits kernel
settings — it prints the exact sudo commands for you to run yourself.

`--agents` only scopes installer checks/setup; which agent holds which role is
decided later, per project, at `pair.sh init`.

The default `<scripts-dir>` (`~/.local/bin`) is on PATH for most login shells,
so from here on the examples invoke `pair.sh` bare — if yours isn't, use the
full `<scripts-dir>/pair.sh` path (agent-side instruction files installed by
the hooks always use the full path).

### Step 4 — verify the live wiring (~60s, burns a little quota)

```bash
mkdir /tmp/triadtest && cd /tmp/triadtest
pair.sh init "tiny test: a hello.py printing hello"
cat .pair/requirements.md .pair/plan.md      # architect intake worked
echo 'print("hello")' > hello.py
pair.sh review "T1"                          # review gate works
pair.sh implement "Reply with exactly: pair-network-ok"
pair.sh junior "anything"   # must REFUSE (no approval recorded) — that's the gate working
```

### Step 5 — set your name (recommended)

Approvals and log entries attribute the human by `PAIR_HUMAN`, falling back
to `git config user.name`, then `$USER`. If your git name is a handle rather
than your name:

```bash
echo 'export PAIR_HUMAN="YourName"' >> ~/.bashrc
```

### Step 6 — first real project

From your project root, either:

- **start from the implementer** (e.g. Claude Code): give it the project
  brief. The installed CLAUDE.md section triggers the protocol: it runs
  `pair.sh init`, implements task by task, gates each on `pair.sh review`,
  and comes back to you for final sign-off; or
- **start from the architect** (e.g. Codex): give it the brief. Its AGENTS.md
  section tells it to bootstrap `.pair/`, delegate via
  `pair.sh implement "T1: ..."`, and review each diff.

Say **"solo"** in the brief to skip the protocol for that task. To run a
non-default lineup or disable the junior lane for a project:

```bash
PAIR_ARCHITECT=claude PAIR_IMPLEMENTER=mycli PAIR_JUNIOR= pair.sh init "<brief>"
```

---

## Day-to-day commands

```
pair.sh init "<project brief>"            architect intake -> requirements.md + plan.md
pair.sh ask "<question>"                  ask the persistent architect session
pair.sh suggest "<idea + why>"            architect rules ACCEPT/REJECT, may amend the plan
pair.sh review [notes]                    architect reviews uncommitted changes vs requirements
pair.sh implement "<task>"                drive the implementer headless (architect-side entry)
pair.sh junior-approve "<task>" "<note>"  record the human's one-time approval for a junior task
pair.sh junior "<task>"                   delegate the approved basic task to the junior
pair.sh status                            roles + state + last log entries
```

Legacy aliases from the pre-adapter era still work: `claude` → `implement`,
`qwen` → `junior`, `qwen-approve` → `junior-approve`.

## The shared state: `.pair/`

```
state.json          # roles, human, per-role sessions {agent, id}, phase, junior_approval
requirements.md     # the architect's understanding of the project
plan.md             # task list T1,T2,... with done-conditions
reviews/NNN.md      # each review verdict (VERDICT: APPROVED / CHANGES_REQUIRED)
suggestions/NNN.md  # implementer suggestions + architect rulings
log.md              # append-only timeline of every exchange
```

`state.json` shape — roles are fixed at `pair.sh init` and live here (edit
`.roles` to reassign mid-project; a reassigned role gets a fresh session
automatically; pre-adapter state files are migrated in place):

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
`### <Agent> — <YYYY-MM-DD HH:MM:SS>`, using the agent's display name
(Codex / Claude / Qwen / ...) or the human's name. `pair.sh` writes this
automatically for everything it produces; agents editing `.pair/` files by
hand must do the same.

## The junior lane (human-gated, one approval = one run)

```bash
pair.sh junior-approve "<exact task text>" "<the human's approval note>"
pair.sh junior "<exact same task text>"
pair.sh review     # architect judges; not up to the mark -> back to the implementer
```

`pair.sh junior` refuses if there is no recorded approval, if the task text
doesn't exactly match the approved one, or if the approval was already
consumed. The approval is consumed at launch — a failed run does not make it
reusable, and there is no standing approval. A task that fails review goes
back to the implementer; the junior may only be used again for a *different*
task, with a fresh approval.

## Swapping agents in and out

Any assistant CLI can hold any role it has the capability for — the engine
has **no hardcoded agent behavior** beyond defaults and legacy aliases.
Plugging in a new one is one bash file implementing a small contract
(`<name>_display`, `_check`, `_consult` and/or `_implement`, optional
`_review`/`_install`):

```bash
# in your kit checkout:
cp adapters/template.sh adapters/mycli.sh    # edit the placeholders
bash tests/smoke.sh                          # engine + contract lint still pass
./install.sh --agents mycli                  # copy it next to the installed pair.sh
# in any project:
PAIR_IMPLEMENTER=mycli pair.sh init "<brief>"
```

The full contract — call signatures, session semantics, the stdout-is-only-
the-session-id rule, install hooks, mock-based testing — is in
**[docs/ADAPTERS.md](docs/ADAPTERS.md)**. Reference implementations:
`adapters/codex.sh` (native review, JSONL sessions), `adapters/claude.sh`
(one CLI in two roles with different permission lanes), `adapters/qwen.sh`
(JSON event-array output, absolute-path binary).

To swap an agent mid-project: edit `.roles` in `.pair/state.json` — the next
call notes the reassignment and starts that role on a fresh session.

## Configuration reference (env vars, no script edits)

Role assignment (read once at `pair.sh init`, then persisted in state.json):

| Variable | Default | Effect |
|---|---|---|
| `PAIR_ARCHITECT` | `codex` | Agent holding the architect role |
| `PAIR_IMPLEMENTER` | `claude` | Agent holding the implementer role |
| `PAIR_JUNIOR` | `qwen` | Agent holding the junior role; `PAIR_JUNIOR=` (empty) disables the lane |
| `PAIR_HUMAN` | `git config user.name`, else `$USER` | The human's name (attribution, approvals) |
| `PAIR_ADAPTERS_DIR` | `<pair.sh dir>/pair-adapters`, else `../adapters` | Where adapters load from |
| `PAIR_DRIVER` | per-subcommand | Who is logged as delegating (`implement` → the architect, `junior` → the implementer) |

Adapter-specific (each adapter documents its own):

| Variable | Default | Effect |
|---|---|---|
| `PAIR_CLAUDE_MODEL` / `PAIR_CLAUDE_EFFORT` | `opus` / `high` | Delegated Claude sessions |
| `PAIR_CODEX_MODEL` | (codex default) | Codex `-m` passthrough |
| `PAIR_QWEN_BIN` | `~/.local/bin/qwen` | Absolute path to the qwen CLI |
| `PAIR_QWEN_APPROVAL` | `yolo` | qwen `--approval-mode` (headless `default` denies edits/shell) |

Example: `PAIR_CLAUDE_MODEL=sonnet PAIR_CLAUDE_EFFORT=medium pair.sh implement "T2: ..."`

## Governance (encoded in every installed file)

1. The architect never writes code. Sole exception: the implementer's usage
   limit is hit AND the human explicitly approves the takeover.
2. Loop until the architect returns APPROVED — then the human gives final
   sign-off.
3. Human approval required for: any commit to any repository, sensitive
   tasks, major changes (architecture/scope/dependency shifts), destructive
   actions.
4. The human has the final say on all project directions.
5. The junior lane is junior-only: very basic tasks, each delegation
   individually pre-approved by the human, consumed at launch, never
   standing. Neither the implementer nor the architect decides alone to use
   the junior, and the junior never judges its own task suitability.
6. Failed junior review = the task returns to the implementer.
7. Every agent addition to shared `.pair/` files carries agent-first
   attribution: `### <Agent> — <timestamp>`.

## Cost note

Every `init/ask/suggest/review` call burns the architect's quota; every
`implement` call burns the implementer's (at opus/high-effort rates by
default — dial down via the config table). Review per completed task, not per
file-save. A locally-served junior (the default qwen setup) costs nothing —
but it is a small model, which is exactly why it only gets junior tasks.

## Repository layout

| Path | What it is | Installs to |
|---|---|---|
| `scripts/pair.sh` | The engine (roles, gates, state, attribution) | `<scripts-dir>/pair.sh` |
| `adapters/<name>.sh` | One adapter per assistant CLI + `template.sh` | `<scripts-dir>/pair-adapters/` |
| `docs/ADAPTERS.md` | The full adapter contract | — |
| `agents/<name>/` | Per-agent install assets (skills, instruction snippets) | agent-specific (see adapter) |
| `install.sh` | Setup + prerequisite checks (adapter-driven) | — |
| `tests/` | Mock CLIs + `smoke.sh` end-to-end suite (no quota) | — |
| `TROUBLESHOOTING.md` | Every failure hit while building this, with fixes | — |

## When something breaks

[TROUBLESHOOTING.md](TROUBLESHOOTING.md) covers every failure actually hit
while building this, grouped by adapter — sandbox/userns issues, network
blocks, escalation refusals, CLI flag quirks, session id capture, the junior
gate refusals, and endpoint diagnosis.
