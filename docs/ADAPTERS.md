# Writing a Triad adapter — plug any assistant CLI into the protocol

Triad never talks to an assistant directly: the engine (`scripts/pair.sh`)
dispatches every call through an **adapter** — one bash file per assistant at
`adapters/<name>.sh` (installed to `<scripts-dir>/pair-adapters/<name>.sh`).
To plug in a new CLI you write one adapter file. You do not need to read the
engine source; this contract is complete.

## Quick start

```bash
cp adapters/template.sh adapters/mycli.sh   # then edit the placeholders
bash -n adapters/mycli.sh                   # syntax
bash tests/smoke.sh                         # engine still healthy
PAIR_ARCHITECT=codex PAIR_IMPLEMENTER=mycli bash scripts/pair.sh init "<brief>"
```

## Naming

- The adapter's filename (minus `.sh`) is the agent name used everywhere:
  role env vars (`PAIR_IMPLEMENTER=mycli`), `state.json` `.roles`, installer
  `--agents`.
- Names must match `^[a-z][a-z0-9_]*$`. The engine validates this before
  sourcing the file — it is what makes the `"${name}_consult"`-style dispatch
  safe. Uppercase, dots, or dashes are rejected.

## The contract

An adapter is a bash fragment that is **sourced** by pair.sh and install.sh.
It must define, replacing `<name>` with the adapter name:

| Symbol | Kind | Required for | Purpose |
|---|---|---|---|
| `<name>_display` | string variable | always | Human-readable display name; used in prompts and `### <Agent> — <timestamp>` attribution headers |
| `<name>_check` | function | installer | Print one line of version/status info; nonzero exit = CLI not usable |
| `<name>_consult` | function | architect role | Read-only consultation: intake, questions, rulings, fallback reviews |
| `<name>_implement` | function | implementer / junior roles | Task execution: may edit files and run commands |
| `<name>_review` | function | optional | Native review command (e.g. `codex review`); without it the engine falls back to `_consult` with the diff embedded |
| `<name>_install` | function | optional | Installer hook for per-agent setup (config, skills, policy rules) |

A role is grantable only if the capability exists: architect needs
`_consult`, implementer and junior need `_implement`. The engine enforces
this (`agent 'x' cannot hold the <role> role`).

### Call signature (consult / implement / review)

```
<name>_consult  OUTFILE SESSION_ID PROMPT
<name>_implement OUTFILE SESSION_ID PROMPT
<name>_review   OUTFILE SESSION_ID PROMPT
```

- `OUTFILE` — write the assistant's **reply text** here (overwrite, not append
  — except `_review`, which appends to a file that already has an attribution
  header).
- `SESSION_ID` — empty string = start a fresh session; non-empty = resume that
  session. If the CLI cannot resume, start fresh and say so in a stderr note.
- `PROMPT` — the full prompt, passed as one argument. Pass it to your CLI
  exactly (quote it; never let the shell expand its contents).

### stdout discipline (the one rule people get wrong)

`_consult` and `_implement` must print **exactly one thing to stdout: the
session id** (the new one if the CLI minted one, otherwise the id you were
given; may be empty if the CLI is sessionless). The engine captures stdout
with `$(...)` and stores it in `state.json`. ALL other output — progress,
warnings, CLI noise — must go to stderr or be swallowed. A stray `echo`
corrupts session tracking.

Return nonzero on failure and leave whatever the CLI produced in `OUTFILE`
(the engine keeps it for diagnosis and dies with a pointer to it).

### Source-time rules

- **No side effects at source time.** The file is sourced by both pair.sh and
  install.sh before any decision is made — top-level code must only define
  variables and functions. No mktemp, no network, no writes.
- Helpers are fine; prefix them with `<name>__` (double underscore) to avoid
  collisions, e.g. `mycli__bin()`.
- Read configuration from env vars named `PAIR_<NAME>_*`
  (e.g. `PAIR_MYCLI_BIN`, `PAIR_MYCLI_MODEL`) with sane defaults inside the
  functions, not at the top level.

### `_install` hook

Called as `<name>_install KIT_DIR PAIR_SH` from install.sh, which provides
the helpers `say`, `ok`, `warn`, `confirm` (respects `--yes`) and
`render` (substitutes `__PAIR_SH__` in doc templates from
`agents/<name>/`). Return nonzero to abort the install. Keep every
machine-level change behind `confirm`.

## Semantics per role

- **Architect** (`_consult`): the engine's prompts instruct the model to be
  read-only, but enforce it too if your CLI can (sandbox flag, restricted
  tool list — see `adapters/codex.sh` `-s read-only`, `adapters/claude.sh`
  consult lane `Read,Glob,Grep`). An architect that silently edits files
  breaks the protocol's audit trail.
- **Implementer** (`_implement`): grant edit + shell capabilities
  (`adapters/claude.sh` uses `--permission-mode acceptEdits` with a Bash
  grant; `adapters/qwen.sh` uses `--approval-mode yolo`). Headless defaults
  of most CLIs deny writes — find your CLI's equivalent or tasks will
  "succeed" without changing any file.
- **Junior** (`_implement`, same function): identical mechanics; the
  human-approval gate (exact task match, consume-before-launch) is role logic
  inside the engine. **Do not** reimplement or relax it in an adapter.

## Reference implementations

- `adapters/codex.sh` — session id captured from a JSONL event stream; native
  `_review`; installer hook with sandbox/config/policy setup.
- `adapters/claude.sh` — one CLI serving two roles with different permission
  lanes; resume mints a *new* session id each call (echoed back, engine
  persists it).
- `adapters/qwen.sh` — JSON event-*array* output parsing; binary addressed by
  absolute path because it's not on non-login-shell PATH.
- `adapters/template.sh` — commented skeleton to copy.

## Testing without burning quota

`tests/mocks/` contains fake `codex`/`claude`/`qwen` binaries that emit each
CLI's real JSON shapes. For a new adapter, add a mock that mimics your CLI's
output format and a smoke case in `tests/smoke.sh` (the existing cases show
the pattern: run pair.sh against the mock, assert on `state.json` and
`$MOCK_LOG`). `bash tests/smoke.sh` must pass before you ship an adapter.
