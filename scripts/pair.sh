#!/usr/bin/env bash
# pair.sh — Triad Protocol engine: communication between a fixed set of ROLES,
# each filled by a pluggable assistant CLI (adapters/<agent>.sh):
#   architect   — intake, rulings, reviews; read-only, never edits files
#   implementer — writes all non-trivial code
#   junior      — optional lane for very basic tasks, human-gated
# Defaults: architect=codex, implementer=claude, junior=qwen. Override AT INIT
# with PAIR_ARCHITECT / PAIR_IMPLEMENTER / PAIR_JUNIOR (PAIR_JUNIOR= empty
# disables the junior lane). Roles persist in .pair/state.json — after init,
# edit .roles there to reassign. State lives in <project>/.pair/.
#
# Usage (run from the project root):
#   pair.sh init "<project brief>"     architect intake -> requirements.md + plan.md
#   pair.sh ask "<question>"           ask the persistent architect session, get ruling
#   pair.sh suggest "<suggestion>"     send a suggestion; architect rules + may amend plan
#   pair.sh review [extra notes]       architect reviews uncommitted changes vs requirements
#   pair.sh implement "<task>"         drive the implementer headless (architect-side entry)
#   pair.sh junior-approve "<task>" "<note>"  record the human's one-time approval for a junior task
#   pair.sh junior "<task>"            delegate an approved basic task to the junior
#   pair.sh status                     show state
# Legacy aliases: claude -> implement, qwen -> junior, qwen-approve -> junior-approve.
#
# The architect runs read-only: it must not create, edit, or delete files; the
# implementer writes all code. The junior handles very basic tasks ONLY
# (output validation, minimal fixes) — every junior delegation needs the
# human's explicit approval first (junior-approve; one approval = one run),
# and if the architect's review finds the junior's work not up to the mark,
# the task goes back to the implementer — no junior retry loops.
# Exception: if the implementer's usage limit is hit, the architect may take
# over writing — only with the human's explicit approval, interactively.
# Governance: architect APPROVED != done — the human gives final sign-off; all
# commits, sensitive tasks, and major changes need their approval.
# Every exchange is appended to .pair/log.md; every entry in the shared .pair/
# files starts with agent-first attribution: "### <Agent> — <timestamp>".
#
# Config: PAIR_HUMAN (default: git config user.name, then $USER),
# PAIR_ADAPTERS_DIR, PAIR_DRIVER (who is logged as delegating; defaults:
# implement -> the architect, junior -> the implementer), plus whatever env
# each adapter documents (PAIR_CODEX_MODEL, PAIR_CLAUDE_MODEL/EFFORT,
# PAIR_QWEN_BIN/APPROVAL, ...).

set -euo pipefail

PROJECT_DIR="$(pwd)"
PAIR="$PROJECT_DIR/.pair"
STATE="$PAIR/state.json"

die() { echo "pair.sh: $*" >&2; exit 1; }

# ── adapter loading ──────────────────────────────────────────────────────────
# adapters live next to the installed pair.sh (pair-adapters/) or, when run
# from a repo checkout, in ../adapters; override with PAIR_ADAPTERS_DIR
SELF_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"   # readlink -f: Linux (macOS: brew coreutils)
ADAPTER_DIR="${PAIR_ADAPTERS_DIR:-}"
if [ -z "$ADAPTER_DIR" ]; then
  for d in "$SELF_DIR/pair-adapters" "$SELF_DIR/../adapters"; do
    if [ -d "$d" ]; then ADAPTER_DIR="$d"; break; fi
  done
fi
[ -n "$ADAPTER_DIR" ] || die "no adapter directory found next to $SELF_DIR — set PAIR_ADAPTERS_DIR"

load_agent() { # load_agent <name> — validate the name, then source adapters/<name>.sh
  local a="$1" f v
  # the regex gate is what makes "${a}_consult"-style dispatch safe — never relax it
  [[ "$a" =~ ^[a-z][a-z0-9_]*$ ]] || die "invalid agent name '$a' (want ^[a-z][a-z0-9_]*$)"
  v="${a}_display"
  if [ -n "${!v:-}" ]; then return 0; fi   # already loaded
  f="$ADAPTER_DIR/$a.sh"
  [ -f "$f" ] || die "unknown agent '$a' — no adapter at $f"
  # shellcheck source=/dev/null
  . "$f"
  [ -n "${!v:-}" ] || die "adapter $f does not define ${a}_display"
}

need_cap() { # need_cap <agent> <verb> <role> — role capability check
  declare -F "${1}_${2}" >/dev/null || die "agent '$1' cannot hold the $3 role (adapter defines no ${1}_${2})"
}

display_of() { local v="${1}_display"; printf '%s' "${!v}"; }

# ── state helpers ────────────────────────────────────────────────────────────
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

default_human() {
  local h="${PAIR_HUMAN:-}"
  if [ -z "$h" ]; then h=$(git config user.name 2>/dev/null || true); fi
  if [ -z "$h" ]; then h="${USER:-human}"; fi
  printf '%s' "$h"
}

migrate_state() { # legacy (hardcoded codex/claude/qwen) state.json -> role-keyed schema
  if jq -e '.roles' "$STATE" >/dev/null 2>&1; then return 0; fi
  echo "pair.sh: migrating legacy state.json to the role-keyed schema" >&2
  local tmp; tmp=$(mktemp)
  jq --arg human "$(default_human)" '
    .roles = {architect: "codex", implementer: "claude", junior: "qwen"}
    | .human = (.human // $human)
    | .sessions = ((.sessions // {})
        + (if .codex_session_id  then {architect:   {agent: "codex",  id: .codex_session_id}}  else {} end)
        + (if .claude_session_id then {implementer: {agent: "claude", id: .claude_session_id}} else {} end)
        + (if .qwen_session_id   then {junior:      {agent: "qwen",   id: .qwen_session_id}}   else {} end))
    | (if .qwen_approval then .junior_approval = .qwen_approval else . end)
    | del(.codex_session_id, .claude_session_id, .qwen_session_id, .qwen_approval)
  ' "$STATE" > "$tmp" && mv "$tmp" "$STATE"
}

session_get() { # session_get <role> -> id; empty (fresh) if the role was reassigned
  local role="$1" have want
  have=$(jq -r ".sessions.$role.agent // empty" "$STATE")
  want=$(jq -r ".roles.$role // empty" "$STATE")
  if [ -n "$have" ] && [ "$have" != "$want" ]; then
    echo "pair.sh: note: $role reassigned ($have -> $want) — starting a fresh session" >&2
    return 0
  fi
  jq -r ".sessions.$role.id // empty" "$STATE"
}

session_set() { # session_set <role> <agent> <id>
  local tmp; tmp=$(mktemp)
  jq --arg r "$1" --arg a "$2" --arg i "$3" '.sessions[$r] = {agent: $a, id: $i}' \
     "$STATE" > "$tmp" && mv "$tmp" "$STATE"
}

next_seq() { # next_seq <dir> -> zero-padded next file number
  local n
  n=$(ls "$1" 2>/dev/null | grep -c '^[0-9]' || true)
  printf '%03d' "$((n + 1))"
}

untracked_diff_context() {
  local f tmp rc
  while IFS= read -r -d '' f; do
    printf '\n--- untracked: %s ---\n' "$f"
    if [ -f "$f" ]; then
      tmp=$(mktemp)
      if git diff --no-index -- /dev/null "$f" > "$tmp" 2>/dev/null; then
        cat "$tmp"
      else
        rc=$?
        if [ "$rc" -eq 1 ]; then
          cat "$tmp"
        else
          printf '(could not render diff for %s; git diff --no-index exited %s)\n' "$f" "$rc"
        fi
      fi
      rm -f "$tmp"
    else
      printf '(not a regular file)\n'
    fi
  done < <(git ls-files -z --others --exclude-standard)
}

warn_role_env() { # warn_role_env <envvar> <state value>
  local v="${!1-}"
  if [ -n "$v" ] && [ "$v" != "$2" ]; then
    echo "pair.sh: note: $1=$v ignored — roles are fixed in .pair/state.json (edit .roles there to reassign)" >&2
  fi
}

resolve_roles() { # after need_state+migrate_state: read roles/human, load adapters
  ARCH=$(jq -r '.roles.architect // empty' "$STATE")
  IMPL=$(jq -r '.roles.implementer // empty' "$STATE")
  JR=$(jq -r '.roles.junior // empty' "$STATE")
  HUMAN=$(jq -r '.human // empty' "$STATE")
  if [ -z "$HUMAN" ]; then HUMAN=$(default_human); fi
  { [ -n "$ARCH" ] && [ -n "$IMPL" ]; } || die "state.json has no architect/implementer roles — corrupt state?"
  warn_role_env PAIR_ARCHITECT "$ARCH"
  warn_role_env PAIR_IMPLEMENTER "$IMPL"
  warn_role_env PAIR_JUNIOR "$JR"
  load_agent "$ARCH"; need_cap "$ARCH" consult architect
  load_agent "$IMPL"; need_cap "$IMPL" implement implementer
  JR_NAME=""
  if [ -n "$JR" ]; then
    load_agent "$JR"; need_cap "$JR" implement junior
    JR_NAME=$(display_of "$JR")
  fi
  ARCH_NAME=$(display_of "$ARCH")
  IMPL_NAME=$(display_of "$IMPL")
}

cmd="${1:-}"; shift || true

# legacy aliases from the hardcoded era — subcommands are role-named now
case "$cmd" in
  claude)       echo "pair.sh: note: 'claude' is a legacy alias for 'implement'" >&2; cmd=implement ;;
  qwen)         echo "pair.sh: note: 'qwen' is a legacy alias for 'junior'" >&2; cmd=junior ;;
  qwen-approve) echo "pair.sh: note: 'qwen-approve' is a legacy alias for 'junior-approve'" >&2; cmd=junior-approve ;;
esac

case "$cmd" in

init)
  BRIEF="${1:-}"; [ -n "$BRIEF" ] || die 'usage: pair.sh init "<project brief>"'
  [ -d "$PAIR" ] && die ".pair/ already exists — protocol already initialized"
  ARCH="${PAIR_ARCHITECT:-codex}"
  IMPL="${PAIR_IMPLEMENTER:-claude}"
  JR="${PAIR_JUNIOR-qwen}"   # PAIR_JUNIOR= (set empty) disables the junior lane
  HUMAN=$(default_human)
  load_agent "$ARCH"; need_cap "$ARCH" consult architect
  load_agent "$IMPL"; need_cap "$IMPL" implement implementer
  JR_NAME=""
  if [ -n "$JR" ]; then
    load_agent "$JR"; need_cap "$JR" implement junior
    JR_NAME=$(display_of "$JR")
  fi
  ARCH_NAME=$(display_of "$ARCH"); IMPL_NAME=$(display_of "$IMPL")

  git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1 || {
    echo "pair.sh: not a git repo — initializing (reviews need git)"
    git -C "$PROJECT_DIR" init -q
  }
  mkdir -p "$PAIR/reviews" "$PAIR/suggestions"
  # keep protocol files out of diffs/reviews
  grep -qx '\.pair/' "$PROJECT_DIR/.gitignore" 2>/dev/null || echo '.pair/' >> "$PROJECT_DIR/.gitignore"
  echo '{}' > "$STATE"
  state_set project "$PROJECT_DIR"
  state_set created "$(now)"
  state_set phase intake
  state_set human "$HUMAN"
  TMP=$(mktemp)
  jq --arg a "$ARCH" --arg i "$IMPL" --arg j "$JR" \
     '.roles = {architect: $a, implementer: $i, junior: $j}' "$STATE" > "$TMP" && mv "$TMP" "$STATE"
  printf '# Pair log — %s\n' "$PROJECT_DIR" > "$PAIR/log.md"
  log "$HUMAN" "Project brief:
$BRIEF"

  echo "pair.sh: running $ARCH_NAME intake (this can take a few minutes)..."
  OUT=$(mktemp)
  # prompts are plain string variables, never unquoted heredocs — a brief
  # containing $(...) or backticks must reach the agent literally
  PROMPT="You are the ARCHITECT/ORCHESTRATOR ($ARCH_NAME) in a multi-agent workflow.
$IMPL_NAME is the IMPLEMENTER and writes all code; you MUST NOT create, edit,
or delete any file — read-only inspection and analysis only. Read the existing
code in this directory if any, then produce, exactly in this format:

=== REQUIREMENTS ===
Your full understanding of the project: goals, constraints, non-goals,
acceptance criteria. Concrete enough that an implementer who never saw the
brief could build it.

=== PLAN ===
Ordered task list T1, T2, ... Each task: what to build, files involved,
and a verifiable done-condition. Keep tasks small enough to review one at a time.

Project brief:
$BRIEF"
  SID=$("${ARCH}_consult" "$OUT" "" "$PROMPT") || die "architect intake failed (output kept at $OUT)"
  [ -n "$SID" ] || die "architect adapter returned no session id"
  session_set architect "$ARCH" "$SID"

  awk '/^=== REQUIREMENTS ===/{s=1;next} /^=== PLAN ===/{s=2;next}
       s==1{print > R} s==2{print > P}' R="$PAIR/requirements.md.body" P="$PAIR/plan.md.body" "$OUT"
  [ -s "$PAIR/requirements.md.body" ] || cp "$OUT" "$PAIR/requirements.md.body"   # fallback: no delimiters
  [ -s "$PAIR/plan.md.body" ] || echo "(no plan section returned — ask the architect)" > "$PAIR/plan.md.body"
  { agent_header "$ARCH_NAME"; cat "$PAIR/requirements.md.body"; } > "$PAIR/requirements.md"
  { agent_header "$ARCH_NAME"; cat "$PAIR/plan.md.body"; } > "$PAIR/plan.md"
  rm -f "$PAIR/requirements.md.body" "$PAIR/plan.md.body"
  log "$ARCH_NAME" "Intake complete. Wrote requirements.md and plan.md. Session: $SID"
  state_set phase implement
  rm -f "$OUT"
  echo "pair.sh: intake done — read .pair/requirements.md and .pair/plan.md"
  echo "pair.sh: roles: architect=$ARCH implementer=$IMPL junior=${JR:-'(disabled)'}"
  ;;

ask|suggest)
  need_state; migrate_state; resolve_roles
  MSG="${1:-}"; [ -n "$MSG" ] || die "usage: pair.sh $cmd \"<message>\""
  SID=$(session_get architect)
  OUT=$(mktemp)
  PREFIX="Question from the implementer ($IMPL_NAME):"
  if [ "$cmd" = suggest ]; then
    PREFIX="Suggestion from the implementer ($IMPL_NAME). Rule on it: ACCEPT (say how the plan changes) or REJECT (say why). If accepted, output the amended plan section in full so it can be transcribed into plan.md:"
  fi
  PROMPT="Reminder: you are the architect ($ARCH_NAME); do not create, edit, or delete files.
Shared context lives in .pair/ (requirements.md, plan.md, log.md).
$PREFIX

$MSG"
  NEW_SID=$("${ARCH}_consult" "$OUT" "$SID" "$PROMPT") || die "architect call failed (output kept at $OUT)"
  if [ -n "$NEW_SID" ]; then session_set architect "$ARCH" "$NEW_SID"; fi
  if [ "$cmd" = suggest ]; then
    N=$(next_seq "$PAIR/suggestions")
    { agent_header "$IMPL_NAME"; echo "$MSG"; echo; agent_header "$ARCH_NAME"; cat "$OUT"; } \
      > "$PAIR/suggestions/$N.md"
    log "$IMPL_NAME" "Suggestion #$N sent (see suggestions/$N.md)"
    log "$ARCH_NAME" "Ruling on suggestion #$N (see suggestions/$N.md)"
  else
    log "$IMPL_NAME" "Q: $MSG"
    log "$ARCH_NAME" "$(cat "$OUT")"
  fi
  cat "$OUT"; rm -f "$OUT"
  ;;

review)
  need_state; migrate_state; resolve_roles
  NOTES="${1:-}"
  N=$(next_seq "$PAIR/reviews")
  OUTFILE="$PAIR/reviews/$N.md"
  REVIEW_PROMPT="You are the ARCHITECT ($ARCH_NAME) reviewing the IMPLEMENTER's uncommitted
changes (git status/diff vs HEAD, including untracked files). Do not create,
edit, or delete any file. Review for: (1) relevance to .pair/requirements.md — flag anything
that drifts from or ignores the requirements; (2) correctness bugs;
(3) missing pieces vs the current task in .pair/plan.md."
  if [ -n "$JR_NAME" ]; then
    REVIEW_PROMPT="$REVIEW_PROMPT
If the work under review was implemented by $JR_NAME (the junior implementer) and
it is not up to the mark, say so explicitly — per protocol the task then goes
back to $IMPL_NAME to redo; $JR_NAME gets no retry loop."
  fi
  REVIEW_PROMPT="$REVIEW_PROMPT
End with a verdict line: VERDICT: APPROVED or VERDICT: CHANGES_REQUIRED
followed by a numbered findings list (file:line, severity, fix).
$NOTES"
  echo "pair.sh: running $ARCH_NAME review of uncommitted changes..."
  agent_header "$ARCH_NAME" > "$OUTFILE"
  RC=0
  if declare -F "${ARCH}_review" >/dev/null; then
    "${ARCH}_review" "$OUTFILE" "$(session_get architect)" "$REVIEW_PROMPT" || RC=$?
  else
    # generic fallback: no native review command — consult the architect
    # session with the diff embedded (a read-only consult may not be able to
    # run git itself). NOTE: a very large diff may blow the context window.
    SID=$(session_get architect)
    if git rev-parse HEAD >/dev/null 2>&1; then
      DIFF=$(git diff HEAD)
    else
      DIFF="(no commits yet — every file is new/untracked)"
    fi
    CTX="=== git status ===
$(git status --short)
=== untracked files ===
$(git ls-files --others --exclude-standard)
=== untracked file contents ===
$(untracked_diff_context)
=== git diff HEAD ===
$DIFF"
    TMP=$(mktemp)
    NEW_SID=$("${ARCH}_consult" "$TMP" "$SID" "$REVIEW_PROMPT

$CTX") || RC=$?
    cat "$TMP" >> "$OUTFILE"; rm -f "$TMP"
    if [ -n "${NEW_SID:-}" ]; then session_set architect "$ARCH" "$NEW_SID"; fi
  fi
  log "$ARCH_NAME" "Review #$N written to reviews/$N.md (exit $RC)"
  echo "pair.sh: review saved -> $OUTFILE"
  tail -40 "$OUTFILE"
  ;;

implement)
  need_state; migrate_state; resolve_roles
  TASK="${1:-}"; [ -n "$TASK" ] || die 'usage: pair.sh implement "<task>"'
  SID=$(session_get implementer)
  OUT=$(mktemp)
  PROMPT="You are the IMPLEMENTER ($IMPL_NAME) in a Triad protocol with $ARCH_NAME (architect).
Context lives in .pair/ (requirements.md, plan.md, log.md — read them first).
Implement the task below. Write code + run whatever verifies it. When done,
summarize what changed and what you verified. If you add anything to the
shared .pair/ files (plan.md amendments, notes), start the addition with the
attribution header '### $IMPL_NAME — <YYYY-MM-DD HH:MM:SS>'.

Task from the architect ($ARCH_NAME):
$TASK"
  NEW_SID=$("${IMPL}_implement" "$OUT" "$SID" "$PROMPT") || die "implementer call failed (output kept at $OUT)"
  if [ -n "$NEW_SID" ]; then session_set implementer "$IMPL" "$NEW_SID"; fi
  RESULT=$(cat "$OUT")
  log "${PAIR_DRIVER:-$ARCH_NAME}" "Delegated task to $IMPL_NAME: $TASK"
  log "$IMPL_NAME" "$RESULT"
  echo "$RESULT"; rm -f "$OUT"
  ;;

junior-approve)
  need_state; migrate_state; resolve_roles
  [ -n "$JR" ] || die "no junior agent configured (roles.junior is empty in .pair/state.json)"
  TASK="${1:-}"; NOTE="${2:-}"
  { [ -n "$TASK" ] && [ -n "$NOTE" ]; } || \
    die "usage: pair.sh junior-approve \"<exact task text>\" \"<$HUMAN's approval note/quote>\""
  TMP=$(mktemp)
  jq --arg t "$TASK" --arg n "$NOTE" --arg ts "$(now)" --arg who "$HUMAN" \
     '.junior_approval = {task: $t, note: $n, approver: $who, approved_at: $ts, consumed: false}' \
     "$STATE" > "$TMP" && mv "$TMP" "$STATE"
  log "$HUMAN" "Approved one junior ($JR_NAME) delegation.
Task: $TASK
Note: $NOTE"
  echo "pair.sh: junior approval recorded (one run only) for: $TASK"
  ;;

junior)
  need_state; migrate_state; resolve_roles
  [ -n "$JR" ] || die "no junior agent configured (roles.junior is empty in .pair/state.json)"
  TASK="${1:-}"; [ -n "$TASK" ] || die 'usage: pair.sh junior "<task>" (must match a recorded junior-approve)'
  APPROVED_TASK=$(jq -r '.junior_approval.task // empty' "$STATE")
  # NOTE: jq's // treats false as empty, so compare explicitly
  UNCONSUMED=$(jq -r '.junior_approval.consumed == false' "$STATE")
  [ -n "$APPROVED_TASK" ] || \
    die "no approval from $HUMAN on record — every junior delegation needs an explicit go-ahead first: pair.sh junior-approve \"<task>\" \"<note>\""
  [ "$UNCONSUMED" = "true" ] || \
    die "recorded approval already consumed — one approval = one run; get a fresh go-ahead from $HUMAN"
  [ "$APPROVED_TASK" = "$TASK" ] || die "task text does not match the approved task.
approved: $APPROVED_TASK
given:    $TASK"
  SID=$(session_get junior)
  OUT=$(mktemp)
  PROMPT="You are the JUNIOR IMPLEMENTER ($JR_NAME) in a three-agent Triad protocol
($ARCH_NAME = architect/reviewer, $IMPL_NAME = primary implementer, you = junior).
Shared context lives in .pair/ (requirements.md, plan.md, log.md — read them
first). You handle ONLY the single very basic task below. Hard limits:
- no architecture or design changes, no new dependencies, no refactors
- no deleting or renaming files, nothing outside the task's scope
- if the task turns out to be bigger than described, STOP and say so —
  it will be reassigned to $IMPL_NAME
Do the task, run whatever verifies it, then summarize the exact files you
changed and the checks you ran. If you add anything to shared .pair/ files,
start the addition with the attribution header '### $JR_NAME — <YYYY-MM-DD HH:MM:SS>'.
Your work will be reviewed by $ARCH_NAME; if it is not up to the mark the task
goes back to $IMPL_NAME — you get no retry.

Task (pre-approved by $HUMAN for you):
$TASK"
  # consume the approval BEFORE launching: one approval = one ATTEMPTED run,
  # otherwise a failed run (possibly after side effects) leaves it reusable
  TMP=$(mktemp)
  jq --arg ts "$(now)" '.junior_approval.consumed = true | .junior_approval.consumed_at = $ts' \
     "$STATE" > "$TMP" && mv "$TMP" "$STATE"
  echo "pair.sh: delegating to $JR_NAME..."
  NEW_SID=$("${JR}_implement" "$OUT" "$SID" "$PROMPT") || die "junior call failed (output kept at $OUT)"
  if [ -n "$NEW_SID" ]; then session_set junior "$JR" "$NEW_SID"; fi
  RESULT=$(cat "$OUT")
  log "${PAIR_DRIVER:-$IMPL_NAME}" "Delegated approved task to $JR_NAME: $TASK"
  log "$JR_NAME" "$RESULT"
  rm -f "$OUT"
  echo "$RESULT"
  echo "pair.sh: approval consumed — next junior task needs a fresh junior-approve. Run pair.sh review before accepting this work."
  ;;

status)
  need_state; migrate_state
  printf 'roles: architect=%s implementer=%s junior=%s human=%s\n' \
    "$(state_get roles.architect)" "$(state_get roles.implementer)" \
    "$(state_get roles.junior)" "$(state_get human)"
  jq . "$STATE"
  echo "--- last log entries:"
  tail -20 "$PAIR/log.md"
  ;;

*)
  grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -45
  exit 1
  ;;
esac
