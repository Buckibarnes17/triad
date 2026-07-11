# codex adapter — Codex CLI (architect-capable: consult + native review).
# Sourced by pair.sh / install.sh; must be side-effect-free at source time.
# Contract: <name>_display, <name>_check, <name>_consult|_implement|_review
# take OUTFILE SESSION_ID PROMPT and print ONLY the session id on stdout.
# Env: PAIR_CODEX_MODEL (optional, e.g. o3 — passed as -m)

codex_display="Codex"

codex_check() { command -v codex >/dev/null 2>&1 && codex --version; }

codex__write_usage() { # JSONL events -> optional PAIR_USAGE_FILE
  local events="$1"
  [ -n "${PAIR_USAGE_FILE:-}" ] || return 0
  jq -s '
    ([.[] | select(.type == "turn.completed" and (.usage | type == "object"))] | last // null) as $turn
    | if $turn == null then empty else
        ($turn.usage // {}) as $u
        | {
            last_input_tokens: ($u.input_tokens // 0),
            call_total_tokens: (($u.input_tokens // 0) + ($u.output_tokens // 0)),
            cached_input_tokens: ($u.cached_input_tokens // 0),
            tool_calls: ([.[] | select(.type == "item.completed")
              | .item.type // empty
              | select(. == "command_execution" or . == "mcp_tool_call"
                or . == "web_search" or . == "file_change") ] | length)
          }
      end
  ' "$events" > "$PAIR_USAGE_FILE" 2>/dev/null || :
}

codex_consult() { # OUTFILE SESSION_ID PROMPT -> stdout: session id only
  local out="$1" sid="$2" prompt="$3" events margs=()
  if [ -n "${PAIR_CODEX_MODEL:-}" ]; then margs=(-m "$PAIR_CODEX_MODEL"); fi
  if [ -z "$sid" ]; then
    events=$(mktemp)
    codex exec --json -s read-only -C "$PWD" --skip-git-repo-check \
      "${margs[@]}" -o "$out" - <<<"$prompt" > "$events" || { rm -f "$events"; return 1; }
    sid=$(jq -r 'select(.type=="thread.started") | .thread_id' "$events" | head -1)
    if [ -z "$sid" ]; then
      echo "codex adapter: could not capture session id (events kept at $events)" >&2
      return 1
    fi
    codex__write_usage "$events"
    rm -f "$events"
  else
    # NOTE: exec resume has no -s/-C flags; sandbox set via -c, cwd is project root
    events=$(mktemp)
    codex exec resume "$sid" --json -c 'sandbox_mode="read-only"' --skip-git-repo-check \
      "${margs[@]}" -o "$out" - <<<"$prompt" > "$events" \
      || { rm -f "$events"; return 1; }
    codex__write_usage "$events"
    rm -f "$events"
  fi
  printf '%s\n' "$sid"
}

codex_review() { # OUTFILE SESSION_ID PROMPT — appends review text; returns CLI exit code
  local out="$1" prompt="$3" margs=() rc=0
  if [ -n "${PAIR_CODEX_MODEL:-}" ]; then margs=(-m "$PAIR_CODEX_MODEL"); fi
  # NOTE: codex review has no -C flag (reviews repo at cwd — pair.sh always runs
  # from the project root) and --uncommitted cannot be combined with a custom
  # prompt, so the prompt itself scopes the review to uncommitted changes.
  codex review "${margs[@]}" - <<<"$prompt" >> "$out" 2>&1 || rc=$?
  return "$rc"
}

codex_install() { # KIT_DIR PAIR_SH — uses install.sh helpers (ok/warn/confirm/render)
  local kit="$1" pair_sh="$2"
  local codex_home="${CODEX_HOME:-$HOME/.codex}"

  if [ "$(uname -s)" = Linux ]; then
    # bubblewrap needs unprivileged user namespaces; the installer never touches
    # kernel settings itself
    if codex sandbox linux -- true >/dev/null 2>&1; then
      ok "codex Linux sandbox works"
    else
      warn "Codex sandbox cannot start (likely unprivileged userns blocked)."
      echo "   Run these yourself, then re-run install.sh:"
      echo "     sudo sysctl kernel.apparmor_restrict_unprivileged_userns=0"
      echo "     echo 'kernel.apparmor_restrict_unprivileged_userns = 0' | sudo tee /etc/sysctl.d/99-codex-bwrap-userns.conf"
      confirm "Continue installing anyway?" || return 1
    fi
  fi

  mkdir -p "$codex_home/skills/pair-handoff" "$codex_home/skills/context-budget" "$codex_home/rules"

  if grep -q "Triad Protocol" "$codex_home/AGENTS.md" 2>/dev/null; then
    ok "AGENTS.md already has the Triad section (skipped)"
  else
    { [ -f "$codex_home/AGENTS.md" ] && echo; render "$kit/agents/codex/AGENTS-pair.md"; } >> "$codex_home/AGENTS.md"
    ok "appended Triad section to $codex_home/AGENTS.md"
  fi

  render "$kit/agents/codex/skills/pair-handoff/SKILL.md" > "$codex_home/skills/pair-handoff/SKILL.md"
  ok "installed skill: pair-handoff"
  render "$kit/agents/codex/skills/context-budget/SKILL.md" > "$codex_home/skills/context-budget/SKILL.md"
  ok "installed skill: context-budget"

  local cfg="$codex_home/config.toml"
  if grep -q '^\[sandbox_workspace_write\]' "$cfg" 2>/dev/null; then
    ok "config.toml already has [sandbox_workspace_write] (verify network_access = true yourself)"
  else
    confirm "Append [sandbox_workspace_write] network_access=true to $cfg? (needed so Codex can call other agent CLIs)" && {
      printf '\n[sandbox_workspace_write]\nnetwork_access = true\n' >> "$cfg"
      ok "network access enabled for Codex workspace-write sandbox"
    }
  fi

  local rules="$codex_home/rules/default.rules"
  local rule_line="prefix_rule(pattern=[\"bash\", \"$pair_sh\"], decision=\"allow\")"
  if grep -qF "$pair_sh" "$rules" 2>/dev/null; then
    ok "execpolicy rule already present"
  else
    confirm "Append execpolicy allow-rule for pair.sh to $rules? (pre-approves the delegation channel so Codex doesn't prompt)" && {
      echo "$rule_line" >> "$rules"
      ok "execpolicy rule added"
    }
  fi
  return 0
}
