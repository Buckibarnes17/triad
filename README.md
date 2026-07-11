# Triad — agent-agnostic pair-programming protocol for assistant CLIs

Triad lets coding assistants collaborate on a project **through explicit
roles, not hardcoded model names**. Any assistant CLI can be plugged into any
role by writing one adapter file — and swapped out again without touching the
engine. It ships with adapters for Codex, Claude Code, Qwen Code, and
opencode, plus a template for adding your own.

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

Long sessions are managed automatically: Triad tracks resident context
pressure separately from cumulative token spend, writes durable semantic
checkpoints, and rolls architect/implementer sessions over before their
context windows become destructive. Fresh sessions re-ground from `.pair/`;
the junior lane is never auto-retried or rolled over.

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

- `codex` (Codex CLI with JSONL `exec` + `exec resume`; verified with 0.144.1)
  — logged in; needs `exec`, `exec resume`,
  `review`. On Linux, unprivileged user namespaces must be enabled for its
  sandbox (the installer detects this and prints the fix —
  see [TROUBLESHOOTING #4](TROUBLESHOOTING.md)).
- `claude` (Claude Code CLI) — logged in; needs `-p`, `--resume`,
  `--output-format json`.
- `qwen` (Qwen Code CLI ≥ 0.19.x) — configured (`~/.qwen/settings.json`);
  needs `-p`, `-r`, `-o json`. Not assumed to be on PATH — it is called by
  absolute path (default `~/.local/bin/qwen`, override `PAIR_QWEN_BIN`).
- `opencode` (opencode CLI, verified with 1.17.8) — providers configured;
  needs `run`, `--format json`, `-s`, `--agent`. Also called by absolute path
  (default `~/.opencode/bin/opencode`, override `PAIR_OPENCODE_BIN`); pick a
  model with `PAIR_OPENCODE_MODEL=provider/model`.

Using a different assistant? See [Swapping agents in and out](#swapping-agents-in-and-out).

Update a global npm installation with `npm install -g @openai/codex@latest`
(use your system's package-manager/root convention if the global prefix is
root-owned), then verify with `codex --version`. Keeping the CLI current is
important for model compatibility and structured usage telemetry.

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
pair.sh checkpoint [role]                write a durable checkpoint without rolling over
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
checkpoints/<role>/  # immutable NNN.md handoffs + current.md for fresh sessions
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
  "context_policy": {"mode": "auto", "soft_tokens": 100000,
                     "rollover_tokens": 150000, "rollover_pct": 70},
  "context": {"architect": {"resident_input_tokens": 84210,
                              "raw_total_tokens": 426000,
                              "checkpoint_due": false, "rollover_due": false}},
  "checkpoints": {"architect": []},
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
(JSON event-array output, absolute-path binary), `adapters/opencode.sh`
(JSONL with multi-event reply concatenation, read-only lane via its `plan`
agent).

Any shipped adapter can hold any capable role, e.g.:

```bash
PAIR_ARCHITECT=opencode pair.sh init "<brief>"     # opencode plans & reviews (fallback review)
PAIR_IMPLEMENTER=opencode pair.sh init "<brief>"   # opencode writes the code
PAIR_JUNIOR=opencode pair.sh init "<brief>"        # opencode as the human-gated junior
```

The default lineup remains Codex + Claude Code + Qwen Code; opencode — like
any additional adapter — is opt-in per project via these variables, never a
silent default change.

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

Context policy is also captured only at `pair.sh init`; persisted state wins
afterward:

| Variable | Default | Effect |
|---|---:|---|
| `PAIR_CTX_MODE` | `auto` | `auto` checkpoints/rolls; `warn` reports only; `off` disables actions |
| `PAIR_CTX_SOFT_TOKENS` | `100000` | One proactive checkpoint per live session |
| `PAIR_CTX_ROLLOVER_TOKENS` | `150000` | Resident-token rollover threshold |
| `PAIR_CTX_ROLLOVER_PCT` | `70` | Rollover percent when the model window is known |
| `PAIR_CTX_CALL_LIMIT` | `20` | Pair/tool-call rollover fallback |
| `PAIR_CTX_RAW_WARN_TOKENS` | `2000000` | Cumulative-spend checkpoint warning threshold |
| `PAIR_CTX_LOG_TAIL` | `40` | Routine `.pair/log.md` tail given to agents |
| `PAIR_CTX_REVIEW_MAX_BYTES` | `200000` | Combined fallback-review bundle cap |
| `PAIR_CTX_IMPLEMENT_FACTOR` | `4` | Conservative estimator multiplier for write lanes |

Adapters may report numeric usage through a private temporary sidecar. This
is optional: unsupported/invalid telemetry falls back to an engine estimate.
The sidecar path is not exported to the assistant process and must never
contain prompts, replies, credentials, keys, or environment values.

### Checkpoint and rollover behavior

- At soft pressure, `auto` writes one checkpoint and keeps the session.
- At rollover pressure, it writes history/current/log/state first, then clears
  only the old session and per-session pressure counters. Lifetime raw/cached
  spend remains visible.
- The fresh call reads the current handoff plus canonical `.pair/` files. A
  working-tree digest mismatch produces a staleness warning; disk wins.
- A genuine adapter session-not-found signal gets one fresh retry for the
  architect/implementer. Arbitrary failures and every junior call get none.
- `pair.sh checkpoint architect` or `implementer` creates a manual recovery
  point. `checkpoint junior` is mechanical-only and never invokes the junior.

Adapter-specific (each adapter documents its own):

| Variable | Default | Effect |
|---|---|---|
| `PAIR_CLAUDE_MODEL` / `PAIR_CLAUDE_EFFORT` | `opus` / `high` | Delegated Claude sessions |
| `PAIR_CODEX_MODEL` | (codex default) | Codex `-m` passthrough |
| `PAIR_QWEN_BIN` | `~/.local/bin/qwen` | Absolute path to the qwen CLI |
| `PAIR_QWEN_APPROVAL` | `yolo` | qwen `--approval-mode` (headless `default` denies edits/shell) |
| `PAIR_OPENCODE_BIN` | `~/.opencode/bin/opencode` | Absolute path to the opencode CLI |
| `PAIR_OPENCODE_MODEL` | (opencode default) | opencode `-m provider/model` passthrough |

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
file-save. Cached input still counts as token volume even when priced more
cheaply, so repeated large contexts can dominate raw usage; bounded log/diff
views and rollover prevent that resident prefix from growing forever. A
locally-served junior (the default qwen setup) costs nothing —
but it is a small model, which is exactly why it only gets junior tasks.

## Repository layout

| Path | What it is | Installs to |
|---|---|---|
| `scripts/pair.sh` | The engine (roles, gates, state, attribution) | `<scripts-dir>/pair.sh` |
| `adapters/<name>.sh` | One adapter per assistant CLI + `template.sh` | `<scripts-dir>/pair-adapters/` |
| `docs/ADAPTERS.md` | The full adapter contract | — |
| `agents/<name>/` | Per-agent install assets (`pair-*` + mandatory `context-budget` skills, instruction snippets) | agent-specific (see adapter) |
| `install.sh` | Setup + prerequisite checks (adapter-driven) | — |
| `tests/` | Mock CLIs + `smoke.sh` end-to-end suite (no quota) | — |
| `TROUBLESHOOTING.md` | Every failure hit while building this, with fixes | — |

## When something breaks

[TROUBLESHOOTING.md](TROUBLESHOOTING.md) covers every failure actually hit
while building this, grouped by adapter — sandbox/userns issues, network
blocks, escalation refusals, CLI flag quirks, session id capture, the junior
gate refusals, and endpoint diagnosis.
