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
# output on stderr so the turn cannot end red. Every real run is appended to
# the task's gatelog so scoreboards read a file, not model memory.
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
# Loop protection: when a previous Stop was already blocked by this hook,
# Claude Code sets "stop_hook_active": true — that stop is allowed through.

set -uo pipefail

ROOT="${CLAUDE_PROJECT_DIR:-.}"
TASKS="$ROOT/.ai_context/tasks"

payload="$(cat 2>/dev/null || true)"
if printf '%s' "$payload" | grep -q '"stop_hook_active"[[:space:]]*:[[:space:]]*true'; then
  exit 0
fi
sid="$(printf '%s' "$payload" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"

# --- Gate 1: first-session setup -------------------------------------------
# Sentinel first (v3.3 templates); legacy placeholder patterns kept for
# projects spawned before the sentinel existed. Keep this pattern in sync
# with session-start.sh — the two layers of one mechanism must agree.
if [ -f "$ROOT/CLAUDE.md" ] && \
   grep -qE 'claude-starter: UNCONFIGURED|<e\.g\.,|<command>|Replace before first commit' "$ROOT/CLAUDE.md"; then
  marker="${TMPDIR:-/tmp}/claude-setup-nudge-${sid:-nosession}"
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
imarker="${TMPDIR:-/tmp}/claude-gate-integrity-${sid:-nosession}"

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

# Task work never sits on the default branch (non-git / detached HEAD: skip).
branch="$(git -C "$ROOT" branch --show-current 2>/dev/null || true)"
case "$branch" in
  main|master)
    integrity_stop '?' "active task '$slug' but the session is on '$branch' — task work belongs on a task/ branch"
    ;;
esac

plan="$TASKS/$slug/plan.md"
[ -f "$plan" ] || integrity_stop '?' "tasks/CURRENT names '$slug' but its plan.md is missing — mid-intake pause, renamed dir, or stale CURRENT"
grep -q '^## ' "$plan" || integrity_stop '?' 'plan.md has no milestone headings — malformed plan, the gate has nothing to check'

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
  exit 0
fi

ms="$(grep -m1 '^## .*\[in_progress\]' "$plan" | sed -n 's/^## \([^:]*\):.*/\1/p')"
gatelog="$TASKS/$slug/gatelog"
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
  printf '%s\t%s\tPASS\t%s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "${ms:-?}" "$cmd_log" >> "$gatelog" 2>/dev/null || true
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
{
  printf 'GATE FAILED — the [in_progress] milestone did not pass verify; this turn cannot end.\n'
  printf '$ %s\n' "$cmd"
  printf '%s\n' "$out" | tail -n 50
  printf 'Fix and re-verify, or record the failure in lessons.md and escalate per the /task ladder.\n'
} >&2
exit 2
