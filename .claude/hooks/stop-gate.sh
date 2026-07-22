#!/usr/bin/env bash
#
# Stop hook — gates that make "done" claims mechanical.
#
# Gate 1 (setup, once per session): a newborn project — CLAUDE.md still
# carrying the UNCONFIGURED sentinel (or legacy template placeholders) —
# blocks the first turn-end and instructs the /setup protocol. A session_id
# marker bounds this to ONE block per session; it re-arms next session and
# falls silent forever once the sentinel is gone.
#
# Gate 2 (milestone verify, every stop while a /task is active): runs the
# [in_progress] milestone's `- verify:` command; on failure exits 2 with the
# output on stderr so the turn cannot end red (first two attempts — see
# Counted yields below). Every real run is appended to the task's gatelog so
# scoreboards read a file, not model memory.
#
# Gate-2 integrity (v3.4): any state in which the milestone gate would
# otherwise be silently OFF — empty/corrupt CURRENT, missing or heading-less
# plan.md, work mid-flight ([done]+[pending]) with no [in_progress], an
# [in_progress] milestone with no verify command, task work sitting on
# main/master — blocks once per session (shared marker) and appends an
# INTEGRITY row to the gatelog. A quiet gatelog therefore provably means
# "clean run", never "the gate was dark". All-[pending] (intake pause) and
# all-[done] (completion wrap-up) stay legitimate no-ops.
#
# Forbidden verify ops: verify commands execute unattended at every turn
# end, so catastrophic operations (sudo, git push, rm -rf on an absolute
# path) are never run — always blocked, always logged, no once-per-session
# yield.
#
# PASS-cache: an expensive verify is NOT re-run when the tree provably has
# not changed since its last PASS (fingerprint = HEAD + tracked diff +
# untracked file CONTENT hashes; untracked files over 1 MB fall back to
# size+mtime so bulk data stays cheap). Any change invalidates the cache,
# so the gate never gets weaker — only cheaper. Non-git trees never cache.
# Skips are silent (no gatelog row) so scoreboard counts stay meaningful.
#
# Zero-stop sweep (v3.6): a task completed inside ONE turn never arms the
# gate — the Stop hook first fires when plan.md is already all-[done], a
# legitimate no-op, so the gatelog stays empty and "0 gate failures" is
# vacuous. At the all-[done] state (and via an explicit `--sweep` call from
# /wrap before CURRENT is deleted) every [done] milestone lacking a PASS row
# is accounted for: the LAST one — whose point-in-time is exactly now — has
# its verify RUN (PASS/FAIL rows, red blocks every time); earlier ones get
# an UNARMED row (their verifies are point-in-time gates, not permanent
# invariants — later milestones may legitimately supersede them, so honest
# vacuity is recorded instead of fake evidence). A quiet gatelog again
# means "clean run": no FAIL, no INTEGRITY, and no unrecorded dark gates.
#
# Counted yields (v3.9): a red verify blocks at most TWICE per milestone per
# session; the third consecutive red stop YIELDS — exit 0 with a STUCK gatelog
# row and a {"systemMessage"} to the human. Rationale: the 2026-07-22 v_trader
# incident — the gate caught a skipped-executor milestone, blocked once, then
# the old unconditional stop_hook_active pass-through let the red turn end
# silently; the human found it by hand half a day later. Three failed attempts
# = the three-strikes rule: stop resampling, hand off. Model-fixable block
# states (status corruption, forbidden verify) keep blocking every attempt —
# the platform's own consecutive-block cap (default 8) is the backstop.
# stop_hook_active is honored only by Gate 1 (setup nudge); the milestone
# gate does its own counting instead.

set -uo pipefail

ROOT="${CLAUDE_PROJECT_DIR:-.}"
TASKS="$ROOT/.ai_context/tasks"

MODE=stop
[ "${1:-}" = "--sweep" ] && MODE=sweep

if [ "$MODE" = stop ]; then
  payload="$(cat 2>/dev/null || true)"
  stop_active=0
  if printf '%s' "$payload" | grep -q '"stop_hook_active"[[:space:]]*:[[:space:]]*true'; then
    stop_active=1
  fi
  sid="$(printf '%s' "$payload" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
else
  sid=""
  stop_active=0
fi
# Filename-safe session id for this hook's own marker/counter files.
sid_s="$(printf '%s' "${sid:-nosession}" | tr -cd 'A-Za-z0-9._-')"
[ -n "$sid_s" ] || sid_s=nosession

# --- Gate 1: first-session setup -------------------------------------------
# Sentinel first (v3.3 templates); legacy placeholder patterns kept for
# projects spawned before the sentinel existed. Keep this pattern in sync
# with session-start.sh — the two layers of one mechanism must agree.
if [ "$MODE" = stop ] && [ "$stop_active" = 0 ] && [ -f "$ROOT/CLAUDE.md" ] && \
   grep -qE 'claude-starter: UNCONFIGURED|<e\.g\.,|<command>|Replace before first commit' "$ROOT/CLAUDE.md"; then
  marker="${TMPDIR:-/tmp}/claude-setup-nudge-${sid_s}"
  if [ ! -f "$marker" ]; then
    : > "$marker" 2>/dev/null || true
    {
      printf 'SETUP GATE — this project has not been set up: CLAUDE.md still carries the UNCONFIGURED sentinel / template placeholders.\n'
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

# --- Gate-2 integrity: no silent disarm --------------------------------------
# One integrity interruption per session (shared marker); every detection
# leaves an INTEGRITY gatelog row, so dark-gate states are always on record.
imarker="${TMPDIR:-/tmp}/claude-gate-integrity-${sid_s}"

integrity_stop() { # $1 = milestone id or '?', $2 = reason
  if [ ! -f "$imarker" ] && [ -n "$slug" ] && [ -d "$TASKS/$slug" ]; then
    printf '%s\t%s\tINTEGRITY\t%s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$1" "$2" \
      >> "$TASKS/$slug/gatelog" 2>/dev/null || true
  fi
  [ -f "$imarker" ] && exit 0
  : > "$imarker" 2>/dev/null || true
  {
    printf 'GATE INTEGRITY — the milestone gate cannot arm: %s\n' "$2"
    printf 'Fix the task state before finishing. If this is a legitimate mid-intake pause\n'
    printf 'awaiting the human, say so and finish — this interrupts once per session.\n'
  } >&2
  exit 2
}

[ -n "$slug" ] || integrity_stop '?' 'tasks/CURRENT exists but is empty/corrupt — restore the slug or delete the file'

# Task work sits on a task/* branch, never the default one (non-git /
# detached HEAD: skip). Any other branch is also a dark state: the gate
# would run the milestone verify against the wrong tree, logging junk FAIL
# rows — block with a clear reason instead.
branch="$(git -C "$ROOT" branch --show-current 2>/dev/null || true)"
case "$branch" in
  main|master)
    integrity_stop '?' "active task '$slug' but the session is on '$branch' — task work belongs on a task/ branch"
    ;;
  ''|task/*) ;;
  *)
    integrity_stop '?' "active task '$slug' but the session is on branch '$branch' — task work belongs on task/<slug>; a verify here would run against the wrong tree"
    ;;
esac

plan="$TASKS/$slug/plan.md"
gatelog="$TASKS/$slug/gatelog"
[ -f "$plan" ] || integrity_stop '?' "tasks/CURRENT names '$slug' but its plan.md is missing — mid-intake pause, renamed dir, or stale CURRENT"
grep -q '^## ' "$plan" || integrity_stop '?' 'plan.md has no milestone headings — malformed plan, the gate has nothing to check'

# --- Counted red blocks ------------------------------------------------------
# Consecutive red *blocks* per (session, milestone), kept in a tmp counter.
# Session-scoped on purpose: gatelog FAIL rows survive across sessions, so
# counting those would carry yesterday's blocks into today's first attempt.
red_file() { # $1 = key -> prints the counter path
  printf '%s/claude-gate-red-%s-%s' "${TMPDIR:-/tmp}" "$sid_s" \
    "$(printf '%s' "$1" | tr -cs 'A-Za-z0-9._-' '_')"
}

red_count() { # $1 = key -> increments and prints the new count
  rcf="$(red_file "$1")"
  n="$(cat "$rcf" 2>/dev/null || true)"
  case "$n" in (''|*[!0-9]*) n=0 ;; esac
  n=$((n + 1))
  printf '%s' "$n" > "$rcf" 2>/dev/null || true
  printf '%s' "$n"
}

red_reset() { # $1 = key
  rm -f "$(red_file "$1")" 2>/dev/null || true
}

# NOTE: $3 lands inside a JSON string — pass fixed ASCII without quotes only.
yield_stuck() { # $1 = milestone id, $2 = consecutive count, $3 = extra note ('' ok)
  printf '%s\t%s\tSTUCK\tyielded to the human after %s consecutive red blocks%s\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S')" "$1" "$2" "${3:+ — $3}" \
    >> "$gatelog" 2>/dev/null || true
  slug_j="$(printf '%s' "$slug" | tr -cd 'A-Za-z0-9._-')"
  ms_j="$(printf '%s' "$1" | tr -cd 'A-Za-z0-9._-')"
  printf '{"systemMessage":"claude-starter gate: task %s / %s is RED — blocked %s stops in a row without a green verify, yielding now.%s A human needs to look: .ai_context/tasks/%s/gatelog"}\n' \
    "$slug_j" "$ms_j" "$2" "${3:+ (${3})}" "$slug_j"
  exit 0
}

# --- Zero-stop sweep ---------------------------------------------------------
# Shared by the all-[done] Stop state and the explicit --sweep mode (called
# by /wrap before CURRENT is deleted, incl. on abandoned tasks).
TAB="$(printf '\t')"

verify_of() { # $1 = milestone id -> prints its `- verify:` command (may be empty)
  awk -v want="## $1:" '
    index($0, want) == 1 { take = 1; next }
    /^## / { take = 0 }
    take && /^- verify:/ {
      sub(/^- verify:[[:space:]]*/, "")
      gsub(/^`|`$/, "")
      print
      exit
    }
  ' "$plan"
}

run_cmd() { # $1 = command; bounded so a hung verify cannot wedge the session
  cd "$ROOT" || return 1
  if command -v timeout >/dev/null 2>&1; then
    timeout 540 bash -c "$1"
  else
    bash -c "$1"
  fi
}

sweep_done_milestones() { # $1 = 1 when the plan is all-[done] (last verify runs)
  run_last="$1"
  last_id="$(grep '^## .*\[done\]' "$plan" | tail -1 | sed -n 's/^## \([^:]*\):.*/\1/p')"
  grep '^## .*\[done\]' "$plan" | sed -n 's/^## \([^:]*\):.*/\1/p' | while IFS= read -r id; do
    [ -n "$id" ] || continue
    grep -qF "${TAB}${id}${TAB}PASS" "$gatelog" 2>/dev/null && continue
    vcmd="$(verify_of "$id")"
    vlog="$(printf '%s' "$vcmd" | tr '\t' ' ')"
    if [ "$id" = "$last_id" ] && [ "$run_last" = 1 ] && [ -n "$vcmd" ]; then
      case " $vcmd " in
        *' sudo '*|*'git push'*|*'rm -rf /'*)
          printf '%s\t%s\tINTEGRITY\tforbidden verify, not executed: %s\n' \
            "$(date '+%Y-%m-%dT%H:%M:%S')" "$id" "$vlog" >> "$gatelog" 2>/dev/null || true
          {
            printf 'GATE REFUSED — the verify command contains a forbidden operation and was NOT run:\n'
            printf '$ %s\n' "$vcmd"
            printf 'Rewrite this milestone verify in plan.md, then finish.\n'
          } >&2
          echo BLOCK
          ;;
        *)
          if out="$(run_cmd "$vcmd" 2>&1)"; then
            printf '%s\t%s\tPASS\t%s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$id" "$vlog" >> "$gatelog" 2>/dev/null || true
          else
            printf '%s\t%s\tFAIL\t%s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$id" "$vlog" >> "$gatelog" 2>/dev/null || true
            {
              printf 'GATE SWEEP FAILED — %s is marked [done] but its verify fails NOW (zero-stop run: the gate never saw it pass).\n' "$id"
              printf '$ %s\n' "$vcmd"
              printf '%s\n' "$out" | tail -n 50
              printf 'The task cannot wrap red: fix it, or mark %s back to [in_progress] and re-enter the loop.\n' "$id"
            } >&2
            echo BLOCK
          fi
          ;;
      esac
    else
      # Earlier [done] milestones (or verify-less ones): their point-in-time
      # has passed — record honest vacuity exactly once, never fake evidence.
      grep -qF "${TAB}${id}${TAB}UNARMED" "$gatelog" 2>/dev/null && continue
      printf '%s\t%s\tUNARMED\t%s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$id" \
        "${vlog:-(no verify command)}" >> "$gatelog" 2>/dev/null || true
    fi
  done | grep -q BLOCK && return 1
  return 0
}

if [ "$MODE" = sweep ]; then
  n_done="$(grep -c '^## .*\[done\]' "$plan" || true)"
  [ "${n_done:-0}" -gt 0 ] || exit 0
  all_done=0
  if ! grep -q '^## .*\[in_progress\]' "$plan" && ! grep -q '^## .*\[pending\]' "$plan"; then
    all_done=1
  fi
  # Explicit /wrap sweep: strict, never yields — /wrap must not wrap red.
  sweep_done_milestones "$all_done" || exit 2
  exit 0
fi

# Exactly one [in_progress] milestone is the contract — corrupted statuses
# would poison the compaction anchor, so block until fixed. Anchor to
# heading lines: plan.md's format comment also contains the literal string
# "[in_progress]" and must not be counted.
n_inprog="$(grep -c '^## .*\[in_progress\]' "$plan" || true)"
if [ "${n_inprog:-0}" -gt 1 ]; then
  printf 'GATE FAILED — %s milestones are marked [in_progress] in plan.md; exactly one is allowed. Fix the statuses, then finish.\n' "$n_inprog" >&2
  exit 2
fi
if [ "${n_inprog:-0}" -eq 0 ]; then
  # All-[pending] (intake pause) and all-[done] (completion wrap-up) are
  # legitimate. [done]+[pending] with no [in_progress] is a status typo —
  # exactly the state in which the gate would silently stay OFF.
  if grep -q '^## .*\[done\]' "$plan" && grep -q '^## .*\[pending\]' "$plan"; then
    integrity_stop '?' 'milestones are [done] and [pending] but none [in_progress] — a status typo has the gate OFF; mark the next milestone [in_progress]'
  fi
  # All-[done] wrap-up: account for gates a zero-stop run never armed —
  # verify the final milestone now, record UNARMED for earlier rowless ones.
  # Red sweeps are counted like any red verify: two blocks, third yields.
  if grep -q '^## .*\[done\]' "$plan"; then
    if ! sweep_done_milestones 1; then
      swn="$(red_count "${slug}-sweep")"
      [ "$swn" -ge 3 ] && yield_stuck sweep "$swn" 'final-milestone verify red at wrap-up'
      exit 2
    fi
    red_reset "${slug}-sweep"
  fi
  exit 0
fi

ms="$(grep -m1 '^## .*\[in_progress\]' "$plan" | sed -n 's/^## \([^:]*\):.*/\1/p')"
gatecache="$TASKS/$slug/.gate-cache"

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
[ -n "$cmd" ] || integrity_stop "${ms:-?}" 'the [in_progress] milestone has no `- verify:` command — the gate cannot arm on it'

# Gatelog rows carry the exact command that was enforced (tabs sanitized) —
# a mid-run weakening of the verify is visible in the audit trail.
cmd_log="$(printf '%s' "$cmd" | tr '\t' ' ')"

# Catastrophic operations never run unattended — not even once.
case " $cmd " in
  *' sudo '*|*'git push'*|*'rm -rf /'*)
    printf '%s\t%s\tINTEGRITY\tforbidden verify, not executed: %s\n' \
      "$(date '+%Y-%m-%dT%H:%M:%S')" "${ms:-?}" "$cmd_log" >> "$gatelog" 2>/dev/null || true
    {
      printf 'GATE REFUSED — the verify command contains a forbidden operation and was NOT run:\n'
      printf '$ %s\n' "$cmd"
      printf 'Verify commands execute unattended at every turn end: no sudo, no git push,\n'
      printf 'no rm -rf on absolute paths. Rewrite this milestone verify in plan.md, then finish.\n'
    } >&2
    exit 2
    ;;
esac

# --- PASS-cache -------------------------------------------------------------
# The cache file itself is gitignored (.ai_context/tasks/*/.gate-cache), so
# it never feeds back into its own fingerprint.
hash_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256
  else cksum
  fi
}

fingerprint() {
  git -C "$ROOT" rev-parse HEAD >/dev/null 2>&1 || return 1
  {
    git -C "$ROOT" rev-parse HEAD
    git -C "$ROOT" status --porcelain
    git -C "$ROOT" diff HEAD
    # Untracked files: content hash — a same-size edit must invalidate.
    # Files over 1 MB fall back to size+mtime so bulk data stays cheap.
    git -C "$ROOT" ls-files -o --exclude-standard | while IFS= read -r uf; do
      p="$ROOT/$uf"
      sz="$(wc -c < "$p" 2>/dev/null | tr -d ' ' || true)"
      if [ -n "$sz" ] && [ "$sz" -le 1048576 ]; then
        printf '%s %s\n' "$uf" "$(hash_stdin < "$p" | awk '{print $1}')"
      else
        printf '%s %s %s\n' "$uf" "${sz:-?}" \
          "$(stat -c %Y "$p" 2>/dev/null || stat -f %m "$p" 2>/dev/null || echo '?')"
      fi
    done
  } 2>/dev/null | hash_stdin | awk '{print $1}'
}

fp="$(fingerprint || true)"
if [ -n "$fp" ] && [ -f "$gatecache" ] && \
   [ "$(cat "$gatecache" 2>/dev/null)" = "$ms|$fp" ]; then
  exit 0
fi

if out="$(run_cmd "$cmd" 2>&1)"; then
  printf '%s\t%s\tPASS\t%s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "${ms:-?}" "$cmd_log" >> "$gatelog" 2>/dev/null || true
  red_reset "${slug}-${ms:-?}"
  # Fingerprint AFTER the run: verify itself may write artifacts; caching the
  # post-run state lets the next no-op stop hit the cache.
  fp="$(fingerprint || true)"
  if [ -n "$fp" ]; then
    printf '%s|%s' "$ms" "$fp" > "$gatecache" 2>/dev/null || true
  fi
  exit 0
fi

rm -f "$gatecache" 2>/dev/null || true
printf '%s\t%s\tFAIL\t%s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "${ms:-?}" "$cmd_log" >> "$gatelog" 2>/dev/null || true
rn="$(red_count "${slug}-${ms:-?}")"
[ "$rn" -ge 3 ] && yield_stuck "${ms:-?}" "$rn" ''
{
  printf 'GATE FAILED (red block %s of 2 — one more red stop hands off to the human) — the [in_progress] milestone did not pass verify; this turn cannot end.\n' "$rn"
  printf '$ %s\n' "$cmd"
  printf '%s\n' "$out" | tail -n 50
  printf 'Fix and re-verify, or record the failure in lessons.md and escalate per the /task ladder.\n'
} >&2
exit 2
