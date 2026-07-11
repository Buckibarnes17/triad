# qwen adapter — Qwen Code CLI (implementer/junior-capable).
# Sourced by pair.sh / install.sh; must be side-effect-free at source time.
# Env: PAIR_QWEN_BIN      absolute path (default ~/.local/bin/qwen — qwen is
#                         typically not on non-login-shell PATH)
#      PAIR_QWEN_APPROVAL headless default mode denies edits/shell; the default
#                         'yolo' mirrors Claude's acceptEdits + Bash grant

qwen_display="Qwen"

qwen__bin() { printf '%s' "${PAIR_QWEN_BIN:-$HOME/.local/bin/qwen}"; }

qwen_check() {
  local bin; bin=$(qwen__bin)
  [ -x "$bin" ] && echo "$bin (version $("$bin" --version 2>/dev/null || echo unknown))"
}

qwen_implement() { # OUTFILE SESSION_ID PROMPT -> stdout: session id only
  local out="$1" sid="$2" prompt="$3" raw new_sid bin
  bin=$(qwen__bin)
  [ -x "$bin" ] || { echo "qwen adapter: binary not found/executable at $bin — install it or set PAIR_QWEN_BIN" >&2; return 1; }
  raw=$(mktemp)
  local args=()
  if [ -n "$sid" ]; then args+=(-r "$sid"); fi
  args+=(-p "$prompt" -o json --approval-mode "${PAIR_QWEN_APPROVAL:-yolo}")
  "$bin" "${args[@]}" > "$raw" || { mv "$raw" "$out"; return 1; }
  # output is a JSON event array; the final type=="result" event carries the reply
  jq -r '[.[] | select(.type=="result")] | last | .result // empty' "$raw" > "$out"
  new_sid=$(jq -r '[.[] | select(.type=="result")] | last | .session_id // empty' "$raw")
  if [ -n "${PAIR_USAGE_FILE:-}" ]; then
    jq '
      ([.[] | select(.type == "result")] | last // {}) as $r
      | ($r.usage // $r.stats.usage // null) as $u
      | if ($u | type) != "object" then empty else
          {
            last_input_tokens: ($u.input_tokens // $u.inputTokens // 0),
            call_total_tokens: (($u.input_tokens // $u.inputTokens // 0)
              + ($u.output_tokens // $u.outputTokens // 0)),
            cached_input_tokens: ($u.cached_input_tokens // $u.cachedInputTokens // 0),
            tool_calls: ([.[] | select(.type == "tool_use" or .type == "tool_call")] | length)
          }
          + (if ($u.context_window // $u.contextWindow // null) != null
             then {context_window: ($u.context_window // $u.contextWindow)} else {} end)
        end
    ' "$raw" > "$PAIR_USAGE_FILE" 2>/dev/null || :
  fi
  if [ ! -s "$out" ]; then
    mv "$raw" "$out"
    echo "qwen adapter: could not parse result — raw output kept" >&2
    return 1
  fi
  rm -f "$raw"
  printf '%s\n' "${new_sid:-$sid}"
}

qwen_install() { # KIT_DIR PAIR_SH — uses install.sh helpers (ok/warn)
  local bin; bin=$(qwen__bin)
  if [ -x "$bin" ]; then
    ok "qwen ($bin)"
  else
    warn "qwen not found at $bin — 'pair.sh junior' will refuse until installed"
    echo "   (optional) install user-local: npm install -g --prefix ~/.local @qwen-code/qwen-code"
    echo "   or point pair.sh at it: export PAIR_QWEN_BIN=/path/to/qwen"
  fi
  return 0
}
