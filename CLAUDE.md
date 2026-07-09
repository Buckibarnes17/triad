# pair-kit

## Environment & commands

Pure bash + jq — no python, no build. Test everything offline (no real agent
CLIs, no quota) with:

```bash
bash tests/smoke.sh        # full end-to-end run against tests/mocks/{codex,claude,qwen}
bash -n scripts/pair.sh    # quick syntax check (smoke.sh does this too)
```

This box only has `claude` — never try to run real `codex`/`qwen` here; the
mocks are the verification story. `./install.sh` is for target machines, not
this one.

## What this does

Role-based multi-CLI pair-programming protocol. Three fixed roles — architect
(intake/rulings/reviews, read-only), implementer (writes all code), junior
(optional, human-gated one-approval-one-run lane) — each filled by any agent
that has an adapter. Defaults: codex/claude/qwen. Shared state per project in
`.pair/` (state.json, requirements.md, plan.md, reviews/, suggestions/, log.md).

## Architecture

- `scripts/pair.sh` — the engine. Role-named subcommands (`init ask suggest
  review implement junior-approve junior status`) + legacy aliases
  (`claude`→implement, `qwen`→junior). Roles read from env
  (`PAIR_ARCHITECT/IMPLEMENTER/JUNIOR`) only at `init`, then persisted in
  `.pair/state.json` `.roles` — state wins afterwards. Sessions are
  role-keyed with the agent recorded: `.sessions.<role> = {agent, id}`;
  a role reassigned in state.json discards its stale session automatically.
  `migrate_state()` upgrades pre-adapter state.json (`codex_session_id` etc.)
  in place. The human is `PAIR_HUMAN` → git user.name → `$USER`.
- `adapters/<name>.sh` — one per assistant, sourced by pair.sh and install.sh.
  Contract: `<name>_display` (var), `<name>_check`, `<name>_consult` /
  `<name>_implement` `OUTFILE SESSION_ID PROMPT` (reply → OUTFILE, **stdout =
  session id only**), optional `<name>_review` (native review; only codex) and
  `<name>_install` (install hook). Names are regex-validated
  (`^[a-z][a-z0-9_]*$`) before sourcing — that's what makes the
  `"${agent}_consult"` dispatch safe; no eval anywhere.
- `install.sh` — generic: prereqs (jq, git), copies pair.sh +
  `adapters/*.sh` → `<scripts-dir>/pair-adapters/`, then loops enabled agents
  running `_check` + `_install`. Per-agent quirks (codex bwrap check,
  config.toml, execpolicy; claude CLAUDE.md append) live in the adapters.
- `agents/<name>/` — installable doc assets (claude skill + CLAUDE.md section,
  codex AGENTS.md section + pair-handoff skill). `__PAIR_SH__` placeholders
  are substituted by install.sh's `render()`.
- `tests/mocks/` — fake codex/claude/qwen emitting each CLI's real JSON shapes
  (codex: JSONL `thread.started` + `-o` file; claude: single JSON object;
  qwen: JSON event *array*), logging argv/prompts to `$MOCK_LOG`.

Gotchas:

- Prompts are built as quoted string variables, never unquoted heredocs — a
  brief containing `$(...)` must reach the agent literally (smoke test 2
  regression-guards this).
- claude CLI: prompt must precede `--allowedTools` (variadic flag swallows
  it); kept as a NOTE in `adapters/claude.sh`. Headless `--resume` mints a new
  session id — the adapter echoes it back and pair.sh persists it every call.
- codex CLI: `exec resume` has no `-s`/`-C` (sandbox via
  `-c 'sandbox_mode="read-only"'`); `codex review` has no `-C` and
  `--uncommitted` conflicts with a custom prompt.
- Architects without a native `_review` get the generic fallback: consult the
  persistent session with `git status`/untracked/`git diff HEAD` embedded in
  the prompt (guarded for repos with no commits yet).
- The junior approval gate (exact task match, consume-before-launch) is role
  logic in pair.sh, NOT in the qwen adapter — don't move it into an adapter.
- Adapter files must be side-effect-free at source time; empty-array
  `"${arr[@]}"` expansion assumes bash ≥ 4.4; `readlink -f` assumes Linux.
