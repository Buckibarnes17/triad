# opencode adapter — opencode CLI (architect-capable via the read-only 'plan'
# agent; implementer/junior-capable via the default build agent).
# Sourced by pair.sh / install.sh; must be side-effect-free at source time.
# Env: PAIR_OPENCODE_BIN   absolute path (default ~/.opencode/bin/opencode —
#                          opencode is typically not on non-login-shell PATH)
#      PAIR_OPENCODE_MODEL optional model override, format provider/model
#                          (e.g. opencode/deepseek-v4-flash-free), passed as -m

opencode_display="OpenCode"

opencode__bin() { printf '%s' "${PAIR_OPENCODE_BIN:-$HOME/.opencode/bin/opencode}"; }

opencode_check() {
  local bin; bin=$(opencode__bin)
  [ -x "$bin" ] && echo "$bin (version $("$bin" --version 2>/dev/null | head -1 || echo unknown))"
}

opencode__call() { # OUTFILE SESSION_ID PROMPT EXTRA_ARGS... -> stdout: session id only
  local out="$1" sid="$2" prompt="$3" raw new_sid bin
  shift 3
  bin=$(opencode__bin)
  [ -x "$bin" ] || { echo "opencode adapter: binary not found/executable at $bin — install it or set PAIR_OPENCODE_BIN" >&2; return 1; }
  raw=$(mktemp)
  local args=(run "$prompt" --format json "$@")
  if [ -n "$sid" ]; then args+=(-s "$sid"); fi
  if [ -n "${PAIR_OPENCODE_MODEL:-}" ]; then args+=(-m "$PAIR_OPENCODE_MODEL"); fi
  "$bin" "${args[@]}" > "$raw" 2>/dev/null || { mv "$raw" "$out"; return 1; }
  # output is JSONL (one event per line, NOT an array); reply text arrives in
  # .type=="text" events at .part.text — concatenate them in order
  jq -rj 'select(.type=="text") | .part.text' "$raw" > "$out"
  new_sid=$(jq -r '.sessionID // empty' "$raw" | tail -1)
  if [ -n "${PAIR_USAGE_FILE:-}" ]; then
    jq -s '
      ([.[] | select(.type == "step_finish" and (.part.tokens | type == "object"))]
        | last // null) as $finish
      | if $finish == null then empty else
          ($finish.part.tokens // {}) as $t
          | (($t.cache.read // $t.cache_read // 0)) as $cached
          | {
              last_input_tokens: (($t.input // $t.input_tokens // 0) + $cached),
              call_total_tokens: (($t.input // $t.input_tokens // 0) + $cached
                + ($t.output // $t.output_tokens // 0)
                + ($t.reasoning // $t.reasoning_tokens // 0)),
              cached_input_tokens: $cached,
              tool_calls: ([.[] | select(.type == "tool_use" or .type == "tool_call")] | length)
            }
        end
    ' "$raw" > "$PAIR_USAGE_FILE" 2>/dev/null || :
  fi
  if [ ! -s "$out" ]; then
    mv "$raw" "$out"
    echo "opencode adapter: could not parse any text event — raw output kept" >&2
    return 1
  fi
  rm -f "$raw"
  printf '%s\n' "${new_sid:-$sid}"
}

opencode_consult() { # architect lane: built-in 'plan' agent has no edit tools
  opencode__call "$1" "$2" "$3" --agent plan
}

opencode_implement() { # write lane: default build agent, permissions auto-approved
  opencode__call "$1" "$2" "$3" --dangerously-skip-permissions
}

# no opencode_review: opencode has no native review command — pair.sh review
# uses the generic fallback (consult with the git diff embedded)
