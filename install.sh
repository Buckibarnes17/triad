#!/usr/bin/env bash
# install.sh — set up the Claude Code <-> Codex pair protocol on this machine.
#
# Usage:
#   ./install.sh [--scripts-dir DIR] [--claude-md FILE] [--claude-skills DIR] [--yes]
#
# Defaults:
#   --scripts-dir    ~/.local/bin
#   --claude-md      ~/.claude/CLAUDE.md          (user-global; use a project
#                                                  CLAUDE.md to scope it)
#   --claude-skills  ~/.claude/pair-skills
#
# The installer NEVER touches kernel settings; if the Codex sandbox is broken
# it prints the exact sudo commands for you to run yourself.

set -euo pipefail

KIT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_DIR="$HOME/.local/bin"
CLAUDE_MD="$HOME/.claude/CLAUDE.md"
CLAUDE_SKILLS="$HOME/.claude/pair-skills"
ASSUME_YES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --scripts-dir)   SCRIPTS_DIR="$2"; shift 2 ;;
    --claude-md)     CLAUDE_MD="$2"; shift 2 ;;
    --claude-skills) CLAUDE_SKILLS="$2"; shift 2 ;;
    --yes)           ASSUME_YES=1; shift ;;
    *) echo "unknown arg: $1"; exit 1 ;;
  esac
done

PAIR_SH="$SCRIPTS_DIR/pair.sh"

say()  { printf '\n== %s\n' "$*"; }
ok()   { printf '   OK  %s\n' "$*"; }
warn() { printf '   !!  %s\n' "$*"; }

confirm() {
  [ "$ASSUME_YES" = 1 ] && return 0
  printf '%s [y/N] ' "$1"; read -r a; [ "$a" = y ] || [ "$a" = Y ]
}

# ── 1. prerequisites ─────────────────────────────────────────────────────────
say "Checking prerequisites"
MISSING=0
for bin in claude codex jq git; do
  if command -v "$bin" >/dev/null 2>&1; then ok "$bin ($(command -v "$bin"))"
  else warn "$bin NOT FOUND"; MISSING=1; fi
done
[ "$MISSING" = 1 ] && { echo "Install the missing tools and re-run."; exit 1; }
codex --version || true

# qwen is optional (junior-implementer lane only) and NOT expected on PATH —
# pair.sh calls it by absolute path (override with PAIR_QWEN_BIN)
QWEN_BIN="${PAIR_QWEN_BIN:-$HOME/.local/bin/qwen}"
if [ -x "$QWEN_BIN" ]; then
  ok "qwen ($QWEN_BIN, version $("$QWEN_BIN" --version 2>/dev/null || echo unknown))"
else
  warn "qwen not found at $QWEN_BIN — 'pair.sh qwen' will refuse until installed"
  echo "   (optional) install user-local: npm install -g --prefix ~/.local @qwen-code/qwen-code"
  echo "   or point pair.sh at it: export PAIR_QWEN_BIN=/path/to/qwen"
fi

# ── 2. Codex sandbox health (Linux) ──────────────────────────────────────────
if [ "$(uname -s)" = Linux ]; then
  say "Checking Codex Linux sandbox (bubblewrap / user namespaces)"
  if codex sandbox linux -- true >/dev/null 2>&1; then
    ok "sandbox works"
  else
    warn "Codex sandbox cannot start (likely unprivileged userns blocked)."
    echo "   Run these yourself, then re-run install.sh:"
    echo "     sudo sysctl kernel.apparmor_restrict_unprivileged_userns=0"
    echo "     echo 'kernel.apparmor_restrict_unprivileged_userns = 0' | sudo tee /etc/sysctl.d/99-codex-bwrap-userns.conf"
    confirm "Continue installing anyway?" || exit 1
  fi
fi

# ── 3. pair.sh ───────────────────────────────────────────────────────────────
say "Installing pair.sh -> $PAIR_SH"
mkdir -p "$SCRIPTS_DIR"
cp "$KIT_DIR/scripts/pair.sh" "$PAIR_SH"
chmod +x "$PAIR_SH"
bash -n "$PAIR_SH" && ok "installed and syntax-checked"

# helper: instantiate a template (replace __PAIR_SH__ with the real path)
render() { sed "s|__PAIR_SH__|$PAIR_SH|g" "$1"; }

# ── 4. Codex side ────────────────────────────────────────────────────────────
say "Codex: AGENTS.md, skill, config, execpolicy rule"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
mkdir -p "$CODEX_HOME/skills/pair-handoff" "$CODEX_HOME/rules"

if grep -q "Pair protocol with Claude Code" "$CODEX_HOME/AGENTS.md" 2>/dev/null; then
  ok "AGENTS.md already has the pair section (skipped)"
else
  { [ -f "$CODEX_HOME/AGENTS.md" ] && echo; render "$KIT_DIR/codex/AGENTS-pair.md"; } >> "$CODEX_HOME/AGENTS.md"
  ok "appended pair section to $CODEX_HOME/AGENTS.md"
fi

render "$KIT_DIR/codex/skills/pair-handoff/SKILL.md" > "$CODEX_HOME/skills/pair-handoff/SKILL.md"
ok "installed skill: pair-handoff"

CFG="$CODEX_HOME/config.toml"
if grep -q '^\[sandbox_workspace_write\]' "$CFG" 2>/dev/null; then
  ok "config.toml already has [sandbox_workspace_write] (verify network_access = true yourself)"
else
  confirm "Append [sandbox_workspace_write] network_access=true to $CFG? (needed so Codex can call the claude CLI)" && {
    printf '\n[sandbox_workspace_write]\nnetwork_access = true\n' >> "$CFG"
    ok "network access enabled for Codex workspace-write sandbox"
  }
fi

RULES="$CODEX_HOME/rules/default.rules"
RULE_LINE="prefix_rule(pattern=[\"bash\", \"$PAIR_SH\"], decision=\"allow\")"
if grep -qF "$PAIR_SH" "$RULES" 2>/dev/null; then
  ok "execpolicy rule already present"
else
  confirm "Append execpolicy allow-rule for pair.sh to $RULES? (pre-approves the delegation channel so Codex doesn't prompt)" && {
    echo "$RULE_LINE" >> "$RULES"
    ok "execpolicy rule added"
  }
fi

# ── 5. Claude side ───────────────────────────────────────────────────────────
say "Claude: skill + CLAUDE.md section"
mkdir -p "$CLAUDE_SKILLS" "$(dirname "$CLAUDE_MD")"
render "$KIT_DIR/claude/skills/pair-protocol.md" > "$CLAUDE_SKILLS/pair-protocol.md"
ok "installed skill: $CLAUDE_SKILLS/pair-protocol.md"

if grep -q "Pair protocol" "$CLAUDE_MD" 2>/dev/null; then
  ok "CLAUDE.md already mentions the pair protocol (skipped)"
else
  { [ -f "$CLAUDE_MD" ] && echo; render "$KIT_DIR/claude/CLAUDE-pair-section.md" \
      | sed "s|the \`pair-protocol\` skill|\`$CLAUDE_SKILLS/pair-protocol.md\`|"; } >> "$CLAUDE_MD"
  ok "appended pair section to $CLAUDE_MD"
fi

# ── 6. done ──────────────────────────────────────────────────────────────────
say "Install complete. Verify with:"
cat <<EOF
   mkdir -p /tmp/pairtest && cd /tmp/pairtest
   bash $PAIR_SH init "tiny test: a hello.py printing hello"
   cat .pair/requirements.md .pair/plan.md
   echo 'print("hello")' > hello.py
   bash $PAIR_SH review "T1"
   bash $PAIR_SH claude "Reply with exactly: pair-network-ok"

   # qwen gate (no model call — must refuse without a recorded approval):
   bash $PAIR_SH qwen "anything"           # expect: refusal, exit 1
   # optional qwen smoke test — ONLY after the human explicitly approves it:
   #   bash $PAIR_SH qwen-approve "reply with exactly: qwen-pair-ok" "<approval note>"
   #   bash $PAIR_SH qwen "reply with exactly: qwen-pair-ok"

Optional: to stop Claude Code prompting before each pair.sh call, add to your
project's .claude/settings.json:
   { "permissions": { "allow": ["Bash(bash $PAIR_SH *)"] } }

See TROUBLESHOOTING.md for every known failure mode and fix.
EOF
