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
export PAIR_HUMAN="TestHuman"
unset PAIR_ARCHITECT PAIR_IMPLEMENTER PAIR_JUNIOR PAIR_DRIVER PAIR_ADAPTERS_DIR 2>/dev/null || true

pass() { echo "  ok  $*"; }
fail() { echo "FAIL: $* (mock log: $MOCK_LOG)" >&2; trap - EXIT; exit 1; }
jqe()  { jq -e "$1" "$2" >/dev/null || fail "jq: $1 ($2)"; }

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
 "codex_session_id":"old-codex","claude_session_id":"old-claude",
 "qwen_approval":{"task":"t","note":"n","approver":"Keshav","approved_at":"x","consumed":false}}
EOF
printf '# log\n' > .pair/log.md
bash "$PAIR_SH" status >/dev/null
jqe '.roles == {architect:"codex", implementer:"claude", junior:"qwen"}' .pair/state.json
jqe '.sessions.architect == {agent:"codex", id:"old-codex"}' .pair/state.json
jqe '.sessions.implementer.id == "old-claude"' .pair/state.json
jqe '.junior_approval.task == "t"' .pair/state.json
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

echo
echo "ALL SMOKE TESTS PASSED"
