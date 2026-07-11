#!/usr/bin/env bash
# install.sh — set up the Triad protocol (pluggable assistant adapters) on this machine.
#
# Usage:
#   ./install.sh [--scripts-dir DIR] [--agents "a b c"]
#                [--claude-md FILE] [--claude-skills DIR] [--yes]
#
# Defaults:
#   --scripts-dir    ~/.local/bin
#   --agents         union of PAIR_ARCHITECT / PAIR_IMPLEMENTER / PAIR_JUNIOR
#                    (i.e. "codex claude qwen" when none are exported)
#   --claude-md      ~/.claude/CLAUDE.md          (claude adapter; user-global —
#                                                  use a project CLAUDE.md to scope it)
#   --claude-skills  ~/.claude/pair-skills        (claude adapter)
#
# Each agent's setup lives in its adapter (adapters/<name>.sh, <name>_install);
# this script only checks generic prereqs, copies pair.sh + adapters, and loops.
# The installer NEVER touches kernel settings; if an agent's sandbox is broken
# its install hook prints the exact sudo commands for you to run yourself.

set -euo pipefail

KIT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_DIR="$HOME/.local/bin"
AGENTS=""
ASSUME_YES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --scripts-dir)   SCRIPTS_DIR="$2"; shift 2 ;;
    --agents)        AGENTS="$2"; shift 2 ;;
    --claude-md)     CLAUDE_MD="$2"; shift 2 ;;      # read by the claude adapter
    --claude-skills) CLAUDE_SKILLS="$2"; shift 2 ;;  # read by the claude adapter
    --yes)           ASSUME_YES=1; shift ;;
    *) echo "unknown arg: $1"; exit 1 ;;
  esac
done

PAIR_SH="$SCRIPTS_DIR/pair.sh"
ADAPTERS_DIR="$SCRIPTS_DIR/pair-adapters"
JUNIOR_AGENT="${PAIR_JUNIOR-qwen}"
[ -n "$AGENTS" ] || AGENTS="${PAIR_ARCHITECT:-codex} ${PAIR_IMPLEMENTER:-claude} $JUNIOR_AGENT"
# shellcheck disable=SC2086 — word-splitting the agent list is intended
AGENTS=$(printf '%s\n' $AGENTS | awk 'NF && !seen[$0]++')

# helpers — adapter <name>_install hooks may use all of these
say()  { printf '\n== %s\n' "$*"; }
ok()   { printf '   OK  %s\n' "$*"; }
warn() { printf '   !!  %s\n' "$*"; }

confirm() {
  [ "$ASSUME_YES" = 1 ] && return 0
  printf '%s [y/N] ' "$1"; read -r a; [ "$a" = y ] || [ "$a" = Y ]
}

# instantiate a template (replace __PAIR_SH__ with the real path)
render() { sed "s|__PAIR_SH__|$PAIR_SH|g" "$1"; }

# ── 1. generic prerequisites ─────────────────────────────────────────────────
say "Checking prerequisites"
MISSING=0
for bin in jq git; do
  if command -v "$bin" >/dev/null 2>&1; then ok "$bin ($(command -v "$bin"))"
  else warn "$bin NOT FOUND"; MISSING=1; fi
done
[ "$MISSING" = 1 ] && { echo "Install the missing tools and re-run."; exit 1; }

# ── 2. pair.sh + adapters ────────────────────────────────────────────────────
say "Installing pair.sh -> $PAIR_SH (adapters -> $ADAPTERS_DIR/)"
mkdir -p "$ADAPTERS_DIR"
cp "$KIT_DIR/scripts/pair.sh" "$PAIR_SH"
chmod +x "$PAIR_SH"
cp "$KIT_DIR"/adapters/*.sh "$ADAPTERS_DIR/"
bash -n "$PAIR_SH"
for f in "$ADAPTERS_DIR"/*.sh; do bash -n "$f"; done
ok "installed and syntax-checked"

# ── 3. per-agent setup ───────────────────────────────────────────────────────
for a in $AGENTS; do
  say "Agent: $a"
  [[ "$a" =~ ^[a-z][a-z0-9_]*$ ]] || { warn "invalid agent name '$a'"; exit 1; }
  ADAPTER="$KIT_DIR/adapters/$a.sh"
  [ -f "$ADAPTER" ] || { warn "no adapter at $ADAPTER — write one (see README: Adding an assistant)"; exit 1; }
  # shellcheck source=/dev/null
  . "$ADAPTER"
  if INFO=$("${a}_check" 2>/dev/null); then
    ok "$a: $(echo "$INFO" | head -1)"
  elif [ "$a" = "$JUNIOR_AGENT" ]; then
    warn "$a not usable yet — 'pair.sh junior' will refuse until it is (junior lane is optional)"
  else
    warn "$a NOT FOUND — required for its role. Install it and re-run."
    exit 1
  fi
  if declare -F "${a}_install" >/dev/null; then
    "${a}_install" "$KIT_DIR" "$PAIR_SH"
  fi
done

# ── 4. done ──────────────────────────────────────────────────────────────────
say "Install complete. Verify with:"
cat <<EOF
   mkdir -p /tmp/pairtest && cd /tmp/pairtest
   bash $PAIR_SH init "tiny test: a hello.py printing hello"
   cat .pair/requirements.md .pair/plan.md
   echo 'print("hello")' > hello.py
   bash $PAIR_SH review "T1"
   bash $PAIR_SH implement "Reply with exactly: pair-network-ok"
   bash $PAIR_SH status                       # context counters + checkpoint history
   bash $PAIR_SH checkpoint architect        # durable manual handoff, no rollover

   # junior gate (no model call — must refuse without a recorded approval):
   bash $PAIR_SH junior "anything"           # expect: refusal, exit 1
   # optional junior smoke test — ONLY after the human explicitly approves it:
   #   bash $PAIR_SH junior-approve "reply with exactly: junior-pair-ok" "<approval note>"
   #   bash $PAIR_SH junior "reply with exactly: junior-pair-ok"

Different lineup? Roles are set at init time, e.g.:
   PAIR_ARCHITECT=claude PAIR_IMPLEMENTER=claude PAIR_JUNIOR= bash $PAIR_SH init "<brief>"

Optional: to stop Claude Code prompting before each pair.sh call, add to your
project's .claude/settings.json:
   { "permissions": { "allow": ["Bash(bash $PAIR_SH *)"] } }

See TROUBLESHOOTING.md for every known failure mode and fix.
EOF
