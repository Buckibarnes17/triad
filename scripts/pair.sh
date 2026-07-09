#!/usr/bin/env bash
# pair.sh — communication channel between Claude Code (implementer),
# Codex (architect/orchestrator/reviewer) and Qwen Code (junior implementer).
# State lives in <project>/.pair/.
#
# Usage (run from the project root):
#   pair.sh init "<project brief>"     Codex intake -> requirements.md + plan.md
#   pair.sh ask "<question>"           ask the persistent Codex session, get ruling
#   pair.sh suggest "<suggestion>"     send a suggestion; Codex rules + may amend plan
#   pair.sh review [extra notes]       Codex reviews uncommitted changes vs requirements
#   pair.sh claude "<task>"            drive Claude Code headless (Codex-side entry)
#   pair.sh qwen-approve "<task>" "<note>"  record Keshav's one-time approval for a qwen task
#   pair.sh qwen "<task>"              delegate an approved basic task to Qwen Code
#   pair.sh status                     show state
#
# Codex runs in the read-only sandbox: it is OS-incapable of editing files;
# Claude writes all code. Qwen is a junior implementer for very basic tasks
# ONLY (output validation, minimal fixes) — every qwen delegation needs
# Keshav's explicit approval first (qwen-approve; one approval = one run),
# and if Codex's review finds qwen's work not up to the mark, the task goes
# back to Claude — no qwen retry loops.
# (Requires kernel.apparmor_restrict_unprivileged_userns=0, persisted in
# /etc/sysctl.d/99-codex-bwrap-userns.conf, or bwrap cannot start.)
# Exception: if Claude's usage limit is hit, Codex may take over writing —
# only with Keshav's explicit approval, in an interactive Codex session.
# Governance: Codex APPROVED != done — Keshav gives final sign-off; all commits,
# sensitive tasks, and major changes need his approval. He owns direction.
# Every exchange is appended to .pair/log.md; every entry in the shared .pair/
# files starts with agent-first attribution: "### <Agent> — <timestamp>".

set -euo pipefail

PROJECT_DIR="$(pwd)"
PAIR="$PROJECT_DIR/.pair"
STATE="$PAIR/state.json"
CODEX_MODEL="${PAIR_CODEX_MODEL:-}"        # optional: export PAIR_CODEX_MODEL=o3 etc.
CLAUDE_MODEL="${PAIR_CLAUDE_MODEL:-opus}"  # model for delegated Claude sessions
CLAUDE_EFFORT="${PAIR_CLAUDE_EFFORT:-high}" # effort for delegated Claude sessions
QWEN_BIN="${PAIR_QWEN_BIN:-/home/keshav/.local/bin/qwen}" # absolute path — qwen is not on non-login-shell PATH
QWEN_APPROVAL="${PAIR_QWEN_APPROVAL:-yolo}" # headless default mode denies edits/shell; yolo mirrors Claude's acceptEdits+Bash grant
# PAIR_DRIVER overrides who is logged as delegating; defaults per subcommand:
# 'claude' is the Codex-side entry (driver Codex), 'qwen' is normally driven by Claude

codex_model_args=()
[ -n "$CODEX_MODEL" ] && codex_model_args=(-m "$CODEX_MODEL")

die() { echo "pair.sh: $*" >&2; exit 1; }

need_state() { [ -f "$STATE" ] || die "no .pair/state.json — run: pair.sh init \"<brief>\""; }

now() { date '+%Y-%m-%d %H:%M:%S'; }

agent_header() { # agent_header <Agent> -> "### <Agent> — <timestamp>"
  printf '### %s — %s\n' "$1" "$(now)"
}

log() { # log <Agent> <text> — agent-first attribution, then the message
  printf '\n### %s — %s\n%s\n' "$1" "$(now)" "$2" >> "$PAIR/log.md"
}

state_get() { jq -r ".$1 // empty" "$STATE"; }
state_set() { # state_set <key> <value>
  local tmp; tmp=$(mktemp)
  jq --arg v "$2" ".$1 = \$v" "$STATE" > "$tmp" && mv "$tmp" "$STATE"
}

next_seq() { # next_seq <dir> -> zero-padded next file number
  local n
  n=$(ls "$1" 2>/dev/null | grep -c '^[0-9]' || true)
  printf '%03d' "$((n + 1))"
}

cmd="${1:-}"; shift || true

case "$cmd" in

init)
  BRIEF="${1:-}"; [ -n "$BRIEF" ] || die 'usage: pair.sh init "<project brief>"'
  [ -d "$PAIR" ] && die ".pair/ already exists — protocol already initialized"
  git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1 || {
    echo "pair.sh: not a git repo — initializing (codex review needs git)"
    git -C "$PROJECT_DIR" init -q
  }
  mkdir -p "$PAIR/reviews" "$PAIR/suggestions"
  # keep protocol files out of diffs/reviews
  grep -qx '\.pair/' "$PROJECT_DIR/.gitignore" 2>/dev/null || echo '.pair/' >> "$PROJECT_DIR/.gitignore"
  echo '{}' > "$STATE"
  state_set project "$PROJECT_DIR"
  state_set created "$(now)"
  state_set phase intake
  printf '# Pair log — %s\n' "$PROJECT_DIR" > "$PAIR/log.md"
  log Keshav "Project brief:
$BRIEF"

  echo "pair.sh: running Codex intake (this can take a few minutes)..."
  OUT=$(mktemp); EVENTS=$(mktemp)
  codex exec --json -s read-only -C "$PROJECT_DIR" --skip-git-repo-check \
    "${codex_model_args[@]}" -o "$OUT" - <<EOF > "$EVENTS"
You are the ARCHITECT/ORCHESTRATOR in a multi-agent workflow. Claude Code is the
IMPLEMENTER and writes all code; you MUST NOT create, edit, or delete any file —
read-only inspection and analysis only. Read the existing code
in this directory if any, then produce, exactly in this format:

=== REQUIREMENTS ===
Your full understanding of the project: goals, constraints, non-goals,
acceptance criteria. Concrete enough that an implementer who never saw the
brief could build it.

=== PLAN ===
Ordered task list T1, T2, ... Each task: what to build, files involved,
and a verifiable done-condition. Keep tasks small enough to review one at a time.

Project brief:
$BRIEF
EOF
  CODEX_ID=$(jq -r 'select(.type=="thread.started") | .thread_id' "$EVENTS" | head -1)
  [ -n "$CODEX_ID" ] || die "could not capture Codex session id (see $EVENTS)"
  state_set codex_session_id "$CODEX_ID"

  awk '/^=== REQUIREMENTS ===/{s=1;next} /^=== PLAN ===/{s=2;next}
       s==1{print > R} s==2{print > P}' R="$PAIR/requirements.md.body" P="$PAIR/plan.md.body" "$OUT"
  [ -s "$PAIR/requirements.md.body" ] || cp "$OUT" "$PAIR/requirements.md.body"   # fallback: no delimiters
  [ -s "$PAIR/plan.md.body" ] || echo "(no plan section returned — ask Codex)" > "$PAIR/plan.md.body"
  { agent_header Codex; cat "$PAIR/requirements.md.body"; } > "$PAIR/requirements.md"
  { agent_header Codex; cat "$PAIR/plan.md.body"; } > "$PAIR/plan.md"
  rm -f "$PAIR/requirements.md.body" "$PAIR/plan.md.body"
  log Codex "Intake complete. Wrote requirements.md and plan.md. Session: $CODEX_ID"
  state_set phase implement
  rm -f "$OUT" "$EVENTS"
  echo "pair.sh: intake done — read .pair/requirements.md and .pair/plan.md"
  ;;

ask|suggest)
  need_state
  MSG="${1:-}"; [ -n "$MSG" ] || die "usage: pair.sh $cmd \"<message>\""
  CODEX_ID=$(state_get codex_session_id); [ -n "$CODEX_ID" ] || die "no codex session id in state"
  OUT=$(mktemp)
  PREFIX="Question from the implementer (Claude):"
  if [ "$cmd" = suggest ]; then
    PREFIX="Suggestion from the implementer (Claude). Rule on it: ACCEPT (say how the plan changes) or REJECT (say why). If accepted, output the amended plan section in full so it can be transcribed into plan.md:"
  fi
  # NOTE: exec resume has no -s/-C flags; sandbox set via -c, cwd is project root
  codex exec resume "$CODEX_ID" -c 'sandbox_mode="read-only"' --skip-git-repo-check \
    "${codex_model_args[@]}" -o "$OUT" - <<EOF >/dev/null
Reminder: you are the architect; do not create, edit, or delete files.
$PREFIX

$MSG
EOF
  if [ "$cmd" = suggest ]; then
    N=$(next_seq "$PAIR/suggestions")
    { agent_header Claude; echo "$MSG"; echo; agent_header Codex; cat "$OUT"; } \
      > "$PAIR/suggestions/$N.md"
    log Claude "Suggestion #$N sent (see suggestions/$N.md)"
    log Codex "Ruling on suggestion #$N (see suggestions/$N.md)"
  else
    log Claude "Q: $MSG"
    log Codex "$(cat "$OUT")"
  fi
  cat "$OUT"; rm -f "$OUT"
  ;;

review)
  need_state
  NOTES="${1:-}"
  N=$(next_seq "$PAIR/reviews")
  OUTFILE="$PAIR/reviews/$N.md"
  echo "pair.sh: running Codex review of uncommitted changes..."
  agent_header Codex > "$OUTFILE"
  set +e
  # NOTE: codex review has no -C flag (reviews repo at cwd — pair.sh always runs
  # from the project root) and --uncommitted cannot be combined with a custom
  # prompt, so the prompt itself scopes the review to uncommitted changes.
  codex review "${codex_model_args[@]}" - <<EOF >> "$OUTFILE" 2>&1
You are the ARCHITECT reviewing the IMPLEMENTER's uncommitted
changes (git status/diff vs HEAD, including untracked files). Do not create,
edit, or delete any file. Review for: (1) relevance to .pair/requirements.md — flag anything
that drifts from or ignores the requirements; (2) correctness bugs;
(3) missing pieces vs the current task in .pair/plan.md.
If the work under review was implemented by Qwen (the junior implementer) and
it is not up to the mark, say so explicitly — per protocol the task then goes
back to Claude to redo; Qwen gets no retry loop.
End with a verdict line: VERDICT: APPROVED or VERDICT: CHANGES_REQUIRED
followed by a numbered findings list (file:line, severity, fix).
$NOTES
EOF
  RC=$?
  set -e
  log Codex "Review #$N written to reviews/$N.md (exit $RC)"
  echo "pair.sh: review saved -> $OUTFILE"
  tail -40 "$OUTFILE"
  ;;

claude)
  need_state
  TASK="${1:-}"; [ -n "$TASK" ] || die 'usage: pair.sh claude "<task>"'
  CLAUDE_ID=$(state_get claude_session_id)
  OUT=$(mktemp)
  PROMPT="You are the IMPLEMENTER in a pair protocol with Codex (architect).
Context lives in .pair/ (requirements.md, plan.md, log.md — read them first).
Implement the task below. Write code + run whatever verifies it. When done,
summarize what changed and what you verified. If you add anything to the
shared .pair/ files (plan.md amendments, notes), start the addition with the
attribution header '### Claude — <YYYY-MM-DD HH:MM:SS>'.

Task from Codex:
$TASK"
  # NOTE: prompt must come BEFORE --allowedTools (variadic flag would swallow
  # it as a tool name), and tools are one comma-joined arg for the same reason.
  if [ -n "$CLAUDE_ID" ]; then
    claude -p "$PROMPT" --resume "$CLAUDE_ID" --output-format json \
      --model "$CLAUDE_MODEL" --effort "$CLAUDE_EFFORT" \
      --permission-mode acceptEdits \
      --allowedTools "Bash,Edit,Write,Read,Glob,Grep,TodoWrite" \
      > "$OUT" || die "claude call failed (see $OUT)"
  else
    claude -p "$PROMPT" --output-format json \
      --model "$CLAUDE_MODEL" --effort "$CLAUDE_EFFORT" \
      --permission-mode acceptEdits \
      --allowedTools "Bash,Edit,Write,Read,Glob,Grep,TodoWrite" \
      > "$OUT" || die "claude call failed (see $OUT)"
    CLAUDE_ID=$(jq -r '.session_id // empty' "$OUT")
    [ -n "$CLAUDE_ID" ] && state_set claude_session_id "$CLAUDE_ID"
  fi
  RESULT=$(jq -r '.result // empty' "$OUT")
  log "${PAIR_DRIVER:-Codex}" "Delegated task to Claude: $TASK"
  log Claude "$RESULT"
  echo "$RESULT"; rm -f "$OUT"
  ;;

qwen-approve)
  need_state
  TASK="${1:-}"; NOTE="${2:-}"
  { [ -n "$TASK" ] && [ -n "$NOTE" ]; } || \
    die 'usage: pair.sh qwen-approve "<exact task text>" "<Keshav approval note/quote>"'
  TMP=$(mktemp)
  jq --arg t "$TASK" --arg n "$NOTE" --arg ts "$(now)" \
     '.qwen_approval = {task: $t, note: $n, approver: "Keshav", approved_at: $ts, consumed: false}' \
     "$STATE" > "$TMP" && mv "$TMP" "$STATE"
  log Keshav "Approved one qwen delegation.
Task: $TASK
Note: $NOTE"
  echo "pair.sh: qwen approval recorded (one run only) for: $TASK"
  ;;

qwen)
  need_state
  TASK="${1:-}"; [ -n "$TASK" ] || die 'usage: pair.sh qwen "<task>" (must match a recorded qwen-approve)'
  [ -x "$QWEN_BIN" ] || die "qwen binary not found/executable at $QWEN_BIN — install it or set PAIR_QWEN_BIN"
  APPROVED_TASK=$(jq -r '.qwen_approval.task // empty' "$STATE")
  # NOTE: jq's // treats false as empty, so compare explicitly
  UNCONSUMED=$(jq -r '.qwen_approval.consumed == false' "$STATE")
  [ -n "$APPROVED_TASK" ] || \
    die "no Keshav approval on record — every qwen delegation needs his explicit go-ahead first: pair.sh qwen-approve \"<task>\" \"<note>\""
  [ "$UNCONSUMED" = "true" ] || \
    die "recorded approval already consumed — one approval = one run; get a fresh go-ahead from Keshav"
  [ "$APPROVED_TASK" = "$TASK" ] || die "task text does not match the approved task.
approved: $APPROVED_TASK
given:    $TASK"
  QWEN_ID=$(state_get qwen_session_id)
  OUT=$(mktemp)
  PROMPT="You are QWEN, the JUNIOR IMPLEMENTER in a three-agent pair protocol
(Codex = architect/reviewer, Claude = primary implementer, you = junior).
Shared context lives in .pair/ (requirements.md, plan.md, log.md — read them
first). You handle ONLY the single very basic task below. Hard limits:
- no architecture or design changes, no new dependencies, no refactors
- no deleting or renaming files, nothing outside the task's scope
- if the task turns out to be bigger than described, STOP and say so —
  it will be reassigned to Claude
Do the task, run whatever verifies it, then summarize the exact files you
changed and the checks you ran. If you add anything to shared .pair/ files,
start the addition with the attribution header '### Qwen — <YYYY-MM-DD HH:MM:SS>'.
Your work will be reviewed by Codex; if it is not up to the mark the task
goes back to Claude — you get no retry.

Task (pre-approved by Keshav for you):
$TASK"
  # consume the approval BEFORE launching: one approval = one ATTEMPTED run,
  # otherwise a failed run (possibly after side effects) leaves it reusable
  TMP=$(mktemp)
  jq --arg ts "$(now)" '.qwen_approval.consumed = true | .qwen_approval.consumed_at = $ts' \
     "$STATE" > "$TMP" && mv "$TMP" "$STATE"
  echo "pair.sh: delegating to qwen ($QWEN_BIN)..."
  if [ -n "$QWEN_ID" ]; then
    "$QWEN_BIN" -r "$QWEN_ID" -p "$PROMPT" -o json --approval-mode "$QWEN_APPROVAL" > "$OUT" \
      || die "qwen call failed (see $OUT)"
  else
    "$QWEN_BIN" -p "$PROMPT" -o json --approval-mode "$QWEN_APPROVAL" > "$OUT" \
      || die "qwen call failed (see $OUT)"
  fi
  # output is a JSON event array; the final type=="result" event carries the reply
  RESULT=$(jq -r '[.[] | select(.type=="result")] | last | .result // empty' "$OUT")
  NEW_ID=$(jq -r '[.[] | select(.type=="result")] | last | .session_id // empty' "$OUT")
  [ -n "$RESULT" ] || die "could not parse qwen result — raw output kept at $OUT"
  [ -n "$NEW_ID" ] && state_set qwen_session_id "$NEW_ID"
  log "${PAIR_DRIVER:-Claude}" "Delegated approved task to Qwen: $TASK"
  log Qwen "$RESULT"
  rm -f "$OUT"
  echo "$RESULT"
  echo "pair.sh: approval consumed — next qwen task needs a fresh qwen-approve. Run pair.sh review before accepting this work."
  ;;

status)
  need_state
  jq . "$STATE"
  echo "--- last log entries:"
  tail -20 "$PAIR/log.md"
  ;;

*)
  grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -30
  exit 1
  ;;
esac
