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

# ...on any absolute path (stop-gate denylist; bash-guard ask tier).
GUARD_RM_RF_ABS="${_G_RM}/"
# ...on the filesystem root (bash-guard deny tier). --no-preserve-root is
# a root delete by definition — denied on sight, target parsing aside.
GUARD_RM_RF_ROOT="${_G_RM}/([[:space:]]|\*|[\"']|$)|(^|[[:space:];&|(])rm[[:space:]][^|;&]*--no-preserve-root"

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
