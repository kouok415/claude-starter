#!/usr/bin/env bash
#
# guard-patterns.sh — the ONE source of the destructive-command matchers
# shared by the two enforcement layers:
#
#   stop-gate.sh   forbidden-verify denylist (sudo, git push, rm -rf on an
#                  absolute path) — verifies execute unattended at turn end
#   bash-guard.sh  PreToolUse tiers (deny: force-push / sudo / rm -rf on
#                  the root; ask: rm -rf on other absolute paths)
#
# v3.9 shipped two hand-mirrored copies, and the stop-gate's literal
# substrings let `rm -fr`, `rm -r -f` and double-space spellings execute
# at turn end (F8). One sourced file so the mirrored lists cannot drift;
# each hook carries a conservative built-in fallback for partially-synced
# projects — degraded means "the old guard", never "no guard".
#
# These are TRIPWIRE regexes (ERE, for grep -E): they stop the common
# spellings of an irreversible mistake and leave an audit line. `bash -c`,
# variable expansion, or piping to sh can still evade them — a documented
# boundary, not a bug to fix here.
#
# shellcheck disable=SC2034  # consumed by the sourcing hooks

# sudo as a standalone word.
GUARD_SUDO='(^|[[:space:];&|(])sudo([[:space:]]|$)'

# Any `git push`, whitespace-tolerant and word-bounded (the stop-gate
# refuses ALL pushes in verifies, not just forced ones).
GUARD_GIT_PUSH='(^|[[:space:];&|(])git[[:space:]]+push([[:space:];&|)]|$)'

# Force-push in any spelling, scoped to the push's pipeline segment:
# --force / --force-with-lease[=ref] / -f, plus the flagless `+refspec`
# form (`git push origin +main`) — a force-push with no flag at all (F12).
GUARD_FORCE_PUSH='git[[:space:]]+push[^|;&]*[[:space:]](--force(-with-lease[^[:space:]]*)?|-f)([[:space:]]|$)|git[[:space:]]+push[^|;&]*[[:space:]]\+[^[:space:]]'

# rm with recursive+force in ANY arrangement — combined (-rf, -fr, -rvf),
# split (-r -f, -f -r), long (--recursive/--force), with unrelated flags
# (e.g. --no-preserve-root) before, between, or after — targeting an
# absolute path. Token-built so flag order and spacing cannot dodge it.
_G_FLAG='-[-[:alnum:]]+'
_G_R='(-[[:alnum:]]*[rR][[:alnum:]]*|--recursive)'
_G_F='(-[[:alnum:]]*f[[:alnum:]]*|--force)'
_G_RF="(-[[:alnum:]]*([rR][[:alnum:]]*f|f[[:alnum:]]*[rR])[[:alnum:]]*|${_G_R}([[:space:]]+${_G_FLAG})*[[:space:]]+${_G_F}|${_G_F}([[:space:]]+${_G_FLAG})*[[:space:]]+${_G_R})"
_G_RM="(^|[[:space:];&|(])rm[[:space:]]+(${_G_FLAG}[[:space:]]+)*${_G_RF}([[:space:]]+${_G_FLAG})*[[:space:]]+[\"']?"

# ...on a path that leaves the project tree: absolute, home-relative
# (`~`, `$HOME`) or parent traversal (`..`) — stop-gate denylist,
# bash-guard ask tier. `$VAR/...` forms stay the documented boundary
# (v3.14.3: with the settings.json rm rule gone these spellings had no
# layer left; the CLI's critical-path breaker covers home itself, not
# `~/projects/x`).
GUARD_RM_RF_ABS="${_G_RM}(/|~|\\\$HOME|\.\.)"
# ...on the filesystem root (bash-guard deny tier). --no-preserve-root is
# a root delete by definition — denied on sight, target parsing aside.
GUARD_RM_RF_ROOT="${_G_RM}/([[:space:]]|\*|[\"']|$)|(^|[[:space:];&|(])rm[[:space:]][^|;&]*--no-preserve-root"

# Claude Code's own per-session scratchpad,
#   /tmp/claude-<uid>/<project>/<session>/scratchpad
# is disposable by construction — the harness creates it and throws it
# away, and milestones clean it constantly. bash-guard's ask tier scrubs
# these paths out before matching (v3.14.1): confirming them buys nothing
# and trains the human to click through the tier that matters. Exactly
# that shape; path characters only in the tail, so a `;rm -rf /etc`
# chained after it survives the scrub; the sourcing hook drops the
# exemption whenever the command contains `..`. bash-guard ONLY — the
# stop-gate denylist keeps refusing them, verifies run unattended.
GUARD_SCRATCHPAD='/tmp/claude-[[:alnum:]_.-]+/[[:alnum:]_.-]+/[[:alnum:]_.-]+/scratchpad[[:alnum:]_./@+~-]*'

# Anything one level below /tmp (v3.14.5, ADR-026): on a dev box /tmp is
# disposable by definition, and every /tmp/<name> the fleet's subagents
# ever deleted was their own temp dir. At least one real path character,
# no glob — `rm -rf /tmp`, `/tmp/` and `/tmp/*` keep asking. bash-guard
# ONLY, like GUARD_SCRATCHPAD. Known edge: the whole /tmp/claude-<uid>
# tree passes under this rule; the CLI does not catch that either.
GUARD_TMP_SUBDIR='/tmp/[[:alnum:]_.-]+[[:alnum:]_./@+~-]*'

# Setup-gate sentinel (ADR-004): the newborn-project trigger shared by
# session-start.sh (instruction layer) and stop-gate.sh (blocking layer) —
# two layers of ONE mechanism, so they must agree on the trigger domain.
# Sentinel first (v3.3 templates); legacy placeholder tokens kept for
# projects spawned before the sentinel existed.
GUARD_SETUP_SENTINEL='claude-starter: UNCONFIGURED|<e\.g\.,|<command>|Replace before first commit'

# The stop-gate's forbidden-verify test (three entries, absolute).
guard_forbidden_verify() { # $1 = verify command -> rc 0 when forbidden
  printf '%s' "$1" | grep -Eq "$GUARD_SUDO" && return 0
  printf '%s' "$1" | grep -Eq "$GUARD_GIT_PUSH" && return 0
  printf '%s' "$1" | grep -Eq "$GUARD_RM_RF_ABS" && return 0
  return 1
}

# --- v4 task helpers (claude-starter v4) ------------------------------------
# Shared with scripts/evidence.sh, which sources this file and refuses to run
# (exit 6) without all five — one copy of the static-command matcher and of
# the donelog writer (ADR-004).

# A command that only lints, parses or lists the code: each segment (split
# on && || ; |, leading VAR=x dropped) starts with a static tool or carries
# a no-op flag. evidence.sh trust refuses such a lane — it proves nothing.
GUARD_STATIC_HEAD='^(((bash|sh|zsh)[[:space:]]+-n)|(python3?[[:space:]]+-m[[:space:]]+(py_compile|compileall))|shellcheck|grep|egrep|fgrep|rg|test|\[|\[\[|ls|true|:|echo|printf|cat|wc|head|tail|find|stat|file|cd)([[:space:]]|$)'
GUARD_STATIC_FLAG='(^|[[:space:]])(--help|-h|--version|-V|--list-[^[:space:]]*|--parse-check|--selftest|--dry-run|--collect-only)([[:space:]]|$)'
static_only() { # $1 = command -> rc 0 when every segment is static
  local seg
  while IFS= read -r seg; do
    seg="$(printf '%s' "$seg" | sed -E 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*//')"
    [ -z "$seg" ] && continue
    printf '%s\n' "$seg" | grep -Eq "$GUARD_STATIC_HEAD|$GUARD_STATIC_FLAG" || return 1
  done < <(printf '%s\n' "$1" | awk '{ gsub(/&&|\|\||;|\|/, "\n"); print }')
  return 0
}

# .ai_context/tasks/CURRENT -> slug; rc 1 when absent, empty, or a path.
task_slug() { # $1 = project root
  local s
  s="$(tr -d '[:space:]' < "$1/.ai_context/tasks/CURRENT" 2>/dev/null)" || return 1
  case "$s" in ''|*/*|*..*) return 1 ;; esac
  printf '%s\n' "$s"
}

# The card's in-progress slice: S<n> of the first `- [~]` line, else `-`.
card_current_slice() { # $1 = card.md
  local s
  s="$(sed -nE 's/^- \[~\] (S[0-9]+)( .*)?$/\1/p' "$1" 2>/dev/null | head -n 1)"
  printf '%s\n' "${s:--}"
}

# A pid lock (.claude/evidence/locks/*.lock) is alive when its pid runs and,
# where ps exists, that process is evidence.sh or task-pair.sh (pid reuse).
lock_alive() { # $1 = pid
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$1" 2>/dev/null || return 1
  command -v ps >/dev/null 2>&1 || return 0
  ps -p "$1" -o args= 2>/dev/null | grep -Eq 'evidence\.sh|task-pair\.sh'
}

# One donelog row (v4 I-1): 7 TAB-separated fields, UTC ts first; TAB/CR/LF
# inside a field become spaces, empty fields `-`, result capped at 300 chars.
# No donelog directory (no task) -> nothing written. Always rc 0.
donelog_row() { # $1 = donelog, $2..$7 = TYPE slice lane|agent|class tree12 record result
  local f="$1" row i v; shift
  [ -d "${f%/*}" ] || return 0
  row="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  for i in 1 2 3 4 5 6; do
    v="$(printf '%s' "${1:-}" | tr '\t\r\n' '   ')"; shift 2>/dev/null
    [ "$i" = 6 ] && v="${v:0:300}"
    row="$row	${v:--}"
  done
  printf '%s\n' "$row" >> "$f" 2>/dev/null
  return 0
}
