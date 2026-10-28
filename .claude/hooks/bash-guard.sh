#!/usr/bin/env bash
#
# PreToolUse hook (Bash) — tripwire for catastrophic or sensitive commands.
#
# Two tiers (tiny list, absolute, logged):
#
#   deny (exit 2, stderr fed back to Claude, logged):
#     - force-push in any spelling (--force / --force-with-lease / -f)
#     - sudo
#     - rm -rf on the filesystem root
#   ask (JSON permissionDecision, human confirms):
#     - rm -rf leaving the project tree (absolute, ~/, $HOME/, ..) — except
#       inside the session's own /tmp/claude-*/…/scratchpad tree, which the
#       harness itself discards. The CLI drops hook asks under
#       bypassPermissions, so the ~/ $HOME/ ../ spellings are mirrored as
#       declarative ask rules in settings.json (v3.14.3) — those prompt in
#       every mode and can never touch a /tmp scratchpad path. The project'"'"'s
#       own tree is exempt like the scratchpad (v3.14.4), and so is any
#       /tmp/<name> — never /tmp itself or /tmp/* (v3.14.5).
#     - the ask tier reads the command with heredoc BODIES removed (v3.14.4):
#       prose in a memory-file write is not a command. The deny tier reads
#       the full text.
#     - commands touching .env files (H1) — .env.example/sample/template/dist
#       are exempt
#     - evidence.sh trust / approve / check / codex: the human's sign-off on a
#       lane, a card, a checker verdict, a Codex result (v4); `run
#       --escalated` past an ESCALATE; task-pair.sh --over-estimate
#     - writes to the evidence ledger (.claude/evidence/, the trust file) by
#       anything but an allowed evidence.sh call; writes to a task donelog,
#       into a pair mailbox (tasks/<slug>/pair/) or Codex's session
#       transcripts; writes to the scripts and settings the evidence chain
#       trusts (the Bash-side twin of settings.json's Edit asks)
#     - while a /task is active: git add -A / --all / . , git checkout --
#       <path>, git checkout . / -f, git switch --discard-changes, git
#       restore, git stash — the checker and the lanes read the main tree
#
# Hook asks are dropped under bypassPermissions; only the declarative asks
# in settings.json (trust/approve/check) survive there.
#
# This is contains-matching on the command string: stronger than the
# prefix-matched permission rules in settings.json (which it complements,
# not replaces), but still a TRIPWIRE, not a sandbox — `bash -c`, variable
# expansion, or piping to sh can evade it. The goal is to stop the common
# spelling of an irreversible mistake and leave an audit line, nothing more.
#
# Denies are absolute: no once-per-session yield. The correct way to run a
# denied command is for the human to run it themselves (or temporarily
# allow it) — that IS the approval the global rules require.

set -uo pipefail

ROOT="${CLAUDE_PROJECT_DIR:-.}"

# Shared destructive-op matchers — one source with the other hooks (F8/F12).
# Fallback: the v3.7–v3.9 built-ins, so a partially-synced project
# degrades to the old tripwire, never to none.
_GP="$(dirname "${BASH_SOURCE[0]}")/guard-patterns.sh"
# shellcheck source=guard-patterns.sh
[ -f "$_GP" ] && . "$_GP"
: "${GUARD_SUDO:=(^|[[:space:];&|(])sudo([[:space:]]|\$)}"
: "${GUARD_FORCE_PUSH:=git[[:space:]]+push[^|;&]*[[:space:]](--force(-with-lease[^[:space:]]*)?|-f)([[:space:]]|\$)}"
: "${GUARD_RM_RF_ROOT:=(^|[[:space:];&|(])rm[[:space:]]+-(rf|fr)[[:alnum:]]*[[:space:]]+/([[:space:]]|\*|\$)}"
: "${GUARD_RM_RF_ABS:=(^|[[:space:];&|(])rm[[:space:]]+-(rf|fr)[[:alnum:]]*[[:space:]]+/[^[:space:]]}"
: "${GUARD_SCRATCHPAD:=/tmp/claude-[[:alnum:]_.-]+/[[:alnum:]_.-]+/[[:alnum:]_.-]+/scratchpad[[:alnum:]_./@+~-]*}"
: "${GUARD_TMP_SUBDIR:=/tmp/[[:alnum:]_.-]+[[:alnum:]_./@+~-]*}"

payload="$(cat 2>/dev/null || true)"

# Extract tool_input.command (and the payload's cwd, line 1); fall back to
# matching the raw payload (a false positive from JSON noise is acceptable for
# a tripwire, a silent parser failure is not).
cmd="$(printf '%s' "$payload" | python3 -c '
import json, sys
try:
    p = json.load(sys.stdin)
    c = p.get("cwd")
    print("C" + (c if isinstance(c, str) else "").replace("\n", " "))
    print(p.get("tool_input", {}).get("command", ""))
except Exception:
    pass
' 2>/dev/null || true)"
pcwd=""
case "$cmd" in
  C*) pcwd="${cmd%%$'\n'*}"; pcwd="${pcwd#C}"
      case "$cmd" in *$'\n'*) cmd="${cmd#*$'\n'}" ;; *) cmd="" ;; esac ;;
esac
[ -n "$cmd" ] || cmd="$payload"

log_deny() { # $1 = reason
  [ -d "$ROOT/.ai_context" ] || return 0
  mkdir -p "$ROOT/.ai_context/private" 2>/dev/null || return 0
  printf '%s\tDENY\t%s\t%s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$1" \
    "$(printf '%s' "$cmd" | tr '\t\n' '  ' | cut -c1-300)" \
    >> "$ROOT/.ai_context/private/bash-guard.log" 2>/dev/null || true
}

deny() { # $1 = short reason, $2 = guidance
  log_deny "$1"
  {
    printf 'BASH GUARD — blocked (%s). This command is never run unattended:\n' "$1"
    printf '$ %s\n' "$cmd"
    printf '%s\n' "$2"
  } >&2
  exit 2
}

ask() { # $1 = reason shown in the confirmation prompt (static text only)
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"}}\n' "$1"
  exit 0
}

# --- deny tier ---------------------------------------------------------------
if printf '%s' "$cmd" | grep -Eq "$GUARD_SUDO"; then
  deny 'sudo' 'Privileged commands need the human: ask them to run it (e.g. via `! sudo ...`).'
fi

# Any force-push spelling: --force / --force-with-lease / -f flags scoped to
# the push's pipeline segment, plus the flagless `+refspec` form (F12).
if printf '%s' "$cmd" | grep -Eq "$GUARD_FORCE_PUSH"; then
  deny 'force-push' 'Force-pushes require explicit human approval (global git rules): the human runs it, or temporarily allows it.'
fi

# Recursive+force rm on the root in any flag arrangement, including
# flag-separated roots like `rm -rf --no-preserve-root /` (F12).
if printf '%s' "$cmd" | grep -Eq "$GUARD_RM_RF_ROOT"; then
  deny 'rm -rf on /' 'Refusing to delete from the filesystem root.'
fi

# --- ask tier ----------------------------------------------------------------
# The ask tier reads a PROBE, not the raw command (v3.14.4):
#   1. heredoc bodies are dropped — prose written into a memory file is not
#      a command. 17 of the 48 subagent `.env` stalls in the fleet since
#      2026-08-01 were a plan or state.md that mentioned `.env`; each parked
#      a subagent for a median 10 minutes, hours overnight. The deny tier
#      above keeps the full text, so `bash <<EOF` smuggling a denied command
#      is still caught. Python failure or an unterminated heredoc ⇒ the
#      full command (fail towards asking). Boundary: a heredoc that is
#      itself EXECUTED (`python3 - <<PY` calling os.system) is now outside
#      the ask tier — the same class as `bash -c`; the deny tier sees it.
#   2. for the rm test, disposable trees are scrubbed: the session
#      scratchpad (GUARD_SCRATCHPAD, v3.14.1), the project's own tree
#      ($CLAUDE_PROJECT_DIR/…, v3.14.4 — a relative `rm -rf build` was
#      always silent; its absolute spelling should not cost a click) and
#      any /tmp/<name> (GUARD_TMP_SUBDIR, v3.14.5 — /tmp is disposable by
#      definition; `/tmp`, `/tmp/` and `/tmp/*` still ask). Any
#      `..` in the command keeps the full string — fail towards asking
#      rather than reason about where a traversal lands.
ask_probe="$(printf '%s' "$cmd" | python3 -c '
import re, sys
s = sys.stdin.read()
sys.stdout.write(re.sub(r"(<<-?[ \t]*([\x27\"]?)(\w+)\2[^\n]*\n)(?:.*?\n)?(^[ \t]*\3[ \t]*$)", r"\1\4", s, flags=re.S | re.M))
' 2>/dev/null)" || ask_probe="$cmd"
[ -n "$ask_probe" ] || ask_probe="$cmd"

rm_probe="$ask_probe"
case "$cmd" in
  *..*) ;;
  *)
    tree_re=""
    case "${ROOT%/}" in
      /?*) tree_re="$(printf '%s' "${ROOT%/}" | sed 's/[][\\.*^$+?(){}|#]/\\&/g')/[[:alnum:]_./@+~-]+" ;;
    esac
    rm_probe="$(printf '%s' "$ask_probe" | sed -E "s#${GUARD_SCRATCHPAD}##g; s#${GUARD_TMP_SUBDIR}##g${tree_re:+; s#${tree_re}##g}")" ;;
esac
if printf '%s' "$rm_probe" | grep -Eq "$GUARD_RM_RF_ABS"; then
  ask 'rm -rf beyond the project tree (absolute, ~/, $HOME/, ..) — confirm the target is disposable'
fi

stripped="$(printf '%s' "$ask_probe" | sed -E 's/\.env\.(example|sample|template|dist)//g')"
if printf '%s' "$stripped" | grep -Eq '(^|[^[:alnum:]_])\.env(\.[[:alnum:]_.-]+)?([^[:alnum:]_.-]|$)'; then
  ask 'touches .env files (H1: secrets) — confirm this should happen'
fi

if printf '%s' "$ask_probe" | grep -Eq '(^|[^[:alnum:]_])\.secrets/'; then
  ask 'touches .secrets/ (runtime-only credentials, H1) — confirm this should happen'
fi

# --- v4: the evidence ledger and a /task's working tree ------------------------
# Needs the v4 matchers: with an older guard-patterns.sh (partial sync) this
# degrades to the v3 guard above — an empty regex would ask on every command.
[ "${GUARD_PATTERNS_V4:-}" = 1 ] || exit 0

# Matchers added after the first v4 release: an older guard-patterns.sh leaves them
# unset, and an empty ERE would match every command — default to one that never does.
for v in GUARD_GIT_CHECKOUT GUARD_GIT_RESTORE_STAGED GUARD_GIT_RESTORE_WT GUARD_GIT_READ GUARD_LEDGER_DIR \
         GUARD_TRUST_FILE GUARD_TRUST_REDIRECT GUARD_RM_CLAUDE GUARD_RM_RECURSIVE GUARD_DONELOG_WRITE \
         GUARD_DONELOG_WRITE_REL GUARD_CD_AICTX GUARD_CHAIN_WRITE GUARD_PAIR_WRITE GUARD_PAIR_WRITE_REL \
         GUARD_PAIR_WRITE_ANY GUARD_CD_PAIR GUARD_CODEX_SESSIONS_WRITE; do
  [ -n "${!v:-}" ] || printf -v "$v" '%s' 'x^'
done

has() { printf '%s' "$ask_probe" | grep -Eq -- "$1"; }

# Some segment (split on ; & | and newlines) of $SEG_IN (default: the probe)
# matches $1 and $3, and not $2 — unless it also matches $4.
seg_any() { # $1 = ERE to hit, $2 = ERE to exclude ('' = none), $3 = ERE also required ('' = none), $4 = exclusion override
  local seg
  while IFS= read -r seg; do
    printf '%s' "$seg" | grep -Eq -- "$1" || continue
    if [ -n "${2:-}" ] && printf '%s' "$seg" | grep -Eq -- "$2" &&
       ! { [ -n "${4:-}" ] && printf '%s' "$seg" | grep -Eq -- "$4"; }; then
      continue
    fi
    [ -n "${3:-}" ] && ! printf '%s' "$seg" | grep -Eq -- "$3" && continue
    return 0
  done < <(printf '%s\n' "${SEG_IN:-$ask_probe}" | tr ';&|' '\n\n\n')
  return 1
}

# The whole command is one allowed evidence.sh call (run/status/show/...).
evidence_ok() {
  case "$cmd" in *$'\n'*) return 1 ;; esac
  printf '%s' "$cmd" | grep -Eq -- "$GUARD_EVIDENCE_OK"
}

# The ledger is guarded at any time, task or not (A1–A6).
# A1–A3b read evidence.sh in command position on a normalised probe: backslash-
# newlines joined, quotes and backslashes deleted, one segment per ; & | ( ) ` or
# newline — `'trust'`, `"approve"`, `evidence\.sh` and `\⏎trust` all ask, a
# commit message that mentions `evidence.sh check` does not (GUARD_EVIDENCE_HUMAN).
sub="$(printf '%s\n' "$ask_probe" | awk '{ if (sub(/\\$/, "")) printf "%s", $0; else print }' |
  tr -d "\"'\\\\" | tr ';&|()`' '\n\n\n\n\n\n' | grep -E -m 1 -- "$GUARD_EVIDENCE_HUMAN" |
  sed -E 's/^.*evidence\.sh[[:space:]]+([a-z]+).*$/\1/')"
case "$sub" in
  trust) ask "evidence.sh trust — YOU approve this lane command as proof of done; confirm only after reading the lane's whole line and every @ line in .claude/done-lanes (the trust binds them and .claude/gitleaks.toml)" ;;
  approve) ask 'evidence.sh approve — records YOUR approval of the task card; confirm only if you, the human, have read and approve this card' ;;
  check) ask 'evidence.sh check — writes a checker record by hand (the SubagentStop hook normally writes it); confirm only if you, the human, attest this checker verdict' ;;
  codex) ask 'evidence.sh codex — writes a Codex review record; scripts/task-pair.sh calls it itself (that call never passes this hook); confirm only if you, the human, are recording a Codex result by hand' ;;
esac
if has "$GUARD_PAIR_OVERESTIMATE"; then
  ask 'task-pair.sh --over-estimate — runs Codex past the run count you approved with the card (it spends your Codex quota); confirm only if you, the human, want more Codex runs for this task'
fi
if has "$GUARD_EVIDENCE_OVERRIDE"; then
  ask 'evidence.sh run past an ESCALATE (3 failed runs of this lane for this slice) — confirm only if you, the human, want another attempt'
fi
# A5 on a probe with /./ and // collapsed: the ledger directory; the trust file,
# except where git only reads or stages it (a redirect onto it still asks); rm -r
# of .claude itself.
lp="$(printf '%s' "$ask_probe" | sed -E 's#/\./#/#g; s#/\./#/#g; s#//+#/#g')"
if ! evidence_ok && { SEG_IN="$lp" seg_any "$GUARD_LEDGER_DIR" ||
     SEG_IN="$lp" seg_any "$GUARD_TRUST_FILE" "$GUARD_GIT_READ" '' "$GUARD_TRUST_REDIRECT" ||
     SEG_IN="$lp" seg_any "$GUARD_RM_CLAUDE" '' "$GUARD_RM_RECURSIVE"; }; then
  ask 'touches .claude/evidence/ or .claude/done-lanes.trust, which only scripts/evidence.sh writes — read them with the Read tool or evidence.sh status/show; confirm only if you, the human, intend this'
fi
# A6: a donelog is tracked — git add, cat, grep, wc, sed -n, cp elsewhere stay
# silent; only writes ask. Inside .ai_context (a cd in the command, or the
# payload's cwd) a bare `donelog` operand counts too.
dlw="$GUARD_DONELOG_WRITE"
case "$pcwd" in */.ai_context|*/.ai_context/*) dlw="$GUARD_DONELOG_WRITE_REL" ;; esac
has "$GUARD_CD_AICTX" && dlw="$GUARD_DONELOG_WRITE_REL"
if seg_any "$dlw" && ! evidence_ok; then
  ask 'writes a task donelog, which only scripts/evidence.sh and the hooks append to — confirm only if you, the human, intend this'
fi
# C1 (pair review): a pair mailbox (packets, the judge's results; settings.json
# Edit-denies it) and Codex's session transcripts, which evidence.sh codex binds a
# result to. scripts/task-pair.sh and the judge write there without this hook;
# only writes ask, as in A6. Inside .ai_context a bare pair/… counts; inside a
# pair/ dir, any relative operand. A custom $CODEX_HOME counts by its literal path.
pw="$GUARD_PAIR_WRITE|$GUARD_CODEX_SESSIONS_WRITE"
case "$pcwd" in */.ai_context|*/.ai_context/*) pw="$pw|$GUARD_PAIR_WRITE_REL" ;; esac
has "$GUARD_CD_AICTX" && pw="$pw|$GUARD_PAIR_WRITE_REL"
case "$pcwd" in */.ai_context/tasks/*/pair|*/.ai_context/tasks/*/pair/*) pw="$pw|$GUARD_PAIR_WRITE_ANY" ;; esac
has "$GUARD_CD_PAIR" && pw="$pw|$GUARD_PAIR_WRITE_ANY"
cxw=""
if [ -n "${CODEX_HOME:-}" ] && declare -F _g_write >/dev/null; then
  _g_write cxw "$(printf '%s' "${CODEX_HOME%/}" | sed 's/[][\\.*^$+?(){}|#]/\\&/g')/sessions(/[^[:space:];&|<>\"']*)?([\"'[:space:])]|\$)"
  pw="$pw|$cxw"
fi
if seg_any "$pw"; then
  ask "writes into a /task pair mailbox (.ai_context/tasks/<slug>/pair/: packets and the judge's results, written only by scripts/task-pair.sh and the judge) or into Codex's session transcripts that evidence.sh codex binds those results to — confirm only if you, the human, intend this"
fi
# The Bash-side twin of settings.json's Edit asks on the evidence chain.
if seg_any "$GUARD_CHAIN_WRITE"; then
  ask 'writes a script or setting the evidence chain trusts (evidence.sh, the hooks, guard-patterns, the checker agent, the gitleaks wrapper, harness-report, settings.json or settings.local.json) — confirm only if you, the human, intend this change'
fi

# A checkout segment naming an existing work-tree path without `--` (G2).
checkout_path() {
  local seg w skip ws
  while IFS= read -r seg; do
    printf '%s' "$seg" | grep -Eq -- "$GUARD_GIT_CHECKOUT" || continue
    read -ra ws <<< "$(printf '%s' "${seg##*checkout}" | tr -d "\"'")"
    skip=""
    for w in ${ws[@]+"${ws[@]}"}; do
      if [ -n "$skip" ]; then skip=""; continue; fi
      case "$w" in -b|-B|--orphan) skip=1; continue ;; -*) continue ;; esac
      case "$w" in
        /*) [ -e "$w" ] && return 0 ;;
        *) { [ -e "$ROOT/$w" ] || { [ -n "$pcwd" ] && [ -e "$pcwd/$w" ]; }; } && return 0 ;;
      esac
    done
  done < <(printf '%s\n' "$ask_probe" | tr ';&|' '\n\n\n')
  return 1
}

# While a /task is active (G1–G5): commands that throw uncommitted work away.
# task_active may run git, so it is asked only after a matcher hits.
g=""
if has "$GUARD_GIT_ADD_ALL"; then g=add
elif has "$GUARD_GIT_CHECKOUT_PATH"; then g=checkout
elif seg_any "$GUARD_GIT_RESTORE" "$GUARD_GIT_RESTORE_STAGED" '' "$GUARD_GIT_RESTORE_WT"; then g=restore
elif seg_any "$GUARD_GIT_STASH" "$GUARD_GIT_STASH_READ"; then g=stash
elif has "$GUARD_GIT_DISCARD"; then g=discard
elif checkout_path; then g=checkout
fi
if [ -n "$g" ] && task_active "$ROOT"; then
  case "$g" in
    add) ask 'git add -A / --all / . while a /task is active — stage the slice files by name; confirm only if every changed file belongs in this commit' ;;
    checkout) ask 'git checkout [--] <path> / git checkout . overwrites uncommitted work while a /task is active — confirm nothing unsaved is lost' ;;
    restore) ask 'git restore overwrites uncommitted work while a /task is active — confirm nothing unsaved is lost' ;;
    stash) ask 'git stash moves uncommitted work out of the tree that lanes and the checker read while a /task is active — confirm (git stash list/show never ask)' ;;
    discard) ask 'git checkout -f / git switch --discard-changes throws away uncommitted work while a /task is active — confirm nothing unsaved is lost' ;;
  esac
fi

exit 0
