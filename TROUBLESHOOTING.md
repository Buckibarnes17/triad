# Troubleshooting — every failure hit while building this, with the fix

These are not hypothetical: each one actually occurred during the original
setup (Ubuntu, kernel 6.8, Codex CLI 0.132.0, Claude Code 2026-07).

## 1. `bwrap: loopback: Failed RTM_NEWADDR: Operation not permitted`

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

## 2. `FailedToOpenSocket` when Codex runs `pair.sh claude`

Codex's `workspace-write` sandbox blocks ALL network by default, and the
`claude` CLI needs to reach Anthropic's API.

Fix — append to `~/.codex/config.toml`:
```toml
[sandbox_workspace_write]
network_access = true
```

## 3. Codex escalation rejected as "data exfiltration"

Codex's approvals reviewer sees "pipe repo contents to an external API" and
refuses without informed consent — it cannot know the pair protocol is
intended. Fix: pre-approve the command at the policy layer. Append to
`~/.codex/rules/default.rules` (adjust the path to where pair.sh lives):
```
prefix_rule(pattern=["bash", "/path/to/pair.sh"], decision="allow")
```
Codex must invoke it exactly as `bash /path/to/pair.sh ...` (not wrapped in
`bash -lc "..."`) or the prefix won't match — the installed AGENTS.md says so.

## 4. `Error: Input must be provided either through stdin or as a prompt argument`

From `pair.sh claude`. Cause: `claude`'s `--allowedTools` flag is VARIADIC —
if the prompt is placed after it, the prompt is swallowed as a tool name.
Already fixed in this kit's pair.sh (prompt precedes the flags; tools are one
comma-joined argument). If you edit pair.sh, keep that ordering.

## 5. `codex review` flag quirks

- No `-C` flag — it reviews the repo at the *current directory* (pair.sh always
  runs it from the project root).
- `--uncommitted` cannot be combined with a custom prompt — the kit scopes the
  review through the prompt text instead.
- It requires a git repository — `pair.sh init` runs `git init` if needed.

## 6. `codex exec resume` flag quirks

No `-s`/`-C` flags (unlike plain `exec`). Sandbox is set via
`-c 'sandbox_mode="read-only"'`; cwd comes from where you run it.

## 7. Claude Code session can't run pair.sh without prompting

In interactive Claude sessions, Bash calls to pair.sh may need per-session
approval depending on permission mode. Optional permanent allow — add to the
project's `.claude/settings.json`:
```json
{ "permissions": { "allow": ["Bash(bash /path/to/pair.sh *)"] } }
```
Note: automation harnesses may (correctly) refuse to launch sandbox-disabled
agents or edit another agent's security config from an autonomous session —
those specific steps are yours to run by hand; the installer prints them.

## 8. Codex session id capture

`codex exec --json` emits JSONL; the id is the first
`{"type":"thread.started","thread_id":"..."}` event. `--ephemeral` runs are NOT
resumable — pair.sh only uses it never; don't add it to init.

## 9. Claude session id capture

`claude -p --output-format json` returns `{"session_id": "...", "result": "..."}`.
Resume with `claude -p "<prompt>" --resume <session_id>`.

## 10. `pair.sh qwen` says "qwen binary not found/executable"

The qwen CLI is typically installed user-local (`npm install -g --prefix
~/.local @qwen-code/qwen-code`) and `~/.local/bin` is NOT on the PATH of
non-login shells — which is why pair.sh calls it by absolute path. Default is
`/home/keshav/.local/bin/qwen`; if yours lives elsewhere, set
`PAIR_QWEN_BIN=/path/to/qwen`. Verify with:
`/home/keshav/.local/bin/qwen --version` (kit built against 0.19.8).

## 11. Qwen replies "write_file and run_shell_command are denied"

Headless qwen (`-p`) runs in `--approval-mode default`, which denies edit and
shell tools — the task "succeeds" but no files change. pair.sh passes
`--approval-mode yolo` by default (mirrors the Claude delegation's
acceptEdits+Bash grant); override with `PAIR_QWEN_APPROVAL=auto-edit` etc.
Note `--approval-mode` is hidden from `qwen --help` but accepted
(choices: plan, default, auto-edit, auto, yolo).

## 12. Qwen JSON parsing / session resume

`qwen -p ... -o json` emits a JSON *array* of events (not JSONL); the final
`{"type":"result", ...}` event carries `session_id` and `result`. pair.sh
extracts both with jq, persists `qwen_session_id`, and resumes with
`qwen -r <id> -p ...`. Qwen has no `-C` flag — cwd is the project root because
pair.sh runs from there.

## 13. Qwen configured but hangs / errors on every call (endpoint down)

Qwen here is NOT a cloud service: `~/.qwen/settings.json` points it at a local
vLLM endpoint — model `qwen3-6-27b` at `http://192.168.200.46:11449/v1`
(auth type `openai` with a dummy key). If the vLLM container on that host is
down, every `pair.sh qwen` call fails or hangs regardless of approvals.
Diagnose:
```bash
curl -s http://192.168.200.46:11449/v1/models | jq -r '.data[].id'   # expect qwen3-6-27b
jq '.modelProviders' ~/.qwen/settings.json                            # expect matching baseUrl
/home/keshav/.local/bin/qwen --version                                # CLI itself OK? (0.19.8)
```
No API cost, but it is a small model — which is exactly why the protocol
restricts it to junior tasks.

## 14. `pair.sh qwen` refuses: "no Keshav approval on record" / "already consumed"

Working as designed, not a bug. Every qwen delegation needs a fresh recorded
approval: `pair.sh qwen-approve "<exact task>" "<note>"` then `pair.sh qwen
"<byte-identical task text>"`. The approval is consumed at launch (even if the
run fails), so a second run always needs a new approval. Task text mismatch →
refusal that prints both strings.

## 15. Delegated Claude call returns "You've hit your session limit"

The call succeeded mechanically — the JSON envelope comes back with the limit
message as `result` and a reset time. `pair.sh` treats it as a normal reply, so
check `result` before assuming the task ran. Options: wait for the reset,
dial cost down for the run (`PAIR_CLAUDE_MODEL=sonnet PAIR_CLAUDE_EFFORT=medium`),
or — per governance — ask the human for approval before Codex takes over
writing. Delegated sessions default to `--model opus --effort high`, which
burns quota fastest.
