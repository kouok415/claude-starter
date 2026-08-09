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

in="$(cat 2>/dev/null || true)"
dir="$(printf '%s' "$in" | sed -n 's/.*"current_dir"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
[ -n "$dir" ] || dir="$(printf '%s' "$in" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
[ -n "$dir" ] || dir="${CLAUDE_PROJECT_DIR:-$PWD}"

cur="$dir/.ai_context/tasks/CURRENT"
[ -f "$cur" ] || exit 0
slug="$(tr -d '[:space:]' < "$cur")"
plan="$dir/.ai_context/tasks/$slug/plan.md"
{ [ -n "$slug" ] && [ -f "$plan" ]; } || exit 0

awk -v slug="$slug" '
  /^## / { n++; if ($0 ~ /\[in_progress\]/) { cur = n; line = $0 } }
  END {
    if (!n) exit
    if (!cur) { printf "%s · no milestone armed", slug; exit }
    sub(/^## /, "", line)
    sub(/[[:space:]]*\[in_progress\].*/, "", line)
    gsub(/`/, "", line)
    if (length(line) > 48) line = substr(line, 1, 47) "…"
    printf "%s ▶ %d/%d · %s", slug, cur, n, line
  }
' "$plan"
