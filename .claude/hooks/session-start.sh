#!/usr/bin/env bash
#
# SessionStart hook — mechanizes the .ai_context reading protocol.
#
# stdout from a SessionStart hook is added to Claude's context, so this
# injects INDEX.md + state.md + the active task card (≤4096 B) and one
# evidence-status line on startup, resume, /clear, AND after compaction —
# the protocol survives context loss without relying on model discipline.
# A task's notes.md is never injected (nor a v3 brief, lessons or spec):
# the executor and the checker read the § the card points at.
#
# Also emits freshness (S3) and size (S7) warnings so stale memory is
# flagged instead of silently trusted.

set -uo pipefail

ROOT="${CLAUDE_PROJECT_DIR:-.}"
CTX="$ROOT/.ai_context"

# Setup-sentinel pattern shared with stop-gate.sh (two layers of one
# mechanism); helper absent (partial sync) = the same literal inline.
# The same file provides the task helpers (task_slug, task_idle).
_GP="$(dirname "${BASH_SOURCE[0]}")/guard-patterns.sh"
# shellcheck source=guard-patterns.sh
[ -f "$_GP" ] && . "$_GP"
[ -n "${GUARD_SETUP_SENTINEL:-}" ] || GUARD_SETUP_SENTINEL='claude-starter: UNCONFIGURED|<e\.g\.,|<command>|Replace before first commit'

# --- Newborn project? Instruct the first-session /setup protocol.
#     Deliberately BEFORE the .ai_context early-exit: the Stop hook's setup
#     gate doesn't require .ai_context either, and the two layers of one
#     mechanism must share a trigger domain — hence the shared constant.
if [ -f "$ROOT/CLAUDE.md" ] && \
   grep -qE "$GUARD_SETUP_SENTINEL" "$ROOT/CLAUDE.md"; then
  printf 'SETUP REQUIRED: this project has not been set up (CLAUDE.md is still a template). In your FIRST reply, run the /setup protocol — interview, scaffold, draft CLAUDE.md/README/state.md for human review — before or alongside the current request. The Stop gate blocks the first turn-end until the draft lands.\n'
fi

# --- Size (CLAUDE.md): Claude Code loads it into every session and subagent.
#     Before the .ai_context early-exit: it applies to any project.
if [ -f "$ROOT/CLAUDE.md" ]; then
  csize="$(wc -c < "$ROOT/CLAUDE.md" | tr -d ' ')"
  if [ "$csize" -gt 20480 ]; then
    printf 'WARNING: CLAUDE.md is %s bytes (cap 20480) — Claude Code loads it into every session and subagent; move detail into skills, .ai_context/knowledge/ or docs/ and keep commands, rules and the Definition of done.\n' "$csize"
  fi
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

# --- Size (INDEX): injected every session, same 4 KB bar as the task files.
#     (The template CI guards the seed; this guards the copy that actually
#     lives — and grows — inside each project.)
if [ -f "$CTX/INDEX.md" ]; then
  isize="$(wc -c < "$CTX/INDEX.md" | tr -d ' ')"
  if [ "$isize" -gt 4096 ]; then
    printf 'WARNING: INDEX.md is %s bytes (cap 4096) — it is injected into every session; keep it meta-only and move content into the files it points at.\n' "$isize"
  fi
fi

# --- Active /task: inject its card — goal, done-when, decisions, slice lines
#     with their evidence ids — so re-anchoring after /clear or compaction
#     lands on the current slice. ≤4096 B by design: past the cap only the
#     first 4096 bytes (whole lines) are injected and evidence.sh lint
#     refuses the card. One evidence-status line rides along; an idle card
#     (D6) is not injected and the Stop gate does not check it.
if [ -f "$CTX/tasks/CURRENT" ]; then
  if [ "${GUARD_PATTERNS_V4:-}" != 1 ]; then
    printf 'WARNING: .claude/hooks/guard-patterns.sh is missing or predates v4 — the task card is not injected; re-sync the template.\n'
  elif ! slug="$(task_slug "$ROOT")"; then
    printf 'WARNING: .ai_context/tasks/CURRENT exists but is empty/corrupt — no task card is injected; restore the slug or delete the file.\n'
  elif [ ! -f "$CTX/tasks/$slug/card.md" ]; then
    if [ -f "$CTX/tasks/$slug/plan.md" ]; then
      printf 'WARNING: tasks/CURRENT names "%s", a v3 plan.md task without card.md — v4 hooks do not drive it and its plan/spec/brief/lessons are no longer injected. Finish it on the v3-final template or rewrite it as a card (/task).\n' "$slug"
    else
      printf 'WARNING: tasks/CURRENT names "%s" but its card.md is missing (mid-intake, renamed dir, or stale CURRENT) — nothing is injected; write the card or delete CURRENT.\n' "$slug"
    fi
  elif task_idle "$ROOT" "$slug"; then
    printf 'NOTE: task "%s" has been idle %s days (no card, donelog or task/%s commit activity) — its card is not injected and the Stop gate does not check it. Resume it with /task (any card edit or evidence run re-activates it), or /wrap it and delete tasks/CURRENT.\n' \
      "$slug" "$(task_idle_days "$ROOT" "$slug")" "$slug"
  else
    card="$CTX/tasks/$slug/card.md"
    csz="$(wc -c < "$card" | tr -d ' ')"
    if [ "$csz" -le 4096 ]; then
      emit_file "$card"
    else
      printf '=== %s (TRUNCATED: first 4096 of %s bytes, cut at the last full line) ===\n' "${card#"$ROOT"/}" "$csz"
      chunk="$(head -c 4096 "$card"; printf x)"
      chunk="${chunk%x}"
      case "$chunk" in
        *$'\n') printf '%s' "$chunk" ;;
        *) printf '%s\n' "$chunk" | sed '$d' ;;
      esac
      printf 'WARNING: card.md is %s bytes (cap 4096) — only the first 4096 bytes were injected; move detail into notes.md (never injected) and keep the card to goal, done-when, decisions and slice lines. evidence.sh lint refuses an oversized card.\n' "$csz"
    fi

    # notes.md is never injected, but every executor and checker pays for it.
    if [ -f "$CTX/tasks/$slug/notes.md" ]; then
      nsz="$(wc -c < "$CTX/tasks/$slug/notes.md" | tr -d ' ')"
      if [ "$nsz" -gt 16384 ]; then
        printf 'WARNING: tasks/%s/notes.md is %s bytes (cap 16384) — it is never injected, but every executor and checker that reads a § pays for it; keep only constraints, interfaces, edge cases, rulings verbatim and measured facts.\n' "$slug" "$nsz"
      fi
    fi

    if [ ! -f "$ROOT/scripts/evidence.sh" ]; then
      printf 'WARNING: scripts/evidence.sh is missing — no slice can be marked done; re-sync the template (sync-project.sh --update-stock).\n'
    else
      tmo=()
      command -v timeout >/dev/null 2>&1 && tmo=(timeout 10)
      line="$(${tmo[@]+"${tmo[@]}"} bash "$ROOT/scripts/evidence.sh" status --line </dev/null 2>/dev/null)"
      rc=$?
      if [ "$rc" != 0 ]; then
        printf 'WARNING: evidence.sh status --line failed (rc %s) — run bash scripts/evidence.sh status to see why.\n' "$rc"
      elif [ -n "$line" ]; then
        printf '=== evidence (scripts/evidence.sh status --line) ===\n%s\n\n' "$line"
      fi
    fi

    # Closed but not wrapped: the window between `evidence.sh close` and
    # /wrap — and the lasting state when wrap is skipped.
    if grep -q '^Closed:[[:space:]]' "$card"; then
      printf 'NOTE: task "%s" is Closed but tasks/CURRENT still points at it — run /wrap to write the scoreboard row and clear CURRENT; until then every session pays this card.\n' "$slug"
    fi
  fi
fi

if [ -f "$CTX/state.md" ]; then
  # --- Freshness (S3): warn when "Last updated" is old ---
  # Anchored to the labeled line: S3 requires the label, and a body date
  # ("ship by 2026-08-01") must not shadow the actual freshness claim.
  lu="$(sed -n 's/.*[Ll]ast updated:*[^0-9]*\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\).*/\1/p' "$CTX/state.md" | head -n1)"
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
