# claude adapter — Claude Code CLI (implementer-capable, and architect-capable
# via a read-only consult lane).
# Sourced by pair.sh / install.sh; must be side-effect-free at source time.
# Env: PAIR_CLAUDE_MODEL (default opus), PAIR_CLAUDE_EFFORT (default high)

claude_display="Claude"

claude_check() { command -v claude >/dev/null 2>&1 && claude --version; }

claude__call() { # OUTFILE SESSION_ID PROMPT PERMISSION_MODE TOOLS_CSV -> stdout: session id only
  local out="$1" sid="$2" prompt="$3" perm="$4" tools="$5" raw new_sid
  raw=$(mktemp)
  # NOTE: prompt must come BEFORE --allowedTools (variadic flag would swallow
  # it as a tool name), and tools are one comma-joined arg for the same reason.
  local args=(-p "$prompt")
  if [ -n "$sid" ]; then args+=(--resume "$sid"); fi
  args+=(--output-format json
         --model "${PAIR_CLAUDE_MODEL:-opus}" --effort "${PAIR_CLAUDE_EFFORT:-high}"
         --permission-mode "$perm"
         --allowedTools "$tools")
  claude "${args[@]}" > "$raw" || { mv "$raw" "$out"; return 1; }
  jq -r '.result // empty' "$raw" > "$out"
  # headless --resume mints a new session id — track it, or later resumes lose context
  new_sid=$(jq -r '.session_id // empty' "$raw")
  rm -f "$raw"
  printf '%s\n' "${new_sid:-$sid}"
}

claude_consult() { # architect lane: read-only tools, default permission mode
  claude__call "$1" "$2" "$3" default "Read,Glob,Grep"
}

claude_implement() {
  claude__call "$1" "$2" "$3" acceptEdits "Bash,Edit,Write,Read,Glob,Grep,TodoWrite"
}

claude_install() { # KIT_DIR PAIR_SH — uses install.sh helpers (ok/render)
  local kit="$1"
  local skills="${CLAUDE_SKILLS:-$HOME/.claude/pair-skills}"
  local md="${CLAUDE_MD:-$HOME/.claude/CLAUDE.md}"
  mkdir -p "$skills" "$(dirname "$md")"
  render "$kit/agents/claude/skills/pair-protocol.md" > "$skills/pair-protocol.md"
  ok "installed skill: $skills/pair-protocol.md"
  if grep -q "Pair protocol" "$md" 2>/dev/null; then
    ok "CLAUDE.md already mentions the pair protocol (skipped)"
  else
    { [ -f "$md" ] && echo; render "$kit/agents/claude/CLAUDE-pair-section.md" \
        | sed "s|the \`pair-protocol\` skill|\`$skills/pair-protocol.md\`|"; } >> "$md"
    ok "appended pair section to $md"
  fi
  return 0
}
