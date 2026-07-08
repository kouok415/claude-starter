#!/usr/bin/env bash
#
# Stop hook — two gates that make "done" claims mechanical.
#
# Gate 1 (setup, once per session): a newborn project — CLAUDE.md still
# carrying template placeholders — blocks the first turn-end and instructs
# the /setup protocol. A session_id marker bounds this to ONE block per
# session; it re-arms next session and falls silent forever once the
# placeholders are gone.
#
# Gate 2 (milestone verify, every stop while a /task is active): runs the
# [in_progress] milestone's `- verify:` command; on failure exits 2 with the
# output on stderr so the turn cannot end red. Every run is appended to the
# task's gatelog so scoreboards read a file, not model memory.
#
# Loop protection: when a previous Stop was already blocked by this hook,
# Claude Code sets "stop_hook_active": true — that stop is allowed through.

set -uo pipefail

ROOT="${CLAUDE_PROJECT_DIR:-.}"
TASKS="$ROOT/.ai_context/tasks"

payload="$(cat 2>/dev/null || true)"
if printf '%s' "$payload" | grep -q '"stop_hook_active"[[:space:]]*:[[:space:]]*true'; then
  exit 0
fi

# --- Gate 1: first-session setup -------------------------------------------
if [ -f "$ROOT/CLAUDE.md" ] && \
   grep -qE '<e\.g\.,|<command>|Replace before first commit' "$ROOT/CLAUDE.md"; then
  sid="$(printf '%s' "$payload" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  marker="${TMPDIR:-/tmp}/claude-setup-nudge-${sid:-nosession}"
  if [ ! -f "$marker" ]; then
    : > "$marker" 2>/dev/null || true
    {
      printf 'SETUP GATE — this project has not been set up: CLAUDE.md still contains template placeholders.\n'
      printf 'Run the /setup protocol now: interview the human if intent is unclear, scaffold if needed,\n'
      printf 'draft CLAUDE.md (Stack/Commands/Verify/DoD) plus README/state.md, and ask the human to\n'
      printf 'review the diff. If the human explicitly declined setup this session, say so and finish.\n'
    } >&2
    exit 2
  fi
fi

# --- Gate 2: milestone verify -----------------------------------------------
[ -f "$TASKS/CURRENT" ] || exit 0
slug="$(tr -d '[:space:]' < "$TASKS/CURRENT")"
[ -n "$slug" ] || exit 0
plan="$TASKS/$slug/plan.md"
[ -f "$plan" ] || exit 0

# Exactly one [in_progress] milestone is the contract — corrupted statuses
# would poison the compaction anchor, so block until fixed. Anchor to
# heading lines: plan.md's format comment also contains the literal string
# "[in_progress]" and must not be counted.
n_inprog="$(grep -c '^## .*\[in_progress\]' "$plan" || true)"
if [ "${n_inprog:-0}" -gt 1 ]; then
  printf 'GATE FAILED — %s milestones are marked [in_progress] in plan.md; exactly one is allowed. Fix the statuses, then finish.\n' "$n_inprog" >&2
  exit 2
fi

# Extract the `- verify:` command of the [in_progress] milestone.
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

ms="$(grep -m1 '^## .*\[in_progress\]' "$plan" | sed -n 's/^## \([^:]*\):.*/\1/p')"
gatelog="$TASKS/$slug/gatelog"

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
  printf '%s\t%s\tPASS\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "${ms:-?}" >> "$gatelog" 2>/dev/null || true
  exit 0
fi

printf '%s\t%s\tFAIL\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "${ms:-?}" >> "$gatelog" 2>/dev/null || true
{
  printf 'GATE FAILED — the [in_progress] milestone did not pass verify; this turn cannot end.\n'
  printf '$ %s\n' "$cmd"
  printf '%s\n' "$out" | tail -n 50
  printf 'Fix and re-verify, or record the failure in lessons.md and escalate per the /task ladder.\n'
} >&2
exit 2
