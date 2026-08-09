#!/usr/bin/env bash
#
# task-statusline.sh — one-line /task position for a Claude Code statusline.
#
# Opt-in (this template never overrides your statusline by default) — add to
# .claude/settings.json or your user settings:
#   "statusLine": { "type": "command",
#                   "command": "bash scripts/task-statusline.sh" }
#
# Reads the statusline JSON on stdin (workspace current_dir / cwd), falls
# back to CLAUDE_PROJECT_DIR / PWD. No active task → prints nothing.

set -uo pipefail

# CJK-safe truncation (see task-status.sh): bash counts characters only
# under a UTF-8 locale; without one this degrades to byte-truncation.
if locale -a 2>/dev/null | grep -qiE '^C\.utf-?8$'; then
  export LC_ALL=C.UTF-8
elif locale -a 2>/dev/null | grep -qiE '^en_US\.utf-?8$'; then
  export LC_ALL=en_US.UTF-8
fi

in="$(cat 2>/dev/null || true)"
dir="$(printf '%s' "$in" | sed -n 's/.*"current_dir"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
[ -n "$dir" ] || dir="$(printf '%s' "$in" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
[ -n "$dir" ] || dir="${CLAUDE_PROJECT_DIR:-$PWD}"

cur="$dir/.ai_context/tasks/CURRENT"
[ -f "$cur" ] || exit 0
slug="$(tr -d '[:space:]' < "$cur")"
plan="$dir/.ai_context/tasks/$slug/plan.md"
{ [ -n "$slug" ] && [ -f "$plan" ]; } || exit 0

info="$(awk '
  /^## / { n++; if ($0 ~ /\[in_progress\]/) { cur = n; line = $0 } }
  END {
    if (!n) exit
    sub(/^## /, "", line)
    sub(/[[:space:]]*\[in_progress\].*/, "", line)
    gsub(/`|\t/, "", line)
    printf "%d\t%d\t%s", cur, n, line
  }
' "$plan")"
[ -n "$info" ] || exit 0
cur="${info%%	*}"; rest="${info#*	}"; n="${rest%%	*}"; line="${rest#*	}"
if [ "${cur:-0}" = 0 ]; then
  printf '%s · no milestone armed' "$slug"
  exit 0
fi
[ "${#line}" -gt 48 ] && line="${line:0:47}…"
printf '%s ▶ %s/%s · %s' "$slug" "$cur" "$n" "$line"
