#!/usr/bin/env bash
#
# SessionStart hook — mechanizes the .ai_context reading protocol.
#
# stdout from a SessionStart hook is added to Claude's context, so this
# injects INDEX.md + state.md on startup, resume, /clear, AND after
# compaction — the protocol survives context loss without relying on
# model discipline.
#
# Also emits freshness (S3) and size (S7) warnings so stale memory is
# flagged instead of silently trusted.

set -uo pipefail

ROOT="${CLAUDE_PROJECT_DIR:-.}"
CTX="$ROOT/.ai_context"

# --- Newborn project? Instruct the first-session /setup protocol.
#     Deliberately BEFORE the .ai_context early-exit: the Stop hook's setup
#     gate doesn't require .ai_context either, and the two layers of one
#     mechanism must share a trigger domain.
if [ -f "$ROOT/CLAUDE.md" ] && \
   grep -qE '<e\.g\.,|<command>|Replace before first commit' "$ROOT/CLAUDE.md"; then
  printf 'SETUP REQUIRED: this project has not been set up (CLAUDE.md is still a template). In your FIRST reply, run the /setup protocol — interview, scaffold, draft CLAUDE.md/README/state.md for human review — before or alongside the current request. The Stop gate blocks the first turn-end until the draft lands.\n'
fi

[ -d "$CTX" ] || exit 0

emit_file() {
  [ -f "$1" ] || return 0
  printf '=== %s ===\n' "${1#"$ROOT"/}"
  cat "$1"
  printf '\n'
}

emit_file "$CTX/INDEX.md"
emit_file "$CTX/state.md"

# --- Active long-horizon task (/task harness): inject its plan + lessons so
#     re-anchoring after /clear or compaction lands on the latest milestone
#     checkpoint, not on a start-of-session snapshot.
if [ -f "$CTX/tasks/CURRENT" ]; then
  slug="$(tr -d '[:space:]' < "$CTX/tasks/CURRENT")"
  if [ -n "$slug" ] && [ -d "$CTX/tasks/$slug" ]; then
    emit_file "$CTX/tasks/$slug/plan.md"
    emit_file "$CTX/tasks/$slug/lessons.md"
  fi
fi

if [ -f "$CTX/state.md" ]; then
  # --- Freshness (S3): warn when "Last updated" is old ---
  lu="$(grep -m1 -Eo '[0-9]{4}-[0-9]{2}-[0-9]{2}' "$CTX/state.md" || true)"
  if [ -n "$lu" ]; then
    lu_epoch="$(date -d "$lu" +%s 2>/dev/null || date -j -f '%Y-%m-%d' "$lu" +%s 2>/dev/null || echo '')"
    if [ -n "$lu_epoch" ]; then
      age_days=$(( ( $(date +%s) - lu_epoch ) / 86400 ))
      if [ "$age_days" -gt 14 ]; then
        printf 'WARNING: state.md last updated %s (%s days ago) — treat its claims as possibly stale; refresh it (run /wrap) before relying on it.\n' "$lu" "$age_days"
      fi
    fi
  else
    printf 'WARNING: state.md has no "Last updated: YYYY-MM-DD" date — add one (S3).\n'
  fi

  # --- Size (S7): 5 KB cap ---
  size="$(wc -c < "$CTX/state.md" | tr -d ' ')"
  if [ "$size" -gt 5120 ]; then
    printf 'WARNING: state.md is %s bytes (cap 5120, S7) — archive resolved sections to journal/ and trim.\n' "$size"
  fi

  # --- Unwrapped session? Commits newer than state.md's Last updated ---
  if [ -n "$lu" ] && [ -d "$ROOT/.git" ]; then
    last_commit="$(git -C "$ROOT" log -1 --format=%cs 2>/dev/null || true)"
    if [ -n "$last_commit" ] && [[ "$last_commit" > "$lu" ]]; then
      printf 'WARNING: latest commit (%s) is newer than state.md (%s) — the previous session may have ended without /wrap. Reconcile from git log/diff, then refresh state.md.\n' "$last_commit" "$lu"
    fi
  fi
fi

exit 0
