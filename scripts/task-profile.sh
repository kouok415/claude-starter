#!/usr/bin/env bash
# task-profile.sh — apply or inspect the /task model profile.
#
# Models live ONLY in .claude/agents/*.md frontmatter (ADR: the harness
# never picks models). This script is the user-directed pen that writes
# those pins deterministically; /task intake calls `apply` with the
# user's --profile choice. Profiles:
#   mixed-judge  judgment agents (scout, planner, plan-critic, reframer,
#                final-verifier) -> fable; executor + verifier -> opus
#   mixed        executor -> opus, everything else inherit (run the
#                session on a fable-class model)
#   inherit      all agents -> inherit (factory state, byte-identical)
# `apply` with no argument: an active task's plan.md header wins (resume
# keeps its recorded profile); otherwise inherit.
set -euo pipefail
cd "$(dirname "$0")/.."
AGENTS=".claude/agents"
JUDGE="scout planner plan-critic reframer final-verifier"
EXEC="executor verifier"

pin() { # <agent> <model>
  local f="$AGENTS/$1.md"
  [ -f "$f" ] || { echo "task-profile: missing $f" >&2; return 1; }
  sed -i "s/^model: .*/model: $2/" "$f"
}

apply_profile() {
  local a
  case "$1" in
    mixed-judge)
      for a in $JUDGE; do pin "$a" fable; done
      for a in $EXEC;  do pin "$a" opus;  done ;;
    mixed)
      for a in $JUDGE $EXEC; do pin "$a" inherit; done
      pin executor opus ;;
    inherit|opus-tier|fable-tier)
      for a in $JUDGE $EXEC; do pin "$a" inherit; done ;;
    *) echo "task-profile: unknown profile '$1'" >&2; exit 2 ;;
  esac
  echo "task-profile: applied $1"
}

active_profile() { # profile recorded by the active task's plan.md, if any
  local slug plan
  [ -f .ai_context/tasks/CURRENT ] || return 1
  slug="$(cat .ai_context/tasks/CURRENT)"
  plan=".ai_context/tasks/$slug/plan.md"
  [ -f "$plan" ] || return 1
  sed -n 's/^<!-- profile: \([a-z-]*\).*/\1/p' "$plan" | head -1
}

warn_env() {
  if [ -n "${CLAUDE_CODE_SUBAGENT_MODEL:-}" ]; then
    echo "task-profile: WARNING: CLAUDE_CODE_SUBAGENT_MODEL=${CLAUDE_CODE_SUBAGENT_MODEL} overrides every frontmatter pin" >&2
  fi
}

cmd="${1:-status}"
case "$cmd" in
  status)
    warn_env
    grep -H '^model:' "$AGENTS"/*.md ;;
  apply)
    warn_env
    want="${2:-}"
    act="$(active_profile || true)"
    if [ -n "$act" ] && [ -n "$want" ] && [ "$want" != "$act" ]; then
      echo "task-profile: PROFILE SWITCH mid-task ($act -> $want): plan.md was cut for $act — follow reference.md §Profiles (re-cut remaining milestones, update the header, note it in lessons.md)" >&2
    fi
    [ -n "$want" ] || want="${act:-inherit}"
    apply_profile "$want" ;;
  mixed-judge|mixed|inherit)
    warn_env
    apply_profile "$cmd" ;;
  *)
    echo "Usage: task-profile.sh <mixed-judge|mixed|inherit|status|apply [profile]>" >&2
    exit 2 ;;
esac
