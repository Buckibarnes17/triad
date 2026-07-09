# Troubleshooting — every failure hit while building this, with the fix

These are not hypothetical: each one actually occurred during the original
setup (Ubuntu, kernel 6.8, Codex CLI 0.132.0, Claude Code 2026-07). Items are
grouped by the adapter they belong to; they apply whenever that agent holds a
role, whichever role it is.

## Engine / any lineup

### 1. `pair.sh: unknown agent '<name>' — no adapter at .../<name>.sh`

The role assignment (`PAIR_ARCHITECT`/`PAIR_IMPLEMENTER`/`PAIR_JUNIOR` at init,
or `.roles` in `.pair/state.json` afterwards) names an agent with no adapter
file. Adapters are searched in `PAIR_ADAPTERS_DIR`, else `pair-adapters/` next
to the installed pair.sh, else `../adapters` relative to a repo checkout.
Write one (see README "Adding an assistant") or fix the name. A related
refusal, `agent '<x>' cannot hold the <role> role`, means the adapter exists
but lacks the required function (`_consult` for architect, `_implement` for
implementer/junior).

### 2. Review looks different: prompt contains the whole git diff

Working as designed. Only agents with a native review command (codex) define
`<name>_review`; for any other architect, `pair.sh review` falls back to
resuming the architect session with the review prompt plus the embedded
`git status` / untracked list / `git diff HEAD`. Note: a very large diff can
blow the model's context window — review per task, not per milestone.

### 3. Roles seem to ignore `PAIR_ARCHITECT` etc.

Role env vars are read once, at `pair.sh init`, then persisted in
`.pair/state.json`. Afterwards the state wins (pair.sh prints a note if the
env disagrees). To reassign mid-project, edit `.roles` in state.json — the
reassigned role's stale session is discarded automatically on the next call.

## Codex adapter

### 4. `bwrap: loopback: Failed RTM_NEWADDR: Operation not permitted`

Every Codex sandboxed command fails; headless `codex exec`/`review` return
"cannot inspect files". Cause: the kernel blocks unprivileged user namespaces
(Ubuntu ships `kernel.apparmor_restrict_unprivileged_userns=1`), so bubblewrap
cannot start. Interactive Codex hides this by escalating with approval;
headless runs (`approval: never`) just fail.

Fix (needs sudo, survives reboot):
```bash
sudo sysctl kernel.apparmor_restrict_unprivileged_userns=0
echo 'kernel.apparmor_restrict_unprivileged_userns = 0' | sudo tee /etc/sysctl.d/99-codex-bwrap-userns.conf
```
Verify: `codex sandbox linux -- ls /tmp` lists files.

### 5. `FailedToOpenSocket` when Codex runs `pair.sh implement`

Codex's `workspace-write` sandbox blocks ALL network by default, and the
implementer's CLI needs to reach its API.

Fix — append to `~/.codex/config.toml`:
```toml
[sandbox_workspace_write]
network_access = true
```

### 6. Codex escalation rejected as "data exfiltration"

Codex's approvals reviewer sees "pipe repo contents to an external API" and
refuses without informed consent — it cannot know the Triad protocol is
intended. Fix: pre-approve the command at the policy layer. Append to
`~/.codex/rules/default.rules` (adjust the path to where pair.sh lives):
```
prefix_rule(pattern=["bash", "/path/to/pair.sh"], decision="allow")
```
Codex must invoke it exactly as `bash /path/to/pair.sh ...` (not wrapped in
`bash -lc "..."`) or the prefix won't match — the installed AGENTS.md says so.

### 7. `codex review` flag quirks

- No `-C` flag — it reviews the repo at the *current directory* (pair.sh always
  runs it from the project root).
- `--uncommitted` cannot be combined with a custom prompt — the kit scopes the
  review through the prompt text instead.
- It requires a git repository — `pair.sh init` runs `git init` if needed.

### 8. `codex exec resume` flag quirks

No `-s`/`-C` flags (unlike plain `exec`). Sandbox is set via
`-c 'sandbox_mode="read-only"'`; cwd comes from where you run it.

### 9. Codex session id capture

`codex exec --json` emits JSONL; the id is the first
`{"type":"thread.started","thread_id":"..."}` event (the adapter extracts it).
`--ephemeral` runs are NOT resumable — don't add it to the adapter.

## Claude adapter

### 10. `Error: Input must be provided either through stdin or as a prompt argument`

Cause: `claude`'s `--allowedTools` flag is VARIADIC — if the prompt is placed
after it, the prompt is swallowed as a tool name. Already fixed in
`adapters/claude.sh` (prompt precedes the flags; tools are one comma-joined
argument). If you edit the adapter, keep that ordering.

### 11. Claude Code session can't run pair.sh without prompting

In interactive Claude sessions, Bash calls to pair.sh may need per-session
approval depending on permission mode. Optional permanent allow — add to the
project's `.claude/settings.json`:
```json
{ "permissions": { "allow": ["Bash(bash /path/to/pair.sh *)"] } }
```
Note: automation harnesses may (correctly) refuse to launch sandbox-disabled
agents or edit another agent's security config from an autonomous session —
those specific steps are yours to run by hand; the installer prints them.

### 12. Claude session id capture

`claude -p --output-format json` returns `{"session_id": "...", "result": "..."}`.
Resume with `claude -p "<prompt>" --resume <session_id>`. Each headless resume
mints a NEW session id — the adapter echoes it back and pair.sh persists it,
so always go through pair.sh rather than resuming an old id by hand.

### 13. Delegated Claude call returns "You've hit your session limit"

The call succeeded mechanically — the JSON envelope comes back with the limit
message as `result` and a reset time. `pair.sh` treats it as a normal reply, so
check `result` before assuming the task ran. Options: wait for the reset,
dial cost down for the run (`PAIR_CLAUDE_MODEL=sonnet PAIR_CLAUDE_EFFORT=medium`),
or — per governance — ask the human for approval before the architect takes
over writing. Delegated sessions default to `--model opus --effort high`,
which burns quota fastest.

## Qwen adapter

### 14. `pair.sh junior` says "qwen binary not found/executable"

The qwen CLI is typically installed user-local (`npm install -g --prefix
~/.local @qwen-code/qwen-code`) and `~/.local/bin` is NOT on the PATH of
non-login shells — which is why the adapter calls it by absolute path. Default
is `~/.local/bin/qwen`; if yours lives elsewhere, set
`PAIR_QWEN_BIN=/path/to/qwen`. Verify with `$PAIR_QWEN_BIN --version`
(kit built against 0.19.8).

### 15. Qwen replies "write_file and run_shell_command are denied"

Headless qwen (`-p`) runs in `--approval-mode default`, which denies edit and
shell tools — the task "succeeds" but no files change. The adapter passes
`--approval-mode yolo` by default (mirrors the Claude delegation's
acceptEdits+Bash grant); override with `PAIR_QWEN_APPROVAL=auto-edit` etc.
Note `--approval-mode` is hidden from `qwen --help` but accepted
(choices: plan, default, auto-edit, auto, yolo).

### 16. Qwen JSON parsing / session resume

`qwen -p ... -o json` emits a JSON *array* of events (not JSONL); the final
`{"type":"result", ...}` event carries `session_id` and `result`. The adapter
extracts both with jq; pair.sh persists the id and resumes with
`qwen -r <id> -p ...`. Qwen has no `-C` flag — cwd is the project root because
pair.sh runs from there.

### 17. Qwen configured but hangs / errors on every call (endpoint down)

Qwen in the original setup is NOT a cloud service: `~/.qwen/settings.json`
points it at a local vLLM endpoint (auth type `openai` with a dummy key). If
that endpoint is down, every `pair.sh junior` call fails or hangs regardless
of approvals. Diagnose:
```bash
curl -s <baseUrl>/models | jq -r '.data[].id'   # expect your served model
jq '.modelProviders' ~/.qwen/settings.json      # expect matching baseUrl
"$PAIR_QWEN_BIN" --version                      # CLI itself OK?
```
No API cost, but it is a small model — which is exactly why the protocol
restricts it to junior tasks.

## Junior gate (engine, any junior agent)

### 18. `pair.sh junior` refuses: "no approval ... on record" / "already consumed"

Working as designed, not a bug. Every junior delegation needs a fresh recorded
approval: `pair.sh junior-approve "<exact task>" "<note>"` then `pair.sh junior
"<byte-identical task text>"`. The approval is consumed at launch (even if the
run fails), so a second run always needs a new approval. Task text mismatch →
refusal that prints both strings.
