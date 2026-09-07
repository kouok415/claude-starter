#!/usr/bin/env bash
#
# PreToolUse hook (Bash) — tripwire for catastrophic or sensitive commands.
#
# Two tiers, mirroring the stop-gate's forbidden-verify philosophy (tiny
# list, absolute, logged):
#
#   deny (exit 2, stderr fed back to Claude, logged):
#     - force-push in any spelling (--force / --force-with-lease / -f)
#     - sudo
#     - rm -rf on the filesystem root
#   ask (JSON permissionDecision, human confirms):
#     - rm -rf leaving the project tree (absolute, ~/, $HOME/, ..) — except
#       inside the session's own /tmp/claude-*/…/scratchpad tree, which the
#       harness itself discards. The CLI drops hook asks under
#       bypassPermissions, so the ~/ $HOME/ ../ spellings are mirrored as
#       declarative ask rules in settings.json (v3.14.3) — those prompt in
#       every mode and can never touch a /tmp scratchpad path. The project'"'"'s
#       own tree is exempt like the scratchpad (v3.14.4).
#     - the ask tier reads the command with heredoc BODIES removed (v3.14.4):
#       prose in a memory-file write is not a command. The deny tier reads
#       the full text.
#     - commands touching .env files (H1) — .env.example/sample/template/dist
#       are exempt
#
# This is contains-matching on the command string: stronger than the
# prefix-matched permission rules in settings.json (which it complements,
# not replaces), but still a TRIPWIRE, not a sandbox — `bash -c`, variable
# expansion, or piping to sh can evade it. The goal is to stop the common
# spelling of an irreversible mistake and leave an audit line, nothing more.
#
# Denies are absolute: no once-per-session yield. The correct way to run a
# denied command is for the human to run it themselves (or temporarily
# allow it) — that IS the approval the global rules require.

set -uo pipefail

ROOT="${CLAUDE_PROJECT_DIR:-.}"

# Shared destructive-op matchers — one source with stop-gate.sh (F8/F12).
# Fallback: the v3.7–v3.9 built-ins, so a partially-synced project
# degrades to the old tripwire, never to none.
_GP="$(dirname "${BASH_SOURCE[0]}")/guard-patterns.sh"
# shellcheck source=guard-patterns.sh
[ -f "$_GP" ] && . "$_GP"
: "${GUARD_SUDO:=(^|[[:space:];&|(])sudo([[:space:]]|\$)}"
: "${GUARD_FORCE_PUSH:=git[[:space:]]+push[^|;&]*[[:space:]](--force(-with-lease[^[:space:]]*)?|-f)([[:space:]]|\$)}"
: "${GUARD_RM_RF_ROOT:=(^|[[:space:];&|(])rm[[:space:]]+-(rf|fr)[[:alnum:]]*[[:space:]]+/([[:space:]]|\*|\$)}"
: "${GUARD_RM_RF_ABS:=(^|[[:space:];&|(])rm[[:space:]]+-(rf|fr)[[:alnum:]]*[[:space:]]+/[^[:space:]]}"
: "${GUARD_SCRATCHPAD:=/tmp/claude-[[:alnum:]_.-]+/[[:alnum:]_.-]+/[[:alnum:]_.-]+/scratchpad[[:alnum:]_./@+~-]*}"

payload="$(cat 2>/dev/null || true)"

# Extract tool_input.command; fall back to matching the raw payload (a
# false positive from JSON noise is acceptable for a tripwire, a silent
# parser failure is not).
cmd="$(printf '%s' "$payload" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("tool_input", {}).get("command", ""))
except Exception:
    pass
' 2>/dev/null || true)"
[ -n "$cmd" ] || cmd="$payload"

log_deny() { # $1 = reason
  [ -d "$ROOT/.ai_context" ] || return 0
  mkdir -p "$ROOT/.ai_context/private" 2>/dev/null || return 0
  printf '%s\tDENY\t%s\t%s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$1" \
    "$(printf '%s' "$cmd" | tr '\t\n' '  ' | cut -c1-300)" \
    >> "$ROOT/.ai_context/private/bash-guard.log" 2>/dev/null || true
}

deny() { # $1 = short reason, $2 = guidance
  log_deny "$1"
  {
    printf 'BASH GUARD — blocked (%s). This command is never run unattended:\n' "$1"
    printf '$ %s\n' "$cmd"
    printf '%s\n' "$2"
  } >&2
  exit 2
}

ask() { # $1 = reason shown in the confirmation prompt (static text only)
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"}}\n' "$1"
  exit 0
}

# --- deny tier ---------------------------------------------------------------
if printf '%s' "$cmd" | grep -Eq "$GUARD_SUDO"; then
  deny 'sudo' 'Privileged commands need the human: ask them to run it (e.g. via `! sudo ...`).'
fi

# Any force-push spelling: --force / --force-with-lease / -f flags scoped to
# the push's pipeline segment, plus the flagless `+refspec` form (F12).
if printf '%s' "$cmd" | grep -Eq "$GUARD_FORCE_PUSH"; then
  deny 'force-push' 'Force-pushes require explicit human approval (global git rules): the human runs it, or temporarily allows it.'
fi

# Recursive+force rm on the root in any flag arrangement, including
# flag-separated roots like `rm -rf --no-preserve-root /` (F12).
if printf '%s' "$cmd" | grep -Eq "$GUARD_RM_RF_ROOT"; then
  deny 'rm -rf on /' 'Refusing to delete from the filesystem root.'
fi

# --- ask tier ----------------------------------------------------------------
# The ask tier reads a PROBE, not the raw command (v3.14.4):
#   1. heredoc bodies are dropped — prose written into a memory file is not
#      a command. 17 of the 48 subagent `.env` stalls in the fleet since
#      2026-08-01 were a plan or state.md that mentioned `.env`; each parked
#      a verifier for a median 10 minutes, hours overnight. The deny tier
#      above keeps the full text, so `bash <<EOF` smuggling a denied command
#      is still caught. Python failure or an unterminated heredoc ⇒ the
#      full command (fail towards asking). Boundary: a heredoc that is
#      itself EXECUTED (`python3 - <<PY` calling os.system) is now outside
#      the ask tier — the same class as `bash -c`; the deny tier sees it.
#   2. for the rm test, paths the harness owns are scrubbed: the session
#      scratchpad (GUARD_SCRATCHPAD, v3.14.1) and the project's own tree
#      ($CLAUDE_PROJECT_DIR/…, v3.14.4 — a relative `rm -rf build` was
#      always silent; its absolute spelling should not cost a click). Any
#      `..` in the command keeps the full string — fail towards asking
#      rather than reason about where a traversal lands.
ask_probe="$(printf '%s' "$cmd" | python3 -c '
import re, sys
s = sys.stdin.read()
sys.stdout.write(re.sub(r"(<<-?[ \t]*([\x27\"]?)(\w+)\2[^\n]*\n)(?:.*?\n)?(^[ \t]*\3[ \t]*$)", r"\1\4", s, flags=re.S | re.M))
' 2>/dev/null)" || ask_probe="$cmd"
[ -n "$ask_probe" ] || ask_probe="$cmd"

rm_probe="$ask_probe"
case "$cmd" in
  *..*) ;;
  *)
    tree_re=""
    case "${ROOT%/}" in
      /?*) tree_re="$(printf '%s' "${ROOT%/}" | sed 's/[][\\.*^$+?(){}|#]/\\&/g')/[[:alnum:]_./@+~-]+" ;;
    esac
    rm_probe="$(printf '%s' "$ask_probe" | sed -E "s#${GUARD_SCRATCHPAD}##g${tree_re:+; s#${tree_re}##g}")" ;;
esac
if printf '%s' "$rm_probe" | grep -Eq "$GUARD_RM_RF_ABS"; then
  ask 'rm -rf beyond the project tree (absolute, ~/, $HOME/, ..) — confirm the target is disposable'
fi

stripped="$(printf '%s' "$ask_probe" | sed -E 's/\.env\.(example|sample|template|dist)//g')"
if printf '%s' "$stripped" | grep -Eq '(^|[^[:alnum:]_])\.env(\.[[:alnum:]_.-]+)?([^[:alnum:]_.-]|$)'; then
  ask 'touches .env files (H1: secrets) — confirm this should happen'
fi

if printf '%s' "$ask_probe" | grep -Eq '(^|[^[:alnum:]_])\.secrets/'; then
  ask 'touches .secrets/ (runtime-only credentials, H1) — confirm this should happen'
fi

# Checkpoint ack files record HUMAN sign-off on a `- checkpoint: human`
# milestone (v3.14). The natural path is the human's own shell (`! touch
# ...` bypasses hooks entirely); a model-issued write must surface this
# confirmation — approving it IS the sign-off, one click, on the record.
if printf '%s' "$ask_probe" | grep -Eq '\.ai_context/tasks/[^[:space:]/]+/ack-'; then
  ask 'checkpoint sign-off: ack files record HUMAN approval — confirm only if you, the human, are signing off this checkpoint'
fi

exit 0
