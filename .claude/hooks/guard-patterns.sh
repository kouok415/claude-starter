#!/usr/bin/env bash
#
# guard-patterns.sh — the ONE source of the matchers and task helpers shared
# by the hooks (ADR-004):
#
#   bash-guard.sh     PreToolUse tiers (deny: force-push / sudo / rm -rf on
#                     the root; ask: rm -rf leaving the tree, the evidence
#                     ledger and chain, git commands that drop work during a
#                     /task)
#   stop-gate.sh and  setup sentinel; task helpers (CURRENT, idle task,
#   session-start.sh  pid locks)
#   spawn-log.sh      task helpers, the donelog writer
#
# scripts/evidence.sh sources it too (static-command matcher, donelog writer,
# the done-slice regex the gate shares).
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
# (`~`, `$HOME`) or parent traversal (`..`) — bash-guard ask tier. `$VAR/...` forms stay the documented boundary
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
# exemption whenever the command contains `..`. bash-guard ONLY.
GUARD_SCRATCHPAD='/tmp/claude-[[:alnum:]_.-]+/[[:alnum:]_.-]+/[[:alnum:]_.-]+/scratchpad[[:alnum:]_./@+~-]*'

# Anything one level below /tmp (v3.14.5, ADR-026): on a dev box /tmp is
# disposable by definition, and every /tmp/<name> the fleet's subagents
# ever deleted was their own temp dir. At least one real path character,
# no glob — `rm -rf /tmp`, `/tmp/` and `/tmp/*` keep asking. Known edge:
# the whole /tmp/claude-<uid> tree passes under this rule; the CLI does
# not catch that either.
GUARD_TMP_SUBDIR='/tmp/[[:alnum:]_.-]+[[:alnum:]_./@+~-]*'

# Setup-gate sentinel (ADR-004): the newborn-project trigger shared by
# session-start.sh (instruction layer) and stop-gate.sh (blocking layer) —
# two layers of ONE mechanism, so they must agree on the trigger domain.
# Sentinel first (v3.3 templates); legacy placeholder tokens kept for
# projects spawned before the sentinel existed.
GUARD_SETUP_SENTINEL='claude-starter: UNCONFIGURED|<e\.g\.,|<command>|Replace before first commit'

# --- v4 bash-guard ask tier (claude-starter v4) ------------------------------
# git commands that throw uncommitted work away, asked only while a /task is
# active (the checker reads the main tree; lanes hash it). A git word — also
# /usr/bin/git and the quoted script of `bash -c "git …"` — then any global
# options (-C <dir>, -c <k=v>, --flags), then the subcommand.
_G_GIT='(^|[[:space:];&|("'"'"'/])git([[:space:]]+(-[Cc][[:space:]]+[^[:space:];&|]+|--?[[:alnum:]][^[:space:];&|]*))*[[:space:]]+'
_G_END='([[:space:];&|)"'"'"']|$)'
GUARD_GIT_ADD_ALL="${_G_GIT}add([[:space:]]+[^[:space:];&|]+)*[[:space:]]+["'"'"']?(-[[:alnum:]]*A[[:alnum:]]*|--all|\\.|\\./|:/|\\*)${_G_END}"
GUARD_GIT_CHECKOUT_PATH="${_G_GIT}checkout([[:space:]]+[^[:space:];&|]+)*[[:space:]]+(--[[:space:]]+[^[:space:];&|]|\\.${_G_END})"
# Any checkout: bash-guard then asks when one of its words is an existing path (`git checkout src/a.txt`).
GUARD_GIT_CHECKOUT="${_G_GIT}checkout${_G_END}"
GUARD_GIT_RESTORE="${_G_GIT}restore${_G_END}"
# `git restore --staged <x>` only unstages; with --worktree / -W it also overwrites the file.
GUARD_GIT_RESTORE_STAGED='(^|[[:space:]])(--staged|-[[:alnum:]]*S[[:alnum:]]*)([[:space:]"'"'"']|$)'
GUARD_GIT_RESTORE_WT='(^|[[:space:]])(--worktree|-[[:alnum:]]*W[[:alnum:]]*)([[:space:]"'"'"']|$)'
GUARD_GIT_STASH="${_G_GIT}stash${_G_END}"
GUARD_GIT_STASH_READ="${_G_GIT}stash[[:space:]]+(list|show)${_G_END}"
GUARD_GIT_DISCARD="${_G_GIT}(checkout|switch)([[:space:]]+[^[:space:];&|]+)*[[:space:]]+(-[[:alnum:]]*f[[:alnum:]]*|--force|--discard-changes)${_G_END}"
# git subcommands that only read or stage: they may name the trust file (pre-commit keeps it append-only).
GUARD_GIT_READ="${_G_GIT}(add|diff|log|show)${_G_END}"

# The evidence ledger: only scripts/evidence.sh writes it. trust, approve and
# check are the human's sign-off; codex is task-pair.sh's own call.
# GUARD_EVIDENCE_HUMAN reads ONE command segment of a normalised probe (bash-guard
# joins backslash-newlines, deletes quotes and backslashes, then splits on ; & | ( )
# backticks and newlines): evidence.sh in command position — after env assignments,
# bash/sh/env/exec/timeout-style wrappers and their flags, by any path. So `evidence.sh
# check` inside a `git commit -m` message stays silent, unless the message itself puts
# one of those separators right before it. Globs (evid*.sh), variables and symlinks
# naming the script stay the documented boundary.
GUARD_EVIDENCE_HUMAN='^[[:space:]]*(([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*|bash|sh|zsh|dash|env|command|exec|nohup|time|timeout|nice|-[^[:space:]]*|[0-9][0-9.]*[smhd]?)[[:space:]]+)*([^[:space:]]*/)?evidence\.sh[[:space:]]+(trust|approve|check|codex)([[:space:]]|$)'
GUARD_EVIDENCE_OVERRIDE='evidence\.sh[[:space:]]+run[[:space:]][^;&|]*--escalated'
GUARD_PAIR_OVERESTIMATE='(^|[[:space:];&|(/])task-pair\.sh[[:space:]].*--over-estimate([[:space:];&|)]|$)'
# A5, read on a probe whose /./ and // are collapsed: the ledger directory, the trust
# file (git add/diff/log/show of it exempt), and rm -r of .claude itself.
GUARD_LEDGER_DIR="\\.claude/evidence(/|[[:space:];&|)\"']|\$)"
GUARD_TRUST_FILE='\.claude/done-lanes\.trust'
GUARD_TRUST_REDIRECT=">[>|]?[[:space:]]*[^[:space:];&|<>]*${GUARD_TRUST_FILE}"
GUARD_RM_CLAUDE='(^|[[:space:];&|(])rm[[:space:]]([^;&|]*[[:space:]])?["'"'"']?([^[:space:];&|]*/)?\.claude(/\*?)?["'"'"']?([[:space:];&|)]|$)'
GUARD_RM_RECURSIVE='(^|[[:space:]])(-[[:alnum:]]*[rR][[:alnum:]]*|--recursive)([[:space:]]|$)'

# A Bash-side WRITE to a file (target ERE $2), set into variable $1: a redirect onto it,
# tee/truncate onto it, rm/mv/unlink/shred of it, sed/perl -i or awk -i inplace on it,
# cp/install/ln/rsync with it as the last word (trailing redirections aside), dd of=it.
# Reads (cat, grep, wc, sed -n, awk without -i, cp it elsewhere, 2>/dev/null) never match.
_g_write() { # $1 = variable name, $2 = target ERE (anchored at a word start by the forms here)
  printf -v "$1" '%s' ">[>|]?[[:space:]]*$2|(^|[[:space:]])(tee|truncate|rm|mv|unlink|shred)[[:space:]]([^;&|]*[[:space:]])?$2|(^|[[:space:]])(sed|perl)[[:space:]]([^;&|]*[[:space:]])?(-[[:alnum:]]*i|--in-place)[^;&|]*[[:space:]]$2|(^|[[:space:]])g?awk[[:space:]]([^;&|]*[[:space:]])?-i[[:space:]]*inplace[^;&|]*[[:space:]]$2|(^|[[:space:]])(cp|install|ln|rsync)[[:space:]]([^;&|]*[[:space:]])?$2([[:space:]]*[0-9]*>&?[^[:space:]]*)*[[:space:]]*\$|of=$2"
}
# A6: a task donelog (only evidence.sh and the hooks append to it). _REL is used when
# the command cd's into .ai_context (GUARD_CD_AICTX) or runs there: a bare `donelog`.
_g_write GUARD_DONELOG_WRITE '[^[:space:];&|<>]*\.ai_context/tasks/[^[:space:]/;&|<>"'"'"']+/donelog(["'"'"'[:space:])]|$)'
_g_write GUARD_DONELOG_WRITE_REL '([^[:space:];&|<>]*/|["'"'"'])?donelog(["'"'"'[:space:])]|$)'
GUARD_CD_AICTX='(^|[[:space:];&|(])(cd|pushd)[[:space:]]+([^;&|]*[[:space:]])?["'"'"']?[^[:space:];&|]*\.ai_context([/"'"'"'[:space:];&|)]|$)'
# A /task pair mailbox, tasks/<slug>/pair/: script-written packets and the judge's results
# (settings.json Edit-denies it; pair review C1). _REL: a bare pair/… once the command cd's
# into .ai_context or runs there; _ANY: any relative operand once it cd's into, or runs in,
# a pair/ dir itself.
_g_write GUARD_PAIR_WRITE '[^[:space:];&|<>]*\.ai_context/tasks/[^[:space:]/;&|<>"'"'"']+/pair(/[^[:space:];&|<>"'"'"']*)?(["'"'"'[:space:])]|$)'
_g_write GUARD_PAIR_WRITE_REL '([^[:space:];&|<>]*/|["'"'"'])?pair/[^[:space:];&|<>"'"'"']*(["'"'"'[:space:])]|$)'
_g_write GUARD_PAIR_WRITE_ANY '["'"'"']?[^-/~$&[:space:];|<>"'"'"'][^[:space:];&|<>]*'
GUARD_CD_PAIR='(^|[[:space:];&|(])(cd|pushd)[[:space:]]+([^;&|]*[[:space:]])?["'"'"']?([^[:space:];&|]*/)?pair/?["'"'"']?([[:space:];&|)]|$)'
# Codex's session transcripts (~/.codex/sessions, $CODEX_HOME/sessions): evidence.sh codex binds
# a Codex result to the judge's own write recorded there (C1).
_g_write GUARD_CODEX_SESSIONS_WRITE '[^[:space:];&|<>]*(\.codex|CODEX_HOME\}?)/sessions(/[^[:space:];&|<>"'"'"']*)?(["'"'"'[:space:])]|$)'
# The scripts and settings the evidence chain trusts — the files settings.json Edit-asks.
_g_write GUARD_CHAIN_WRITE '[^[:space:];&|<>]*(scripts/(evidence|precommit-gitleaks|harness-report)\.sh|\.claude/hooks/(guard-patterns|stop-gate|spawn-log|bash-guard|session-start)\.sh|\.claude/agents/checker\.md|\.claude/settings(\.local)?\.json)(["'"'"'[:space:])]|$)'
# The whole command is ONE allowed evidence.sh call: a literal "$CLAUDE_PROJECT_DIR"/
# or plain path prefix (no $( ) < > or backtick), no ; & | redirect, backtick or $ after.
GUARD_EVIDENCE_OK='^[[:space:]]*(bash[[:space:]]+)?("\$CLAUDE_PROJECT_DIR"/|[A-Za-z0-9_./~+@-]*)scripts/evidence\.sh[[:space:]]+(run|status|show|done|close|start|lint)([[:space:]][^;&|<>`$]*)?$'

# A done slice line of a card, as the Stop gate and evidence.sh status read it (one regex, hooks review M1).
GUARD_SLICE_X='^- \[x\] S[0-9]+([[:space:]]|$)'

# --- v4 task helpers (claude-starter v4) ------------------------------------
# Shared with scripts/evidence.sh, which sources this file and refuses to run
# (exit 6) without all five and GUARD_SLICE_X — one copy of the static-command
# matcher, of the donelog writer and of the done-slice regex (ADR-004).

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
  s="$(tr -d '[:space:]' 2>/dev/null < "$1/.ai_context/tasks/CURRENT")" || return 1
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

# Idle task (D6): card, donelog and the task/<slug> branch all untouched for a
# week. An idle card is not injected and the Stop gate does not check it.
TASK_IDLE_SECS=604800

file_mtime() { # $1 = path -> epoch seconds; empty when absent
  [ -e "$1" ] || return 0
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

# Newest of card.md and donelog mtimes; only when both are a week old is the
# last commit on task/<slug> asked for (one git call, and only then).
task_last_active() { # $1 = root, $2 = slug -> epoch; empty when nothing is known
  local d="$1/.ai_context/tasks/$2" t c
  t="$(file_mtime "$d/card.md")"
  c="$(file_mtime "$d/donelog")"
  if [ -n "$c" ] && { [ -z "$t" ] || [ "$c" -gt "$t" ]; }; then t="$c"; fi
  if [ -z "$t" ] || [ $(($(date +%s) - t)) -gt "$TASK_IDLE_SECS" ]; then
    c="$(git -C "$1" log -1 --format=%ct "refs/heads/task/$2" 2>/dev/null)"
    if [ -n "$c" ] && { [ -z "$t" ] || [ "$c" -gt "$t" ]; }; then t="$c"; fi
  fi
  printf '%s\n' "$t"
}

task_idle() { # $1 = root, $2 = slug -> rc 0 when idle; an unknown age is not idle
  local t
  t="$(task_last_active "$1" "$2")"
  [ -n "$t" ] && [ $(($(date +%s) - t)) -gt "$TASK_IDLE_SECS" ]
}

task_idle_days() { # $1 = root, $2 = slug -> whole days since the last activity
  local t
  t="$(task_last_active "$1" "$2")"
  [ -n "$t" ] && echo $((($(date +%s) - t) / 86400))
}

# A /task is active: CURRENT names a slug, its card exists, and it is not idle.
# A v3 CURRENT (plan.md, no card.md) is no active task for the v4 hooks.
task_active() { # $1 = root
  local s
  s="$(task_slug "$1")" && [ -f "$1/.ai_context/tasks/$s/card.md" ] && ! task_idle "$1" "$s"
}

# Set last: a hook that sees it knows every v4 matcher and helper above exists.
GUARD_PATTERNS_V4=1
