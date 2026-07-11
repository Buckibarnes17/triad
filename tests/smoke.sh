#!/usr/bin/env bash
# smoke.sh — end-to-end test of Triad + adapters against the mock agent CLIs
# in tests/mocks/ (no real codex/claude/qwen needed). Run: bash tests/smoke.sh
set -euo pipefail

KIT="$(cd "$(dirname "$0")/.." && pwd)"
PAIR_SH="$KIT/scripts/pair.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

export MOCK_LOG="$WORK/mock.log"; : > "$MOCK_LOG"
export MOCK_COUNTERS="$WORK/counters"; mkdir -p "$MOCK_COUNTERS"
export PATH="$KIT/tests/mocks:$PATH"
export PAIR_QWEN_BIN="$KIT/tests/mocks/qwen"
export PAIR_OPENCODE_BIN="$KIT/tests/mocks/opencode"
export PAIR_HUMAN="TestHuman"
unset PAIR_ARCHITECT PAIR_IMPLEMENTER PAIR_JUNIOR PAIR_DRIVER PAIR_ADAPTERS_DIR 2>/dev/null || true

pass() { echo "  ok  $*"; }
fail() { echo "FAIL: $* (mock log: $MOCK_LOG)" >&2; trap - EXIT; exit 1; }
jqe()  { local expr="$1"; shift; jq -e "$expr" "$@" >/dev/null || fail "jq: $expr"; }

echo "== 1. syntax"
bash -n "$PAIR_SH" || fail "pair.sh syntax"
for f in "$KIT"/adapters/*.sh "$KIT/install.sh" "$KIT"/tests/mocks/* "$0"; do
  bash -n "$f" || fail "syntax: $f"
done
pass "bash -n on pair.sh, adapters, install.sh, mocks"

echo "== 1b. adapter contract lint (docs/ADAPTERS.md)"
for f in "$KIT"/adapters/*.sh; do
  n=$(basename "$f" .sh)
  [[ "$n" =~ ^[a-z][a-z0-9_]*$ ]] || fail "adapter name '$n' violates ^[a-z][a-z0-9_]*\$"
  ( set -euo pipefail; . "$f"
    v="${n}_display"; [ -n "${!v:-}" ] || { echo "no ${n}_display" >&2; exit 1; }
    declare -F "${n}_consult" >/dev/null || declare -F "${n}_implement" >/dev/null \
      || { echo "no ${n}_consult/_implement" >&2; exit 1; }
  ) || fail "adapter contract: $f"
done
pass "every adapter sources cleanly and defines display + a role capability"

echo "== 2. init (default roles) + hostile brief"
A="$WORK/projA"; mkdir -p "$A"; cd "$A"
bash "$PAIR_SH" init 'brief with $(dangerous) and `backticks` and "quotes"' >/dev/null
jqe '.roles == {architect:"codex", implementer:"claude", junior:"qwen"}' .pair/state.json
jqe '.human == "TestHuman"' .pair/state.json
jqe '.sessions.architect == {agent:"codex", id:"mock-codex-1"}' .pair/state.json
grep -q 'mock requirements body' .pair/requirements.md || fail "requirements body"
grep -q 'T1: mock task' .pair/plan.md || fail "plan body"
grep -q '^### Codex' .pair/requirements.md || fail "attribution header"
grep -qF 'brief with $(dangerous) and `backticks`' "$MOCK_LOG" || fail "brief must reach the agent unexpanded"
grep -q '^### TestHuman' .pair/log.md || fail "human attribution in log"
pass "state schema, req/plan split, unexpanded brief"

echo "== 3. ask / suggest resume the architect session"
bash "$PAIR_SH" ask "what now?" >/dev/null
grep -qF -- 'codex exec resume mock-codex-1' "$MOCK_LOG" || fail "ask must resume the codex session"
grep -q 'sandbox_mode' "$MOCK_LOG" || fail "resume must set the read-only sandbox"
bash "$PAIR_SH" suggest "use X instead" >/dev/null
[ -f .pair/suggestions/001.md ] || fail "suggestions/001.md missing"
grep -q '^### Claude' .pair/suggestions/001.md || fail "suggestion attribution"
pass "ask/suggest"

echo "== 4. native review + implement session tracking"
bash "$PAIR_SH" review "T1" >/dev/null
grep -q 'VERDICT: APPROVED' .pair/reviews/001.md || fail "review verdict"
bash "$PAIR_SH" implement "task one" >/dev/null
jqe '.sessions.implementer == {agent:"claude", id:"mock-claude-1"}' .pair/state.json
bash "$PAIR_SH" implement "task two" >/dev/null
grep -q '^ARG:--resume$' "$MOCK_LOG" || fail "second implement must resume"
grep -q '^ARG:mock-claude-1$' "$MOCK_LOG" || fail "resume id"
p_line=$(grep -n '^ARG:-p$' "$MOCK_LOG" | head -1 | cut -d: -f1)
t_line=$(grep -n '^ARG:--allowedTools$' "$MOCK_LOG" | head -1 | cut -d: -f1)
[ "$p_line" -lt "$t_line" ] || fail "prompt must come before --allowedTools"
pass "review, resume, claude arg order"

echo "== 5. junior human gate"
bash "$PAIR_SH" junior "small fix" >/dev/null 2>&1 && fail "junior must refuse without approval"
bash "$PAIR_SH" junior-approve "small fix" "go ahead" >/dev/null
jqe '.junior_approval.approver == "TestHuman" and .junior_approval.consumed == false' .pair/state.json
bash "$PAIR_SH" junior "small fix" >/dev/null
jqe '.junior_approval.consumed == true' .pair/state.json
jqe '.sessions.junior.agent == "qwen"' .pair/state.json
grep -q '^ARG:--approval-mode$' "$MOCK_LOG" || fail "qwen approval-mode flag"
bash "$PAIR_SH" junior "small fix" >/dev/null 2>&1 && fail "consumed approval must not be reusable"
pass "approve -> run -> consumed"

echo "== 6. legacy aliases"
bash "$PAIR_SH" claude "task three" >/dev/null 2>"$WORK/alias.err"
grep -q "legacy alias for 'implement'" "$WORK/alias.err" || fail "claude alias note"
bash "$PAIR_SH" qwen-approve "tiny" "yes" >/dev/null 2>&1
bash "$PAIR_SH" qwen "tiny" >/dev/null 2>&1
jqe '.junior_approval.task == "tiny" and .junior_approval.consumed == true' .pair/state.json
pass "claude / qwen / qwen-approve still work"

echo "== 7. claude as architect: consult init + generic fallback review"
B="$WORK/projB"; mkdir -p "$B"; cd "$B"
PAIR_ARCHITECT=claude bash "$PAIR_SH" init "brief B" >/dev/null
jqe '.sessions.architect.agent == "claude"' .pair/state.json
echo "newfile" > f.txt
bash "$PAIR_SH" review >/dev/null
grep -q 'mock-claude-result' .pair/reviews/001.md || fail "fallback review content"
grep -q 'git diff HEAD' "$MOCK_LOG" || fail "fallback review must embed the diff"
grep -q 'untracked file contents' "$MOCK_LOG" || fail "fallback review must include untracked file content section"
grep -qF '+newfile' "$MOCK_LOG" || fail "fallback review must include untracked file contents"
pass "fallback review via architect consult"

echo "== 8. legacy state.json migration"
C="$WORK/projC"; mkdir -p "$C/.pair"; cd "$C"
cat > .pair/state.json <<'EOF'
{"project":"/x","created":"2026-01-01 00:00:00","phase":"implement",
 "sentinel":{"preserve":"exact semantic value"},
 "codex_session_id":"old-codex","claude_session_id":"old-claude",
 "qwen_approval":{"task":"t","note":"n","approver":"Keshav","approved_at":"x","consumed":false}}
EOF
printf '# log\n' > .pair/log.md
bash "$PAIR_SH" status >/dev/null
jqe '.roles == {architect:"codex", implementer:"claude", junior:"qwen"}' .pair/state.json
jqe '.sessions.architect == {agent:"codex", id:"old-codex"}' .pair/state.json
jqe '.sessions.implementer.id == "old-claude"' .pair/state.json
jqe '.junior_approval.task == "t"' .pair/state.json
jqe '.sentinel == {preserve:"exact semantic value"}' .pair/state.json
jqe '.context_policy.mode == "auto" and (.context.architect | has("resident_input_tokens")) and (.checkpoints.architect | type == "array")' .pair/state.json
jqe 'has("codex_session_id") or has("qwen_approval") | not' .pair/state.json
pass "legacy keys mapped to role-keyed schema"

echo "== 9. one binary in two roles + disabled junior lane"
D="$WORK/projD"; mkdir -p "$D"; cd "$D"
PAIR_ARCHITECT=claude PAIR_IMPLEMENTER=claude PAIR_JUNIOR= bash "$PAIR_SH" init "brief D" >/dev/null
bash "$PAIR_SH" implement "task d" >/dev/null
AID=$(jq -r '.sessions.architect.id' .pair/state.json)
IID=$(jq -r '.sessions.implementer.id' .pair/state.json)
{ [ -n "$AID" ] && [ -n "$IID" ] && [ "$AID" != "$IID" ]; } || fail "architect/implementer sessions must be independent (got '$AID' vs '$IID')"
jqe '.roles.junior == ""' .pair/state.json
bash "$PAIR_SH" junior-approve "x" "y" >/dev/null 2>&1 && fail "junior lane must be disabled"
pass "independent sessions; junior disabled"

echo "== 10. mid-project reassignment discards the stale session"
tmp=$(mktemp); jq '.roles.implementer = "qwen"' .pair/state.json > "$tmp" && mv "$tmp" .pair/state.json
bash "$PAIR_SH" implement "task e" 2>"$WORK/reassign.err" >/dev/null
grep -q 'starting a fresh session' "$WORK/reassign.err" || fail "reassignment note"
jqe '.sessions.implementer.agent == "qwen"' .pair/state.json
pass "stale session discarded on reassignment"

echo "== 11. opencode adapter: architect (plan agent, JSONL, fallback review) + model override"
E="$WORK/projE"; mkdir -p "$E"; cd "$E"
PAIR_ARCHITECT=opencode PAIR_OPENCODE_MODEL=mock/model PAIR_JUNIOR= \
  bash "$PAIR_SH" init "brief E" >/dev/null
jqe '.sessions.architect.agent == "opencode"' .pair/state.json
grep -q '^ARG:run$' "$MOCK_LOG" || fail "opencode consult must use 'run'"
grep -q '^ARG:--agent$' "$MOCK_LOG" || fail "opencode consult must use --agent"
grep -q '^ARG:plan$' "$MOCK_LOG" || fail "opencode consult must use the plan agent"
grep -q '^ARG:mock/model$' "$MOCK_LOG" || fail "PAIR_OPENCODE_MODEL must pass through as -m"
# multiple text events must concatenate in order into one reply
grep -q 'mock-opencode-result mock-opencode-1' .pair/requirements.md \
  || fail "opencode JSONL text events must concatenate in order"
echo "newfile" > f.txt
bash "$PAIR_SH" review >/dev/null
grep -q 'mock-opencode-result' .pair/reviews/001.md || fail "opencode fallback review content"
OC_SID=$(jq -r '.sessions.architect.id' .pair/state.json)
[ "$OC_SID" = "mock-opencode-1" ] || fail "opencode session id capture (got '$OC_SID')"
pass "opencode architect: plan agent, model passthrough, JSONL concat, fallback review"

echo "== 12. opencode as implementer and junior (write lane + human gate)"
F="$WORK/projF"; mkdir -p "$F"; cd "$F"
PAIR_IMPLEMENTER=opencode PAIR_JUNIOR=opencode bash "$PAIR_SH" init "brief F" >/dev/null
bash "$PAIR_SH" implement "task f" >/dev/null
jqe '.sessions.implementer.agent == "opencode"' .pair/state.json
grep -q '^ARG:--dangerously-skip-permissions$' "$MOCK_LOG" || fail "opencode implement must skip permissions"
bash "$PAIR_SH" junior "tiny f" >/dev/null 2>&1 && fail "opencode junior must refuse without approval"
bash "$PAIR_SH" junior-approve "tiny f" "go" >/dev/null
bash "$PAIR_SH" junior "tiny f" >/dev/null
jqe '.junior_approval.consumed == true and .sessions.junior.agent == "opencode"' .pair/state.json
bash "$PAIR_SH" implement "task f2" >/dev/null
grep -q '^ARG:-s$' "$MOCK_LOG" || fail "second opencode implement must resume via -s"
pass "opencode write lane, junior gate, -s resume"

echo "== 13. adapter telemetry present/absent + stdout session discipline"
G="$WORK/projG"; mkdir -p "$G"; cd "$G"
MOCK_USAGE=1 bash "$PAIR_SH" init "brief G" >/dev/null
jqe '.sessions.architect.id == "mock-codex-1"' .pair/state.json
jqe '.context.architect.source == "usage" and .context.architect.resident_input_tokens == 900
     and .context.architect.raw_total_tokens == 1000 and .context.architect.cached_input_tokens == 700
     and .context.architect.tool_calls == 1' .pair/state.json
MOCK_USAGE=1 bash "$PAIR_SH" implement "usage task" >/dev/null
jqe '.sessions.implementer.agent == "claude" and .sessions.implementer.id != ""' .pair/state.json
jqe '.context.implementer.source == "usage" and .context.implementer.resident_input_tokens == 920
     and .context.implementer.raw_total_tokens == 1000 and .context.implementer.cached_input_tokens == 800' .pair/state.json
bash "$PAIR_SH" junior-approve "usage junior" "approved" >/dev/null
MOCK_USAGE=1 bash "$PAIR_SH" junior "usage junior" >/dev/null
jqe '.context.junior.source == "usage" and .context.junior.resident_input_tokens == 600
     and .context.junior.context_window == 131072 and .context.junior.cached_input_tokens == 400
     and .context.junior.tool_calls == 1' .pair/state.json
cd "$F"
MOCK_USAGE=1 bash "$PAIR_SH" implement "task f3 usage" >/dev/null
jqe '.context.implementer.source == "usage" and .context.implementer.resident_input_tokens == 800
     and .context.implementer.cached_input_tokens >= 300 and .context.implementer.tool_calls >= 1' .pair/state.json
cd "$A"; jqe '.context.architect.source == "estimate"' .pair/state.json
pass "all shipped usage parsers + estimator fallback; session ids unpolluted"

echo "== 14. structured checkpoint, digest sensitivity, immutable history"
cd "$G"
MOCK_CHECKPOINT_JSON=1 bash "$PAIR_SH" checkpoint architect >/dev/null
jqe '.checkpoints.architect[-1].semantic_valid == true and .checkpoints.architect[-1].synthesized == false' .pair/state.json
[ -s .pair/checkpoints/architect/001.md ] && [ -s .pair/checkpoints/architect/current.md ] \
  || fail "checkpoint history/current missing"
HIST_HASH=$(sha256sum .pair/checkpoints/architect/001.md | awk '{print $1}')
DIGEST1=$(jq -r '.checkpoints.architect[-1].digest' .pair/state.json)
printf 'untracked one\n' > digest.txt
MOCK_CHECKPOINT_JSON=1 bash "$PAIR_SH" checkpoint architect >/dev/null
DIGEST2=$(jq -r '.checkpoints.architect[-1].digest' .pair/state.json)
[ "$DIGEST1" != "$DIGEST2" ] || fail "digest must change with untracked content"
[ "$HIST_HASH" = "$(sha256sum .pair/checkpoints/architect/001.md | awk '{print $1}')" ] \
  || fail "prior checkpoint history must be immutable"
[ -s .pair/checkpoints/architect/002.md ] || fail "second immutable checkpoint missing"
pass "validated semantic checkpoint, content digest, append-only history"

echo "== 15. soft checkpoint once, rollover, re-grounding, lifetime counters"
H="$WORK/projH"; mkdir -p "$H"; cd "$H"
PAIR_ARCHITECT=claude PAIR_JUNIOR= bash "$PAIR_SH" init "brief H" >/dev/null
OLD=$(jq -r '.sessions.architect.id' .pair/state.json)
tmp=$(mktemp); jq '.context.architect.checkpoint_due=true | .context.architect.rollover_due=false' .pair/state.json > "$tmp" && mv "$tmp" .pair/state.json
MOCK_CHECKPOINT_JSON=1 bash "$PAIR_SH" ask "soft one" >/dev/null
jqe '(.checkpoints.architect | length) == 1 and .checkpoints.architect[0].reason == "soft-auto"
     and .context.architect.soft_checkpoint_done == true' .pair/state.json
[ "$(jq -r '.sessions.architect.id' .pair/state.json)" = "$OLD" ] || fail "soft checkpoint must not switch"
tmp=$(mktemp); jq '.context.architect.checkpoint_due=true' .pair/state.json > "$tmp" && mv "$tmp" .pair/state.json
MOCK_CHECKPOINT_JSON=1 bash "$PAIR_SH" ask "soft two" >/dev/null
jqe '(.checkpoints.architect | length) == 1' .pair/state.json
tmp=$(mktemp); jq '.context.architect.rollover_due=true | .context.architect.raw_total_tokens=12345
  | .context.architect.cached_input_tokens=10000' .pair/state.json > "$tmp" && mv "$tmp" .pair/state.json
: > "$MOCK_LOG"
MOCK_CHECKPOINT_JSON=1 bash "$PAIR_SH" ask "roll now" >/dev/null
NEW=$(jq -r '.sessions.architect.id' .pair/state.json)
[ "$NEW" != "$OLD" ] || fail "rollover must start a fresh architect session"
jqe '(.checkpoints.architect | length) == 2 and .checkpoints.architect[-1].reason == "rollover-auto"
     and .checkpoints.architect[-1].session_id == $old
     and .context.architect.raw_total_tokens >= 12345 and .context.architect.cached_input_tokens >= 10000' \
  --arg old "$OLD" .pair/state.json
grep -q '\[CONTEXT ROLLOVER\]' "$MOCK_LOG" || fail "fresh call missing re-ground preamble"
pass "one soft checkpoint/session, write-then-switch rollover, lifetime spend preserved"

echo "== 16. stale handoff warning + synthesized fallback"
cd "$H"
MOCK_CHECKPOINT_JSON=1 bash "$PAIR_SH" checkpoint architect >/dev/null
tmp=$(mktemp); jq '.sessions.architect.id=""' .pair/state.json > "$tmp" && mv "$tmp" .pair/state.json
printf 'changed after checkpoint\n' > stale.txt
: > "$MOCK_LOG"
bash "$PAIR_SH" ask "stale check" >/dev/null
grep -q 'STALENESS WARNING' "$MOCK_LOG" || fail "stale checkpoint warning missing"
J="$WORK/projJ"; mkdir -p "$J"; cd "$J"
PAIR_ARCHITECT=claude PAIR_JUNIOR= bash "$PAIR_SH" init "brief J" >/dev/null
tmp=$(mktemp); jq '.context.architect.rollover_due=true' .pair/state.json > "$tmp" && mv "$tmp" .pair/state.json
bash "$PAIR_SH" ask "invalid checkpoint response triggers fallback" >/dev/null
jqe '.checkpoints.architect[-1].reason == "rollover-auto" and .checkpoints.architect[-1].synthesized == true
     and .checkpoints.architect[-1].semantic_valid == false' .pair/state.json
grep -q 'synthesized handoff' .pair/checkpoints/architect/current.md || fail "synthesized fallback body missing"
pass "disk-authoritative staleness warning + synthesized checkpoint fallback"

echo "== 17. context policy warn/off are non-mutating"
K="$WORK/projK"; mkdir -p "$K"; cd "$K"
PAIR_ARCHITECT=claude PAIR_JUNIOR= bash "$PAIR_SH" init "brief K" >/dev/null
KSID=$(jq -r '.sessions.architect.id' .pair/state.json)
tmp=$(mktemp); jq '.context_policy.mode="warn" | .context.architect.rollover_due=true' .pair/state.json > "$tmp" && mv "$tmp" .pair/state.json
bash "$PAIR_SH" ask "warn only" >/dev/null 2> "$WORK/warn.err"
grep -q 'mode=warn: not acting' "$WORK/warn.err" || fail "warn mode notice missing"
jqe '(.checkpoints.architect | length) == 0 and .sessions.architect.id == $sid' \
  --arg sid "$KSID" .pair/state.json
tmp=$(mktemp); jq '.context_policy.mode="off"' .pair/state.json > "$tmp" && mv "$tmp" .pair/state.json
bash "$PAIR_SH" ask "off only" >/dev/null
jqe '(.checkpoints.architect | length) == 0 and .sessions.architect.id == $sid' \
  --arg sid "$KSID" .pair/state.json
pass "warn reports and off ignores without checkpoint/session mutation"

echo "== 18. resume rc=3 retry, arbitrary failure no retry, junior invariants"
R="$WORK/projR"; mkdir -p "$R"; cd "$R"
PAIR_ADAPTERS_DIR="$KIT/tests/fixtures" PAIR_ARCHITECT=resumecheck PAIR_IMPLEMENTER=resumecheck PAIR_JUNIOR=resumecheck \
  bash "$PAIR_SH" init "brief R" >/dev/null
RSID=$(jq -r '.sessions.architect.id' .pair/state.json)
: > "$MOCK_LOG"
PAIR_ADAPTERS_DIR="$KIT/tests/fixtures" MOCK_RESUME_MODE=rc3 bash "$PAIR_SH" ask "recover" > "$WORK/recover.out"
grep -q '^clean-result:' "$WORK/recover.out" || fail "fresh retry output not clean"
grep -q 'resume-attempt:rc3' "$MOCK_LOG" || fail "rc3 resume attempt missing"
grep -q 'SECRET_AT_BYTE_ZERO' .pair/log.md && fail "resume diagnostic content leaked into durable log"
jqe '.checkpoints.architect[-1].reason == "resume-failure" and .checkpoints.architect[-1].session_id == $sid
     and .checkpoints.architect[-1].synthesized == true' --arg sid "$RSID" .pair/state.json
PAIR_ADAPTERS_DIR="$KIT/tests/fixtures" bash "$PAIR_SH" implement "prime implementer" >/dev/null
ISID=$(jq -r '.sessions.implementer.id' .pair/state.json)
PAIR_ADAPTERS_DIR="$KIT/tests/fixtures" MOCK_RESUME_MODE=rc1 bash "$PAIR_SH" implement "ordinary fail" >/dev/null 2>&1 \
  && fail "ordinary rc1 failure must propagate"
[ "$(jq -r '.sessions.implementer.id' .pair/state.json)" = "$ISID" ] || fail "rc1 must keep implementer session"
jqe '(.checkpoints.implementer | length) == 0' .pair/state.json
PAIR_ADAPTERS_DIR="$KIT/tests/fixtures" bash "$PAIR_SH" junior-approve "prime junior" "yes" >/dev/null
PAIR_ADAPTERS_DIR="$KIT/tests/fixtures" bash "$PAIR_SH" junior "prime junior" >/dev/null
PAIR_ADAPTERS_DIR="$KIT/tests/fixtures" bash "$PAIR_SH" junior-approve "junior fails" "yes again" >/dev/null
PAIR_ADAPTERS_DIR="$KIT/tests/fixtures" MOCK_RESUME_MODE=rc3 bash "$PAIR_SH" junior "junior fails" >/dev/null 2>&1 \
  && fail "junior rc3 must fail without retry"
jqe '.junior_approval.consumed == true and (.checkpoints.junior | length) == 0' .pair/state.json
pass "one genuine fresh retry; arbitrary/junior failures never retried"

echo "== 19. large fallback review is capped and log remains append-only"
L="$WORK/projL"; mkdir -p "$L"; cd "$L"
PAIR_ARCHITECT=claude PAIR_JUNIOR= bash "$PAIR_SH" init "brief L" >/dev/null
tmp=$(mktemp); jq '.context_policy.review_max_bytes=4096' .pair/state.json > "$tmp" && mv "$tmp" .pair/state.json
yes 'large-diff-line-abcdefghijklmnopqrstuvwxyz' 2>/dev/null | head -c 120000 > huge.txt || true
LOG_BEFORE=$(wc -c < .pair/log.md)
: > "$MOCK_LOG"
bash "$PAIR_SH" review >/dev/null
grep -q '\[TRUNCATED\].*4096 bytes' "$MOCK_LOG" || fail "large review truncation marker missing"
[ "$(wc -c < "$MOCK_LOG")" -lt 30000 ] || fail "fallback review prompt exceeded bounded size"
[ "$(wc -c < .pair/log.md)" -ge "$LOG_BEFORE" ] || fail "log.md was truncated"
pass "combined diff cap + explicit marker; durable log never truncated"

echo
echo "ALL SMOKE TESTS PASSED (19 scenarios)"
