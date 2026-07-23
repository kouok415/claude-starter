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
#     - rm -rf on any other absolute path
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
if printf '%s' "$cmd" | grep -Eq "$GUARD_RM_RF_ABS"; then
  ask 'rm -rf on an absolute path — confirm the target is disposable'
fi

stripped="$(printf '%s' "$cmd" | sed -E 's/\.env\.(example|sample|template|dist)//g')"
if printf '%s' "$stripped" | grep -Eq '(^|[^[:alnum:]_])\.env(\.[[:alnum:]_.-]+)?([^[:alnum:]_.-]|$)'; then
  ask 'touches .env files (H1: secrets) — confirm this should happen'
fi

if printf '%s' "$cmd" | grep -Eq '(^|[^[:alnum:]_])\.secrets/'; then
  ask 'touches .secrets/ (runtime-only credentials, H1) — confirm this should happen'
fi

exit 0
