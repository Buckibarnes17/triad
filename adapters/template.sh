# template adapter — copy to adapters/<name>.sh and replace every "template".
# Full contract: docs/ADAPTERS.md. The short version:
#   - sourced by pair.sh/install.sh: NO side effects at the top level
#   - _consult/_implement: reply text -> OUTFILE, stdout = session id ONLY
#   - SESSION_ID empty = fresh session, non-empty = resume
#   - adapter name (filename minus .sh) must match ^[a-z][a-z0-9_]*$
# Env: PAIR_TEMPLATE_BIN — path to your CLI (example convention)

template_display="Template"   # shown in prompts and ### <Agent> — <ts> headers

template__bin() { printf '%s' "${PAIR_TEMPLATE_BIN:-template-cli}"; }

template_check() { # one line of version info; nonzero = not usable
  command -v "$(template__bin)" >/dev/null 2>&1 && "$(template__bin)" --version
}

# Architect capability. Delete this function if your CLI should never be
# architect (the engine will then refuse the role). Keep it READ-ONLY: use
# your CLI's sandbox/tool-restriction flags if it has them.
template_consult() { # OUTFILE SESSION_ID PROMPT -> stdout: session id only
  local out="$1" sid="$2" prompt="$3" raw new_sid
  raw=$(mktemp)
  local args=()
  if [ -n "$sid" ]; then args+=(--resume "$sid"); fi          # <- your resume flag
  # invoke your CLI headless; ALL noise to stderr or a temp file, never stdout
  "$(template__bin)" --prompt "$prompt" --json "${args[@]}" > "$raw" \
    || { mv "$raw" "$out"; return 1; }                        # keep raw output for diagnosis
  # extract reply text and (new) session id from your CLI's output format:
  jq -r '.reply // empty' "$raw" > "$out"
  new_sid=$(jq -r '.session // empty' "$raw")
  rm -f "$raw"
  printf '%s\n' "${new_sid:-$sid}"
}

# Implementer/junior capability. Delete if your CLI should never write code.
# Grant edit+shell here — most CLIs' headless defaults deny writes and tasks
# would "succeed" without changing files.
template_implement() { # OUTFILE SESSION_ID PROMPT -> stdout: session id only
  # often identical to _consult but with permissive flags, e.g.:
  #   args+=(--auto-approve-edits --allow-shell)
  template_consult "$1" "$2" "$3"
}

# OPTIONAL: native review command (delete unless your CLI has one — without
# it the engine falls back to _consult with the git diff embedded).
# template_review() { # OUTFILE SESSION_ID PROMPT — APPEND review text to OUTFILE
#   "$(template__bin)" review - <<<"$3" >> "$1" 2>&1
# }

# OPTIONAL: installer hook — per-agent setup. Helpers available: say/ok/warn/
# confirm (respects --yes) / render (substitutes __PAIR_SH__ in agents/<name>/
# doc templates). Gate every machine-level change behind confirm.
# template_install() { # KIT_DIR PAIR_SH
#   ok "template: nothing to set up"
#   return 0
# }
