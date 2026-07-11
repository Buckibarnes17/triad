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
#   pair.sh checkpoint [role]          write a context checkpoint (machine metadata + one agent summary)
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
# Context policy is captured at init from PAIR_CTX_MODE, PAIR_CTX_SOFT_TOKENS,
# PAIR_CTX_ROLLOVER_TOKENS, PAIR_CTX_ROLLOVER_PCT, PAIR_CTX_CALL_LIMIT,
# PAIR_CTX_RAW_WARN_TOKENS, PAIR_CTX_LOG_TAIL, PAIR_CTX_REVIEW_MAX_BYTES,
# and PAIR_CTX_IMPLEMENT_FACTOR.
# Persisted state wins after init; these variables do not mutate live policy.
# 'checkpoint' is manual-only for now: it records a context checkpoint (machine
# metadata + one agent-authored summary) but never rolls a session over —
# automatic rollover is a later task.

set -euo pipefail

PROJECT_DIR="$(pwd)"
PAIR="$PROJECT_DIR/.pair"
STATE="$PAIR/state.json"

CTX_MODE_DEFAULT="auto"
CTX_SOFT_TOKENS_DEFAULT=100000
CTX_ROLLOVER_TOKENS_DEFAULT=150000
CTX_ROLLOVER_PCT_DEFAULT=70
CTX_CALL_LIMIT_DEFAULT=20
CTX_RAW_WARN_TOKENS_DEFAULT=2000000
CTX_LOG_TAIL_DEFAULT=40
CTX_REVIEW_MAX_BYTES_DEFAULT=200000
CTX_IMPLEMENT_FACTOR_DEFAULT=4
CTX_SYNTH_MAX_BYTES=20000

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

validate_uint() { # validate_uint <env-name> <value> <min> <max>
  local name="$1" value="$2" min="$3" max="$4"
  [[ "$value" =~ ^[0-9]+$ ]] || die "$name must be an integer (got '$value')"
  [ "$value" -ge "$min" ] && [ "$value" -le "$max" ] || \
    die "$name must be between $min and $max (got '$value')"
}

validate_context_policy_env() {
  local mode="${PAIR_CTX_MODE:-$CTX_MODE_DEFAULT}"
  local soft="${PAIR_CTX_SOFT_TOKENS:-$CTX_SOFT_TOKENS_DEFAULT}"
  local rollover="${PAIR_CTX_ROLLOVER_TOKENS:-$CTX_ROLLOVER_TOKENS_DEFAULT}"
  case "$mode" in auto|warn|off) ;; *) die "PAIR_CTX_MODE must be auto, warn, or off (got '$mode')" ;; esac
  validate_uint PAIR_CTX_SOFT_TOKENS "$soft" 1000 100000000
  validate_uint PAIR_CTX_ROLLOVER_TOKENS "$rollover" 1000 100000000
  [ "$soft" -le "$rollover" ] || \
    die "PAIR_CTX_SOFT_TOKENS must be <= PAIR_CTX_ROLLOVER_TOKENS"
  validate_uint PAIR_CTX_ROLLOVER_PCT "${PAIR_CTX_ROLLOVER_PCT:-$CTX_ROLLOVER_PCT_DEFAULT}" 1 95
  validate_uint PAIR_CTX_CALL_LIMIT "${PAIR_CTX_CALL_LIMIT:-$CTX_CALL_LIMIT_DEFAULT}" 1 100000
  validate_uint PAIR_CTX_RAW_WARN_TOKENS "${PAIR_CTX_RAW_WARN_TOKENS:-$CTX_RAW_WARN_TOKENS_DEFAULT}" 1000 1000000000
  validate_uint PAIR_CTX_LOG_TAIL "${PAIR_CTX_LOG_TAIL:-$CTX_LOG_TAIL_DEFAULT}" 1 10000
  validate_uint PAIR_CTX_REVIEW_MAX_BYTES "${PAIR_CTX_REVIEW_MAX_BYTES:-$CTX_REVIEW_MAX_BYTES_DEFAULT}" 1024 100000000
  validate_uint PAIR_CTX_IMPLEMENT_FACTOR "${PAIR_CTX_IMPLEMENT_FACTOR:-$CTX_IMPLEMENT_FACTOR_DEFAULT}" 1 100
}

ensure_context_schema() { # additive migration; existing values always win
  local tmp; tmp=$(mktemp)
  jq \
    --arg mode "$CTX_MODE_DEFAULT" \
    --argjson soft "$CTX_SOFT_TOKENS_DEFAULT" \
    --argjson rollover "$CTX_ROLLOVER_TOKENS_DEFAULT" \
    --argjson pct "$CTX_ROLLOVER_PCT_DEFAULT" \
    --argjson calls "$CTX_CALL_LIMIT_DEFAULT" \
    --argjson raw "$CTX_RAW_WARN_TOKENS_DEFAULT" \
    --argjson tail "$CTX_LOG_TAIL_DEFAULT" \
    --argjson review "$CTX_REVIEW_MAX_BYTES_DEFAULT" \
    --argjson factor "$CTX_IMPLEMENT_FACTOR_DEFAULT" '
      .context_policy = ({
        mode: $mode, soft_tokens: $soft, rollover_tokens: $rollover,
        rollover_pct: $pct, call_limit: $calls, raw_warn_tokens: $raw,
        log_tail: $tail, review_max_bytes: $review, implement_factor: $factor
      } + (.context_policy // {}))
      | .context = (.context // {})
      | .context.architect = ({resident_input_tokens: 0, context_window: 0,
          raw_total_tokens: 0, cached_input_tokens: 0, tool_calls: 0,
          pair_calls: 0, source: "none", checkpoint_due: false,
          rollover_due: false, soft_checkpoint_done: false, updated_at: null} + (.context.architect // {}))
      | .context.implementer = ({resident_input_tokens: 0, context_window: 0,
          raw_total_tokens: 0, cached_input_tokens: 0, tool_calls: 0,
          pair_calls: 0, source: "none", checkpoint_due: false,
          rollover_due: false, soft_checkpoint_done: false, updated_at: null} + (.context.implementer // {}))
      | .context.junior = ({resident_input_tokens: 0, context_window: 0,
          raw_total_tokens: 0, cached_input_tokens: 0, tool_calls: 0,
          pair_calls: 0, source: "none", checkpoint_due: false,
          rollover_due: false, soft_checkpoint_done: false, updated_at: null} + (.context.junior // {}))
      | .checkpoints = ({architect: [], implementer: [], junior: []} + (.checkpoints // {}))
    ' "$STATE" > "$tmp" && mv "$tmp" "$STATE"
}

init_context_schema() { # init-time policy capture after validation
  local tmp; tmp=$(mktemp)
  jq \
    --arg mode "${PAIR_CTX_MODE:-$CTX_MODE_DEFAULT}" \
    --argjson soft "${PAIR_CTX_SOFT_TOKENS:-$CTX_SOFT_TOKENS_DEFAULT}" \
    --argjson rollover "${PAIR_CTX_ROLLOVER_TOKENS:-$CTX_ROLLOVER_TOKENS_DEFAULT}" \
    --argjson pct "${PAIR_CTX_ROLLOVER_PCT:-$CTX_ROLLOVER_PCT_DEFAULT}" \
    --argjson calls "${PAIR_CTX_CALL_LIMIT:-$CTX_CALL_LIMIT_DEFAULT}" \
    --argjson raw "${PAIR_CTX_RAW_WARN_TOKENS:-$CTX_RAW_WARN_TOKENS_DEFAULT}" \
    --argjson tail "${PAIR_CTX_LOG_TAIL:-$CTX_LOG_TAIL_DEFAULT}" \
    --argjson review "${PAIR_CTX_REVIEW_MAX_BYTES:-$CTX_REVIEW_MAX_BYTES_DEFAULT}" \
    --argjson factor "${PAIR_CTX_IMPLEMENT_FACTOR:-$CTX_IMPLEMENT_FACTOR_DEFAULT}" '
      .context_policy = {mode: $mode, soft_tokens: $soft,
        rollover_tokens: $rollover, rollover_pct: $pct, call_limit: $calls,
        raw_warn_tokens: $raw, log_tail: $tail, review_max_bytes: $review,
        implement_factor: $factor}
    ' "$STATE" > "$tmp" && mv "$tmp" "$STATE"
  ensure_context_schema
}

account_context_call() { # role lane prompt outfile usage-sidecar
  local role="$1" lane="$2" prompt="$3" outfile="$4" usage="$5"
  local prompt_bytes output_bytes estimate factor source last_input window call_total cached tools
  prompt_bytes=$(printf '%s' "$prompt" | wc -c)
  output_bytes=$(wc -c < "$outfile" 2>/dev/null || echo 0)
  estimate=$(( (prompt_bytes + output_bytes + 3) / 4 ))
  factor=$(jq -r '.context_policy.implement_factor // 4' "$STATE")
  if [ "$lane" = implement ]; then estimate=$((estimate * factor)); fi

  source="estimate"; last_input=""; window=""; call_total=""; cached=0; tools=0
  if [ -s "$usage" ] && jq -e '
      type == "object"
      and ([.last_input_tokens?, .context_window?, .call_total_tokens?,
            .cached_input_tokens?, .tool_calls?]
           | map(select(. != null)) | all(type == "number" and . >= 0))
      and ([.last_input_tokens?, .context_window?, .call_total_tokens?,
            .cached_input_tokens?, .tool_calls?]
           | map(select(. != null)) | length > 0)
    ' "$usage" >/dev/null 2>&1; then
    last_input=$(jq -r '.last_input_tokens // empty | floor' "$usage")
    window=$(jq -r '.context_window // empty | floor' "$usage")
    call_total=$(jq -r '.call_total_tokens // empty | floor' "$usage")
    cached=$(jq -r '.cached_input_tokens // 0 | floor' "$usage")
    tools=$(jq -r '.tool_calls // 0 | floor' "$usage")
    [ -n "$last_input" ] && source="usage"
  elif [ -s "$usage" ]; then
    echo "pair.sh: warning: adapter wrote invalid context telemetry; using estimate" >&2
  fi
  [ -n "$call_total" ] || call_total="$estimate"

  local tmp ts; tmp=$(mktemp); ts=$(now)
  jq --arg r "$role" --arg src "$source" --arg ts "$ts" \
     --argjson est "$estimate" --argjson last "${last_input:-0}" \
     --argjson win "${window:-0}" --argjson raw "$call_total" \
     --argjson cached "$cached" --argjson tools "$tools" '
    (.context[$r] // {}) as $old
    | (.context_policy // {}) as $p
    | (($old.resident_input_tokens // 0) + $est) as $estimated_resident
    | (if $src == "usage" then $last else $estimated_resident end) as $resident
    | (if $win > 0 then $win else ($old.context_window // 0) end) as $window
    | (($old.raw_total_tokens // 0) + $raw) as $raw_total
    | (($old.cached_input_tokens // 0) + $cached) as $cached_total
    | (($old.tool_calls // 0) + $tools) as $tool_total
    | (($old.pair_calls // 0) + 1) as $pair_calls
    | (($resident >= ($p.soft_tokens // 100000))
       or ($raw_total >= ($p.raw_warn_tokens // 2000000))) as $checkpoint
    | (($resident >= ($p.rollover_tokens // 150000))
       or ($pair_calls >= ($p.call_limit // 20))
       or ($tool_total >= ($p.call_limit // 20))
       or ($window > 0 and (($resident * 100 / $window) >= ($p.rollover_pct // 70)))) as $rollover
    | .context[$r] = (($old // {}) + {
        resident_input_tokens: $resident, context_window: $window,
        raw_total_tokens: $raw_total, cached_input_tokens: $cached_total,
        tool_calls: $tool_total, pair_calls: $pair_calls, source: $src,
        checkpoint_due: $checkpoint, rollover_due: $rollover, updated_at: $ts
      })
  ' "$STATE" > "$tmp" && mv "$tmp" "$STATE"
}

dispatch_call() { # role agent verb outfile session prompt lane -> stdout session id only
  local role="$1" agent="$2" verb="$3" out="$4" sid="$5" prompt="$6" lane="$7"
  local usage sidout rc=0 PAIR_USAGE_FILE
  usage=$(mktemp); sidout=$(mktemp)
  PAIR_USAGE_FILE="$usage" # dynamically scoped for the adapter; not exported to its CLI child
  if "${agent}_${verb}" "$out" "$sid" "$prompt" > "$sidout"; then
    account_context_call "$role" "$lane" "$prompt" "$out" "$usage"
  else
    rc=$?
  fi
  cat "$sidout"
  rm -f "$usage" "$sidout"
  return "$rc"
}

dispatch_review() { # role agent outfile session prompt -> native review, no stdout contract
  local role="$1" agent="$2" out="$3" sid="$4" prompt="$5" usage rc=0 PAIR_USAGE_FILE
  usage=$(mktemp)
  PAIR_USAGE_FILE="$usage" # adapter-only sidecar path; do not expose it to the agent CLI
  if "${agent}_review" "$out" "$sid" "$prompt"; then
    account_context_call "$role" consult "$prompt" "$out" "$usage"
  else
    rc=$?
  fi
  rm -f "$usage"
  return "$rc"
}

default_human() {
  local h="${PAIR_HUMAN:-}"
  if [ -z "$h" ]; then h=$(git config user.name 2>/dev/null || true); fi
  if [ -z "$h" ]; then h="${USER:-human}"; fi
  printf '%s' "$h"
}

migrate_state() { # legacy role migration plus additive context schema
  local tmp
  if ! jq -e '.roles' "$STATE" >/dev/null 2>&1; then
    echo "pair.sh: migrating legacy state.json to the role-keyed schema" >&2
    tmp=$(mktemp)
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
  fi
  ensure_context_schema
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
      if git diff --binary --no-index -- /dev/null "$f" > "$tmp" 2>/dev/null; then
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

# ── checkpoint helpers (T-C3) ────────────────────────────────────────────────
checkpoint_digest() { # binary-safe, content-sensitive working-tree digest (SHA-256).
  # Covers tracked changes vs HEAD + staged state + untracked non-ignored
  # contents. `--binary` emits literal GIT binary patches so two *different*
  # binary blobs never collapse to the same "Binary files differ" marker;
  # untracked bytes are length-framed and symlink targets captured, so broken or
  # unusual entries still change the digest. Any content change (even untracked,
  # HEAD unchanged) yields a different digest.
  local head len f
  head=$(git rev-parse HEAD 2>/dev/null || echo none)
  {
    printf 'HEAD\0%s\0' "$head"
    printf 'TRACKED\0'
    if [ "$head" = none ]; then git diff --binary 2>/dev/null || true
    else git diff --binary HEAD 2>/dev/null || true; fi
    printf '\0STAGED\0'
    if [ "$head" = none ]; then git diff --cached --binary 2>/dev/null || true
    else git diff --cached --binary HEAD 2>/dev/null || true; fi
    printf '\0UNTRACKED\0'
    while IFS= read -r -d '' f; do
      if [ -L "$f" ]; then
        printf '%s\0symlink\0%s\0' "$f" "$(readlink -- "$f" 2>/dev/null || echo '?')"
      elif [ -f "$f" ]; then
        len=$(wc -c < "$f" 2>/dev/null || echo 0)
        printf '%s\0file\0%s\0' "$f" "$len"
        cat -- "$f" 2>/dev/null || true
        printf '\0'
      else
        printf '%s\0other\0\0' "$f"   # fifo/socket/dir-symlink etc.
      fi
    done < <(git ls-files -z --others --exclude-standard 2>/dev/null)
  } | sha256sum | awk '{print $1}'
}

# Schema for the agent-authored semantic summary. A valid checkpoint summary is
# a single JSON object with every field present, correctly typed, and non-empty;
# decisions are decision+rationale object pairs. Empty strings, missing keys,
# wrong types, or non-JSON prose are all INVALID.
CKPT_SCHEMA='
  def ne: type=="string" and (gsub("^\\s+|\\s+$";"") | length>0);
  def nelist: (ne) or (type=="array" and length>0 and all(.[]; ne));
  type=="object"
  and (has("goals") and (.goals|nelist))
  and (has("decisions") and (.decisions|type=="array" and length>0
        and all(.[]; type=="object"
                     and has("decision") and (.decision|ne)
                     and has("rationale") and (.rationale|ne))))
  and (has("blockers") and (.blockers|nelist))
  and (has("approvals_pending") and (.approvals_pending|nelist))
  and (has("next_actions") and (.next_actions|nelist))
  and (has("paths") and (.paths|nelist))
  and (has("tests") and (.tests|nelist))
'

checkpoint_semantic_ok() { # <raw_outfile> <normalized_json_out>
  # Strip ```json / ``` fences, then require a schema-valid JSON object. On
  # success writes canonical (pretty) JSON to <normalized_json_out>.
  local f="$1" norm="$2" tmp; tmp=$(mktemp)
  sed -e 's/^[[:space:]]*```[a-zA-Z0-9]*[[:space:]]*$//' \
      -e 's/^[[:space:]]*```[[:space:]]*$//' "$f" > "$tmp"
  if jq -e "$CKPT_SCHEMA" "$tmp" >/dev/null 2>&1; then
    jq '.' "$tmp" > "$norm"; rm -f "$tmp"; return 0
  fi
  rm -f "$tmp"; return 1
}

checkpoint_synth_body() { # <role> <note> — engine-only synthesized handoff body
  # (bounded git/plan/review/log context; no agent call). Used for mechanical /
  # synthesized checkpoints so a fresh session can still re-ground from disk.
  local role="$1" note="$2" tail_n rv raw total omitted
  tail_n=$(log_tail_n)                          # single consistent bound for every view
  raw=$(mktemp)
  {
    printf '%s\n\n' "$note"
    printf '## synthesized handoff (engine mechanical fallback — verify against disk)\n'
    printf 'git_head: %s\n' "$(git rev-parse HEAD 2>/dev/null || echo '(no commits)')"
    printf 'git_status (first %s lines):\n' "$tail_n"; git status --short 2>/dev/null | head -n "$tail_n" || true
    printf '\nplan.md focus (tail -%s):\n' "$tail_n"; tail -n "$tail_n" "$PAIR/plan.md" 2>/dev/null || true
    printf '\nlatest review verdict:\n'
    rv=$(ls "$PAIR/reviews" 2>/dev/null | grep '^[0-9]' | tail -1 || true)
    if [ -n "$rv" ]; then grep -h '^VERDICT:' "$PAIR/reviews/$rv" 2>/dev/null || echo "(no verdict line in $rv)"; else echo "(no reviews yet)"; fi
    printf '\nrecent log (tail -%s):\n' "$tail_n"; tail -n "$tail_n" "$PAIR/log.md" 2>/dev/null || true
  } > "$raw"
  total=$(wc -c < "$raw")
  if [ "$total" -gt "$CTX_SYNTH_MAX_BYTES" ]; then
    head -c "$CTX_SYNTH_MAX_BYTES" "$raw"
    omitted=$((total - CTX_SYNTH_MAX_BYTES))
    printf '\n\n=== [TRUNCATED] synthesized handoff capped at %s bytes; %s bytes omitted from the combined end. Re-read canonical .pair files directly. ===\n' \
      "$CTX_SYNTH_MAX_BYTES" "$omitted"
  else
    cat "$raw"
  fi
  rm -f "$raw"
}

checkpoint_role() { # <role> [reason] [force_mechanical] — writes a schema-complete
  # MECHANICAL checkpoint (history NNN.md + current.md + state entry) BEFORE any
  # agent call, then atomically enriches it with a validated JSON semantic
  # summary. reason parameterizes the record; force_mechanical=1 skips the agent
  # call entirely (synthesized fallback, e.g. a dead session). Never clears the
  # session (the caller does the switch), never touches junior_approval, and
  # never invokes the junior adapter (junior/consult-less agents are mechanical).
  local role="$1" reason="${2:-manual}" force_mech="${3:-0}" \
        agent sid name digest head dir n ts file new_sid rc \
        n_int meta out norm mechanical_only=0 note
  agent=$(jq -r ".roles.$role // empty" "$STATE")
  [ -n "$agent" ] || { echo "pair.sh: no $role role configured — skipping" >&2; return 0; }
  sid=$(session_get "$role")
  name=$(display_of "$agent")
  digest=$(checkpoint_digest)
  head=$(git rev-parse HEAD 2>/dev/null || echo "(no commits)")
  dir="$PAIR/checkpoints/$role"; mkdir -p "$dir"
  n=$(next_seq "$dir"); n_int=$((10#$n))
  ts=$(now); file="checkpoints/$role/$n.md"

  # a checkpoint may only use a READ-ONLY consult lane. The junior adapter is
  # never called; nor is any implement-only agent (that would be write-capable).
  note="(semantic summary pending — mechanical record written before the agent call)"
  if [ "$force_mech" = 1 ]; then
    mechanical_only=1
    note="(synthesized checkpoint (reason=$reason): engine mechanical fallback — no agent call)"
  elif [ "$role" = junior ]; then
    mechanical_only=1
    note="(junior role: mechanical checkpoint only — the junior adapter is never invoked; the one-time approval is untouched)"
  elif [ -z "$sid" ]; then
    mechanical_only=1
    note="(no live $role session — mechanical checkpoint only; semantic summary unavailable)"
  elif ! declare -F "${agent}_consult" >/dev/null; then
    mechanical_only=1
    note="(mechanical checkpoint only — agent '$agent' has no read-only consult lane; semantic summary omitted by design)"
  fi

  # metadata header, built once; identical in the mechanical and enriched files
  meta="$(agent_header "$name")
# CHECKPOINT $role #$n
reason: $reason
session_id: ${sid:-(none)}
agent: $agent
git_head: $head
digest: $digest
$(jq -r --arg r "$role" '(.context[$r] // {}) |
    "resident_input_tokens: \(.resident_input_tokens // 0)",
    "context_window: \(.context_window // 0)",
    "raw_total_tokens: \(.raw_total_tokens // 0)",
    "cached_input_tokens: \(.cached_input_tokens // 0)",
    "tool_calls: \(.tool_calls // 0)",
    "pair_calls: \(.pair_calls // 0)"' "$STATE")"

  emit_ckpt() { # <sem_valid> <body_file> — atomically (re)write NNN.md + current.md
    local sv="$1" body="$2" t="$PAIR/$file.tmp.$$"
    { printf '%s\n' "$meta"
      printf 'semantic_valid: %s\n' "$sv"
      printf -- '--- SEMANTIC SUMMARY (valid=%s) ---\n' "$sv"
      cat "$body"
    } > "$t" && mv "$t" "$PAIR/$file" && cp "$PAIR/$file" "$dir/current.md"
  }

  # ── persist a schema-complete mechanical checkpoint FIRST, in the exact
  # durable order: history -> current -> log -> checkpoint state record. A
  # failure at any earlier step (set -e) aborts before the caller's switch.
  # synthesized:true until a valid agent summary enriches it.
  out=$(mktemp); printf '%s\n' "$note" > "$out"
  emit_ckpt false "$out"                       # (1) history NNN.md  (2) current.md
  log "$name" "Checkpoint #$n mechanical record written ($file, reason=$reason). session=${sid:-(none)} head=$head digest=${digest:0:12}"   # (3) log
  local tmp; tmp=$(mktemp)                       # (4) checkpoint state record
  jq --arg r "$role" --argjson n "$n_int" --arg at "$ts" --arg sid "${sid:-}" \
     --arg head "$head" --arg digest "$digest" --arg file "$file" --arg reason "$reason" '
     .checkpoints[$r] = ((.checkpoints[$r] // []) + [{
       n: $n, at: $at, reason: $reason, session_id: $sid, git_head: $head,
       digest: $digest, semantic_valid: false, synthesized: true, file: $file,
       counters: {
         resident_input_tokens: (.context[$r].resident_input_tokens // 0),
         raw_total_tokens: (.context[$r].raw_total_tokens // 0),
         pair_calls: (.context[$r].pair_calls // 0),
         tool_calls: (.context[$r].tool_calls // 0)
       }
     }])' "$STATE" > "$tmp" && mv "$tmp" "$STATE"

  if [ "$mechanical_only" = 1 ]; then
    # enrich the body with a bounded synthesized handoff (still synthesized:true)
    checkpoint_synth_body "$role" "$note" > "$out"
    emit_ckpt false "$out"
    rm -f "$out"
    echo "pair.sh: $role checkpoint #$n -> .pair/$file (mechanical/synthesized only)"
    return 0
  fi

  # ── the single semantic call (read-only consult lane) ──
  local cp_prompt
  cp_prompt="You are the $name ($role role) in a Triad protocol. This is a CONTEXT
CHECKPOINT, not a task: do NOT create, edit, or delete any file. Re-read
.pair/requirements.md, .pair/plan.md, the latest .pair/reviews/, and
tail -$(jq -r '.context_policy.log_tail // 40' "$STATE") .pair/log.md as needed.
$(budget_reminder readonly)
Output ONLY a single JSON object (no prose, no code fences) with EXACTLY these keys,
every field present, correctly typed, and NON-EMPTY; never include secrets,
credentials, API keys, or env values:
{
  \"goals\": \"<what this session is trying to achieve>\",
  \"decisions\": [ {\"decision\": \"<what was decided>\", \"rationale\": \"<why>\"} ],
  \"blockers\": \"<blockers, or 'none'>\",
  \"approvals_pending\": \"<commits/sensitive/major changes awaiting the human, or 'none'>\",
  \"next_actions\": [ \"<ordered concrete next step>\" ],
  \"paths\": [ \"<exact file touched or owned this phase>\" ],
  \"tests\": \"<how to verify + last known result>\"
}"
  rc=0
  new_sid=$(dispatch_call "$role" "$agent" consult "$out" "$sid" "$cp_prompt" consult) || rc=$?
  if [ "$rc" != 0 ]; then
    echo "pair.sh: warning: $name checkpoint call failed (exit $rc) — synthesized fallback kept" >&2
    checkpoint_synth_body "$role" "(checkpoint call failed, exit $rc — synthesized fallback; semantic summary unavailable)" > "$out"
    emit_ckpt false "$out"; rm -f "$out"        # record stays synthesized:true (never flipped)
    echo "pair.sh: $role checkpoint #$n -> .pair/$file (synthesized; agent call failed)"
    return 0
  fi
  [ -n "$new_sid" ] && session_set "$role" "$agent" "$new_sid"

  norm=$(mktemp)
  if checkpoint_semantic_ok "$out" "$norm"; then
    # ── finding 4: atomically enrich the SAME checkpoint after validation ──
    emit_ckpt true "$norm"
    tmp=$(mktemp)
    jq --arg r "$role" '.checkpoints[$r][-1].semantic_valid = true
                        | .checkpoints[$r][-1].synthesized = false' \
       "$STATE" > "$tmp" && mv "$tmp" "$STATE"
    log "$name" "Checkpoint #$n enriched with a validated semantic summary."
    echo "pair.sh: $role checkpoint #$n -> .pair/$file (semantic_valid=true)"
  else
    echo "pair.sh: warning: $name checkpoint summary is not schema-valid JSON — synthesized fallback kept" >&2
    checkpoint_synth_body "$role" "(agent summary rejected: not a schema-valid JSON checkpoint — synthesized fallback)" > "$out"
    emit_ckpt false "$out"                       # record stays synthesized:true
    echo "pair.sh: $role checkpoint #$n -> .pair/$file (synthesized; summary rejected)"
  fi
  rm -f "$out" "$norm"
}

# ── bounded context bundles / budget prompts (T-C5) ──────────────────────────
log_tail_n() { jq -r '.context_policy.log_tail // 40' "$STATE"; }

budget_reminder() { # [readonly] — concise per-call context-budget reminder
  local mode="${1:-write}" lt; lt=$(log_tail_n)
  cat <<EOF
Context budget: sessions are disposable — .pair/ on disk is the source of truth.
For .pair/log.md read only the last $lt lines (tail -$lt), never the whole file.
Keep routine output to ~100 lines / ~2K tokens and active diagnostics to ~250
lines / ~5K tokens.
EOF
  if [ "$mode" = readonly ]; then
    printf '%s\n' 'You are read-only: do not create files; summarize verbose evidence and identify the exact path/command needed for deeper inspection.'
  else
    printf '%s\n' 'Write anything more verbose to a file and summarize it in the reply rather than pasting it.'
  fi
}

review_context_file() { # <bundle_out> <cap_bytes> — build the fallback-review
  # context (status + untracked + binary diff) via a binary-safe temp-FILE pipeline
  # (never loading the uncapped diff into a shell variable) and cap the COMBINED
  # bundle to <cap_bytes>, appending an explicit truncation marker with the
  # omitted byte count and what/where was dropped.
  local out="$1" cap="$2" raw total omitted
  raw=$(mktemp)
  {
    printf '=== git status (short) ===\n'; git status --short 2>/dev/null || true
    printf '\n=== untracked files ===\n'; git ls-files --others --exclude-standard 2>/dev/null || true
    printf '\n=== untracked file contents ===\n'; untracked_diff_context 2>/dev/null || true
    printf '\n=== git diff HEAD ===\n'
    if git rev-parse HEAD >/dev/null 2>&1; then git diff --binary HEAD 2>/dev/null || true
    else printf '(no commits yet — every file is new/untracked)\n'; fi
  } > "$raw"                                   # streamed to a FILE, uncapped, never a variable
  total=$(wc -c < "$raw")
  if [ "$total" -gt "$cap" ]; then
    head -c "$cap" "$raw" > "$out"             # byte-safe cap on the combined bundle
    omitted=$((total - cap))
    printf '\n\n=== [TRUNCATED] review bundle capped at %s bytes (context_policy.review_max_bytes); %s bytes omitted from the END of the combined status/untracked/diff bundle. Run `git diff --binary HEAD` and `git status` yourself for the complete picture. ===\n' "$cap" "$omitted" >> "$out"
  else
    cp "$raw" "$out"
  fi
  rm -f "$raw"
}

# ── rollover / re-grounding / recovery helpers (T-C4) ────────────────────────
# Reserved adapter exit code: a _consult/_implement/_review that returns 3
# (PAIR_RC_NO_SESSION) signals "the given session id could not be resumed"
# (session-not-found). Only that specific failure earns a single fresh retry;
# any other nonzero exit is a genuine task failure and is never retried.

rollover_switch() { # <role> — clear the (already-checkpointed) session and reset
  # per-session PRESSURE counters + the soft-checkpoint marker; PRESERVE lifetime
  # raw_total_tokens and cached_input_tokens (cumulative spend outlives a session).
  local r="$1" tmp; tmp=$(mktemp)
  jq --arg r "$r" '
      (if .sessions[$r] then .sessions[$r].id = "" else . end)
    | .context[$r].resident_input_tokens = 0
    | .context[$r].context_window = 0
    | .context[$r].tool_calls = 0
    | .context[$r].pair_calls = 0
    | .context[$r].checkpoint_due = false
    | .context[$r].rollover_due = false
    | .context[$r].soft_checkpoint_done = false
  ' "$STATE" > "$tmp" && mv "$tmp" "$STATE"
}

handoff_preamble() { # <role> -> re-grounding preamble IF a checkpoint exists (else
  # empty). Injected only on a fresh (post-rollover) session. Compares the
  # recorded digest to the current one and warns when the tree has moved on.
  local role="$1" rec_digest cur_digest file stale tail_n
  file=$(jq -r --arg r "$role" '.checkpoints[$r] // [] | (last // {}) | .file // empty' "$STATE")
  [ -n "$file" ] || return 0
  rec_digest=$(jq -r --arg r "$role" '.checkpoints[$r] | last | .digest // ""' "$STATE")
  cur_digest=$(checkpoint_digest)
  tail_n=$(jq -r '.context_policy.log_tail // 40' "$STATE")
  stale=""
  if [ -n "$rec_digest" ] && [ "$rec_digest" != "$cur_digest" ]; then
    stale="STALENESS WARNING: the working tree changed since this handoff was written
(recorded digest ${rec_digest:0:12} != current ${cur_digest:0:12}). DISK IS
AUTHORITATIVE — re-verify every decision/path/test against the CURRENT code first.
"
  fi
  printf '%s' "[CONTEXT ROLLOVER] You are resuming the $role role on a FRESH session after a
context rollover. Previous session handoff: .pair/checkpoints/$role/current.md
(latest record .pair/$file), recorded working-tree digest ${rec_digest:0:12}.
Before anything else, re-read .pair/requirements.md, .pair/plan.md, the latest
.pair/reviews/, that handoff file, and tail -$tail_n .pair/log.md. Those files are the
canonical truth — trust DISK over the handoff on any conflict.
$stale
--- your task follows ---
"
}

maybe_rollover() { # <role> — pre-dispatch check for ask/suggest/review/implement.
  # NEVER junior. off: inert. warn: report soft/rollover pressure, no mutation.
  # auto: rollover (checkpoint+switch) when rollover_due; otherwise ONE proactive
  # no-switch checkpoint per live session when checkpoint_due (soft threshold).
  local role="$1" mode roll soft done sid tmp
  [ "$role" = junior ] && return 0
  mode=$(jq -r '.context_policy.mode // "auto"' "$STATE")
  [ "$mode" = off ] && return 0
  roll=$(jq -r --arg r "$role" '.context[$r].rollover_due // false' "$STATE")
  soft=$(jq -r --arg r "$role" '.context[$r].checkpoint_due // false' "$STATE")
  sid=$(jq -r --arg r "$role" '.sessions[$r].id // empty' "$STATE")

  if [ "$mode" = warn ]; then
    if [ "$roll" = true ]; then
      echo "pair.sh: note: $role is over the ROLLOVER threshold — consider 'pair.sh checkpoint $role' (mode=warn: not acting)" >&2
    elif [ "$soft" = true ]; then
      echo "pair.sh: note: $role is over the soft CHECKPOINT threshold — consider 'pair.sh checkpoint $role' (mode=warn: not acting)" >&2
    fi
    return 0
  fi

  # ── auto ──
  if [ "$roll" = true ]; then
    [ -n "$sid" ] || return 0   # nothing live to roll
    echo "pair.sh: auto-rollover: $role over threshold — checkpoint then fresh session" >&2
    checkpoint_role "$role" rollover-auto      # durable history->current->log->state
    rollover_switch "$role"                     # ...only THEN clear session + counters + soft marker
    echo "pair.sh: auto-rollover: $role rolled; the next call re-grounds from the handoff" >&2
    return 0
  fi
  # proactive soft checkpoint: once per live session, NO switch
  done=$(jq -r --arg r "$role" '.context[$r].soft_checkpoint_done // false' "$STATE")
  if [ "$soft" = true ] && [ "$done" != true ] && [ -n "$sid" ]; then
    echo "pair.sh: auto-checkpoint: $role over the soft threshold — one proactive checkpoint (no switch)" >&2
    checkpoint_role "$role" soft-auto
    tmp=$(mktemp)
    jq --arg r "$role" '.context[$r].soft_checkpoint_done = true' "$STATE" > "$tmp" && mv "$tmp" "$STATE"
  fi
}

role_dispatch() { # <role> <agent> <verb> <lane> <outfile> <base_prompt>
  # Inject the handoff preamble on a fresh session, dispatch, and on a genuine
  # resume failure (rc==3) retry EXACTLY once with a fresh session — architect/
  # implementer only. Persists the session; prints the new session id.
  local role="$1" agent="$2" verb="$3" lane="$4" out="$5" prompt="$6"
  local sid full new_sid rc
  sid=$(session_get "$role")
  full="$prompt"; [ -z "$sid" ] && full="$(handoff_preamble "$role")$prompt"
  rc=0; new_sid=$(dispatch_call "$role" "$agent" "$verb" "$out" "$sid" "$full" "$lane") || rc=$?
  if [ "$rc" = 0 ]; then
    [ -n "$new_sid" ] && session_set "$role" "$agent" "$new_sid"
    printf '%s' "$new_sid"; return 0
  fi
  if [ "$rc" = 3 ] && [ -n "$sid" ] && { [ "$role" = architect ] || [ "$role" = implementer ]; }; then
    echo "pair.sh: $role session '$sid' could not be resumed (rc=3) — synthesized checkpoint + one fresh retry" >&2
    # Log only non-content metadata about the discarded diagnostic (byte count
    # and SHA-256) so the durable log cannot leak diagnostic content
    # or grow without bound — then TRUNCATE the result file so stale failure
    # output cannot contaminate the successful retry's task output.
    if [ -s "$out" ]; then
      local dbytes dsha
      dbytes=$(wc -c < "$out")
      dsha=$(sha256sum "$out" | awk '{print $1}')
      log "$(display_of "$agent")" "resume-failure on session $sid (rc=3): discarded ${dbytes}B of diagnostic from task output (sha256=$dsha; content not persisted)"
    fi
    checkpoint_role "$role" resume-failure 1   # dead session: mechanical/synthesized, old id recorded
    rollover_switch "$role"                     # clear the dead session before retrying
    : > "$out"                                  # clean slate for the retry output
    full="$(handoff_preamble "$role")$prompt"
    rc=0; new_sid=$(dispatch_call "$role" "$agent" "$verb" "$out" "" "$full" "$lane") || rc=$?
    if [ "$rc" = 0 ]; then
      [ -n "$new_sid" ] && session_set "$role" "$agent" "$new_sid"
      printf '%s' "$new_sid"; return 0
    fi
  fi
  return "$rc"   # arbitrary failures (and post-retry failures) are NOT retried
}

architect_review_dispatch() { # <outfile> <review_prompt> -> rc; native or fallback
  # review with handoff injection + a single genuine-resume-failure retry. Rewrites
  # the outfile fresh each attempt (header + body) so a retry never duplicates.
  local out="$1" rp="$2" sid full rc new_sid fresh=0 CAP BUNDLE TMP
  sid=$(session_get architect)
  while :; do
    full="$rp"; [ -z "$sid" ] && full="$(handoff_preamble architect)$rp"
    agent_header "$ARCH_NAME" > "$out"     # fresh header each attempt (no duplication)
    rc=0
    if declare -F "${ARCH}_review" >/dev/null; then
      dispatch_review architect "$ARCH" "$out" "$sid" "$full" || rc=$?   # native review: unchanged
    else
      # generic fallback: build a binary-safe, review_max_bytes-capped context
      # bundle in a FILE (never load the uncapped diff into a shell variable).
      CAP=$(jq -r '.context_policy.review_max_bytes // 200000' "$STATE")
      BUNDLE=$(mktemp); review_context_file "$BUNDLE" "$CAP"
      TMP=$(mktemp)
      new_sid=$(dispatch_call architect "$ARCH" consult "$TMP" "$sid" "$full

$(cat "$BUNDLE")" consult) || rc=$?
      cat "$TMP" >> "$out"; rm -f "$TMP" "$BUNDLE"
      if [ "$rc" = 0 ] && [ -n "$new_sid" ]; then session_set architect "$ARCH" "$new_sid"; fi
    fi
    [ "$rc" = 0 ] && return 0
    if [ "$rc" = 3 ] && [ -n "$sid" ] && [ "$fresh" = 0 ]; then
      fresh=1
      echo "pair.sh: architect session '$sid' could not be resumed (rc=3) — synthesized checkpoint + one fresh retry" >&2
      checkpoint_role architect resume-failure 1
      rollover_switch architect
      sid=""
      continue
    fi
    return "$rc"
  done
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
  validate_context_policy_env
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
  init_context_schema
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
$(budget_reminder readonly)

=== REQUIREMENTS ===
Your full understanding of the project: goals, constraints, non-goals,
acceptance criteria. Concrete enough that an implementer who never saw the
brief could build it.

=== PLAN ===
Ordered task list T1, T2, ... Each task: what to build, files involved,
and a verifiable done-condition. Keep tasks small enough to review one at a time.

Project brief:
$BRIEF"
  SID=$(dispatch_call architect "$ARCH" consult "$OUT" "" "$PROMPT" consult) || die "architect intake failed (output kept at $OUT)"
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
  maybe_rollover architect        # only after arg validation — never roll then fail on usage
  OUT=$(mktemp)
  PREFIX="Question from the implementer ($IMPL_NAME):"
  if [ "$cmd" = suggest ]; then
    PREFIX="Suggestion from the implementer ($IMPL_NAME). Rule on it: ACCEPT (say how the plan changes) or REJECT (say why). If accepted, output the amended plan section in full so it can be transcribed into plan.md:"
  fi
  PROMPT="Reminder: you are the architect ($ARCH_NAME); do not create, edit, or delete files.
Shared context lives in .pair/ (requirements.md, plan.md; for log.md read tail -$(log_tail_n) only).
$(budget_reminder readonly)
$PREFIX

$MSG"
  role_dispatch architect "$ARCH" consult consult "$OUT" "$PROMPT" >/dev/null \
    || die "architect call failed (output kept at $OUT)"
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
  maybe_rollover architect
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
$(budget_reminder readonly)
$NOTES"
  echo "pair.sh: running $ARCH_NAME review of uncommitted changes..."
  # native review (if the adapter has one) or the generic diff-embedded consult
  # fallback, with fresh-session handoff injection + one genuine-resume retry.
  # NOTE: a very large diff may blow the context window (bounded in T-C5).
  RC=0
  architect_review_dispatch "$OUTFILE" "$REVIEW_PROMPT" || RC=$?
  log "$ARCH_NAME" "Review #$N written to reviews/$N.md (exit $RC)"
  echo "pair.sh: review saved -> $OUTFILE"
  tail -40 "$OUTFILE"
  ;;

implement)
  need_state; migrate_state; resolve_roles
  TASK="${1:-}"; [ -n "$TASK" ] || die 'usage: pair.sh implement "<task>"'
  maybe_rollover implementer      # only after arg validation — never roll then fail on usage
  OUT=$(mktemp)
  PROMPT="You are the IMPLEMENTER ($IMPL_NAME) in a Triad protocol with $ARCH_NAME (architect).
Read .pair/requirements.md and .pair/plan.md first; for .pair/log.md read only
tail -$(log_tail_n) (never the whole file).
$(budget_reminder)
Implement the task below. Write code + run whatever verifies it. When done,
summarize what changed and what you verified. If you add anything to the
shared .pair/ files (plan.md amendments, notes), start the addition with the
attribution header '### $IMPL_NAME — <YYYY-MM-DD HH:MM:SS>'.

Task from the architect ($ARCH_NAME):
$TASK"
  role_dispatch implementer "$IMPL" implement implement "$OUT" "$PROMPT" >/dev/null \
    || die "implementer call failed (output kept at $OUT)"
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
Read .pair/requirements.md and .pair/plan.md first; for .pair/log.md read only
tail -$(log_tail_n) (never the whole file).
$(budget_reminder)
You handle ONLY the single very basic task below. Hard limits:
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
  NEW_SID=$(dispatch_call junior "$JR" implement "$OUT" "$SID" "$PROMPT" implement) || die "junior call failed (output kept at $OUT)"
  if [ -n "$NEW_SID" ]; then session_set junior "$JR" "$NEW_SID"; fi
  RESULT=$(cat "$OUT")
  log "${PAIR_DRIVER:-$IMPL_NAME}" "Delegated approved task to $JR_NAME: $TASK"
  log "$JR_NAME" "$RESULT"
  rm -f "$OUT"
  echo "$RESULT"
  echo "pair.sh: approval consumed — next junior task needs a fresh junior-approve. Run pair.sh review before accepting this work."
  ;;

checkpoint)
  need_state; migrate_state; resolve_roles
  ROLE="${1:-}"
  ROLES_TO_CP=""
  if [ -n "$ROLE" ]; then
    case "$ROLE" in
      architect|implementer|junior) ROLES_TO_CP="$ROLE" ;;
      *) die "unknown role '$ROLE' (want architect, implementer, or junior)" ;;
    esac
  else
    # default: architect + implementer (the rollover-eligible roles), each only
    # if it has a live session. Junior is exempt from automatic rollover and is
    # checkpointed only when named explicitly.
    for r in architect implementer; do
      [ -n "$(jq -r ".sessions.$r.id // empty" "$STATE")" ] && ROLES_TO_CP="$ROLES_TO_CP $r"
    done
    [ -n "$ROLES_TO_CP" ] || die "no architect/implementer session to checkpoint — name a role: pair.sh checkpoint <role>"
  fi
  for r in $ROLES_TO_CP; do
    echo "pair.sh: checkpointing $r..."
    checkpoint_role "$r"
  done
  ;;

status)
  need_state; migrate_state
  printf 'roles: architect=%s implementer=%s junior=%s human=%s\n' \
    "$(state_get roles.architect)" "$(state_get roles.implementer)" \
    "$(state_get roles.junior)" "$(state_get human)"
  jq . "$STATE"
  jq -r '
    ["architect", "implementer", "junior"][] as $r
    | (.context[$r] // {}) as $c
    | "context \($r): resident=\($c.resident_input_tokens // 0) window=\($c.context_window // 0) "
      + (if (($c.context_window // 0) > 0) then
           "pct=\((((($c.resident_input_tokens // 0) * 100) / $c.context_window) | floor))% "
         else "pct=n/a " end)
      + "raw=\($c.raw_total_tokens // 0) cached=\($c.cached_input_tokens // 0) "
      + "tools=\($c.tool_calls // 0) calls=\($c.pair_calls // 0) "
      + "source=\($c.source // "none") checkpoint=\($c.checkpoint_due // false) rollover=\($c.rollover_due // false) "
      + "ckpts=\((.checkpoints[$r] // []) | length)"
      + ((.checkpoints[$r] // []) | if length>0 then " last=#\(last.n)(\(last.reason),synth=\(last.synthesized // false))" else "" end)
  ' "$STATE"
  echo "--- last log entries:"
  tail -20 "$PAIR/log.md"
  ;;

*)
  grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -45
  exit 1
  ;;
esac
