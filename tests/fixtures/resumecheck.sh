# Test-only adapter for resume recovery and junior no-retry invariants.
# Sourced by pair.sh; intentionally has no source-time side effects.

resumecheck_display="ResumeCheck"
resumecheck_check() { echo "resumecheck fixture"; }

resumecheck__call() { # OUTFILE SESSION_ID PROMPT -> stdout session id
  local out="$1" sid="$2" prompt="$3" dir marker n mode
  dir="${MOCK_COUNTERS:?}"; mode="${MOCK_RESUME_MODE:-ok}"
  if [ -n "$sid" ] && [ "$mode" != ok ]; then
    marker="$dir/resumecheck-${mode}-${sid}.seen"
    if [ ! -f "$marker" ]; then
      printf 'SECRET_AT_BYTE_ZERO diagnostic for %s\n' "$sid" > "$out"
      printf 'seen\n' > "$marker"
      printf 'resume-attempt:%s:%s\n' "$mode" "$sid" >> "${MOCK_LOG:-/dev/null}"
      [ "$mode" = rc3 ] && return 3
      return 1
    fi
  fi
  if [ -z "$sid" ]; then
    n=$(cat "$dir/resumecheck.n" 2>/dev/null || echo 0); n=$((n + 1))
    printf '%s\n' "$n" > "$dir/resumecheck.n"
    sid="resumecheck-$n"
  fi
  printf 'PROMPT:%s\n' "$prompt" >> "${MOCK_LOG:-/dev/null}"
  if [[ "$prompt" == *"=== REQUIREMENTS ==="* ]]; then
    printf '%s\n' '=== REQUIREMENTS ===' 'fixture requirements' '=== PLAN ===' 'T1: fixture task' > "$out"
  else
    printf 'clean-result:%s\n' "$sid" > "$out"
  fi
  printf '%s\n' "$sid"
}

resumecheck_consult() { resumecheck__call "$1" "$2" "$3"; }
resumecheck_implement() { resumecheck__call "$1" "$2" "$3"; }
