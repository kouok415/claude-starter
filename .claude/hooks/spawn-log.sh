#!/usr/bin/env bash
#
# SubagentStart hook — append-only spawn evidence for the /task harness.
#
# argv[1] is the agent class as routed by the settings.json matchers
# ("executor" | "other"); the matcher does ALL the filtering, so this script
# reads NOTHING from the hook payload — immune to payload schema drift.
#
# One TSV row per spawn into the active task's spawnlog:
#   <timestamp>\t<in_progress milestone or - >\t<class>
#
# Why it exists (2026-07-22 v_trader incident): plan.md said [in_progress]
# but no executor was ever spawned — the two states are indistinguishable
# after a compaction unless spawning leaves a trace. The stop-gate uses this
# file to tell "never started" from "tried and failed" when a verify is red.
#
# Capability handshake: on M/L tasks the intake always spawns scout/planner
# agents BEFORE any milestone arms, so a spawnlog with ANY row proves the
# SubagentStart event fires in this environment. The gate only makes
# no-spawn claims when the file is non-empty — on Claude Code versions
# without SubagentStart, the file stays absent and the gate stays silent.
#
# No active task => no-op: agents spawned outside /task leave no rows.

set -uo pipefail

ROOT="${CLAUDE_PROJECT_DIR:-.}"
TASKS="$ROOT/.ai_context/tasks"
kind="${1:-other}"

cat > /dev/null 2>&1 || true   # drain stdin; payload deliberately unused

[ -f "$TASKS/CURRENT" ] || exit 0
slug="$(tr -d '[:space:]' < "$TASKS/CURRENT")"
[ -n "$slug" ] && [ -d "$TASKS/$slug" ] || exit 0

ms='-'
plan="$TASKS/$slug/plan.md"
if [ -f "$plan" ]; then
  m="$(grep -m1 '^## .*\[in_progress\]' "$plan" | sed -n 's/^## \([^:]*\):.*/\1/p')"
  [ -n "$m" ] && ms="$m"
fi

printf '%s\t%s\t%s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$ms" "$kind" \
  >> "$TASKS/$slug/spawnlog" 2>/dev/null || true
exit 0
