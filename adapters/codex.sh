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

codex_driver_usage() { # USAGE_OUT — best-effort resident-context telemetry for an
  # INTERACTIVE Codex session driving pair.sh from this project directory (the
  # engine's driver lane). Codex appends token_count events to its local rollout
  # JSONL (~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl) as a session runs; the
  # freshest rollout whose recorded cwd matches this project is the driver —
  # written moments ago by the very turn that invoked pair.sh. Bounded local
  # read only: no network, no quota, no prompt content copied. Nonzero return =
  # no fresh matching rollout; the engine falls back to its estimate.
  local out="$1" dir="${CODEX_HOME:-$HOME/.codex}/sessions" f cwd_norm f_cwd now_s mtime
  [ -d "$dir" ] || return 1
  cwd_norm=$(pwd -W 2>/dev/null || pwd)              # Git Bash: Windows form, matching what codex records
  cwd_norm=$(printf '%s' "$cwd_norm" | tr '\\' '/' | tr '[:upper:]' '[:lower:]')
  now_s=$(date +%s)
  while IFS= read -r f; do
    mtime=$(date -r "$f" +%s 2>/dev/null || echo 0)
    # ls -t order: once a file is stale, everything after it is staler — a
    # stale rollout is an old session on disk, not the live driver
    [ $((now_s - mtime)) -le 21600 ] || break
    f_cwd=$(head -n1 "$f" | jq -r '.payload.cwd // empty' 2>/dev/null \
              | tr '\\' '/' | tr '[:upper:]' '[:lower:]')
    [ "$f_cwd" = "$cwd_norm" ] || continue
    tail -n 400 "$f" | jq -s '
      [.[] | select(.type == "event_msg" and .payload.type == "token_count"
                    and ((.payload.info | type) == "object"))] | last
      | if . == null then empty else
          {last_input_tokens: (.payload.info.last_token_usage.input_tokens // 0),
           cached_input_tokens: (.payload.info.last_token_usage.cached_input_tokens // 0)}
          + (if (.payload.info.model_context_window // 0) > 0
             then {context_window: .payload.info.model_context_window} else {} end)
        end' > "$out" 2>/dev/null
    [ -s "$out" ] && return 0
    return 1
  done < <(ls -t "$dir"/*/*/*/rollout-*.jsonl 2>/dev/null | head -15)
  return 1
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
