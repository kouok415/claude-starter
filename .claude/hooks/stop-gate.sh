#!/usr/bin/env bash
#
# Stop hook — the milestone gate. Mechanizes "Verify before claiming done"
# for long-horizon tasks driven by /task.
#
# When a task is active (.ai_context/tasks/CURRENT names a slug) and its
# plan.md has a milestone marked [in_progress], this hook runs that
# milestone's `- verify:` command when Claude tries to end the turn. On
# failure it exits 2 with the output on stderr, which Claude Code feeds
# back to Claude — a turn cannot end while the gate is red.
#
# No active task, no [in_progress] milestone, or no verify line => no-op,
# so ordinary sessions never notice this hook exists.
#
# Loop protection: when a previous Stop was already blocked by this hook,
# Claude Code sets "stop_hook_active": true in the hook input; that stop is
# allowed through rather than blocking forever.

set -uo pipefail

ROOT="${CLAUDE_PROJECT_DIR:-.}"
TASKS="$ROOT/.ai_context/tasks"

payload="$(cat 2>/dev/null || true)"
if printf '%s' "$payload" | grep -q '"stop_hook_active"[[:space:]]*:[[:space:]]*true'; then
  exit 0
fi

[ -f "$TASKS/CURRENT" ] || exit 0
slug="$(tr -d '[:space:]' < "$TASKS/CURRENT")"
[ -n "$slug" ] || exit 0
plan="$TASKS/$slug/plan.md"
[ -f "$plan" ] || exit 0

# Extract the `- verify:` command of the first [in_progress] milestone.
# plan.md format (kept in sync with .claude/skills/task/SKILL.md):
#   ## M3: <title> [in_progress]
#   - verify: `<command>`
cmd="$(awk '
  /^## / { inprog = ($0 ~ /\[in_progress\]/); next }
  inprog && /^- verify:/ {
    sub(/^- verify:[[:space:]]*/, "")
    gsub(/^`|`$/, "")
    print
    exit
  }
' "$plan")"
[ -n "$cmd" ] || exit 0

# Bound the verify run so a hung command cannot wedge the session
# (the hook-level timeout in settings.json is 600s; stay under it).
run_verify() {
  cd "$ROOT" || return 1
  if command -v timeout >/dev/null 2>&1; then
    timeout 540 bash -c "$cmd"
  else
    bash -c "$cmd"
  fi
}

if out="$(run_verify 2>&1)"; then
  exit 0
fi

{
  printf 'GATE FAILED — the [in_progress] milestone did not pass verify; this turn cannot end.\n'
  printf '$ %s\n' "$cmd"
  printf '%s\n' "$out" | tail -n 50
  printf 'Fix and re-verify, or record the failure in lessons.md and escalate per the /task ladder.\n'
} >&2
exit 2
