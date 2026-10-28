#!/usr/bin/env bash
# task-pair.sh — drive the Codex judge of a /task over herdr (pair on).
#
# The skill (pair.md) decides WHEN to ask; this script asks the same way
# every time. Files are the contract: `tasks/<slug>/pair/NNN-<stage>[-S<n>].md`
# packet in, `.result.md` out. herdr starts the agent, submits, waits and
# reports `blocked`. The script decides only run_state and never prints a
# verdict of its own; every settled run becomes an evidence record through
# `scripts/evidence.sh codex` (workshop ADR-028, ADR-030, ADR-039).
#
#   ensure                                  find or start the judge
#   check card                              write the card packet, send it
#   check slice S<n> [--since REF]          REF: the HEAD `evidence.sh start` recorded
#   check final [--since REF] [--rebuttal F]  REF: the card's base:
#   packet <same as check>                  write the packet only, print its path
#   send <packet> [--timeout MS] [--over-estimate]  /new, prompt, wait, collect, record
#   wait <seq> [--timeout MS]               re-attach to a run still in flight
#   digest                                  card:<sha256>, status marks excluded
#   fingerprint                             tree fingerprint (test seam)
#
# REF defaults to that commit and must be it: evidence.sh codex binds a
# review only to the content since there. Run check/send/wait in the
# background: one run can take an hour. A run past what the human consented
# to (pair.md §Quota) is refused (3); --over-estimate is for after their yes.
# Exit: 0 completed + recorded (the verdict is in the result); 2 usage;
# 3 refused; 4 the judge needs the human; 5 in flight / herdr wait timed
# out (run wait <seq>); 6 no usable result, record not written, or not_started.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
DEFAULT_TIMEOUT_MS=7200000   # send runs in the background; this is herdr's own wait, not a tool-call cap
START_TIMEOUT_MS=60000
START_GRACE_S="${TASK_PAIR_START_GRACE_S:-10}"   # a turn that shows no sign of starting gets this long (tests shorten it)

# Paths under $HOME are written as ~/…: pair/ is tracked, and a home path
# names the user (runlog, packets, screen dumps, messages).
# shellcheck disable=SC2088  # t is a literal ~/ on purpose
tilde() { local t='~/'; if [ -n "${HOME:-}" ] && [ "$HOME" != / ]; then printf '%s' "${1//"$HOME"\//$t}"; else printf '%s' "$1"; fi; }
die() { echo "task-pair: $(tilde "$*")" >&2; exit "${RC:-2}"; }
refuse() { RC=3 die "$@"; }

# --- JSON helpers (herdr prints compact JSON; no jq in the template) -------
jstr() { # $1 = key -> first string value of that key on stdin
  sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
}

hash_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256
  else cksum
  fi
}

# HEAD + status + diff + untracked content, minus what is machine-written
# while a run is in flight: the runlog, the judge record, `.fp-*`, this
# run's result, and the donelog and .claude/evidence/ — the gate, spawn-log
# and a parallel checker write those during every run (R16). Everything
# else under pair/ (packets, old results) counts: a judge that touched
# anything voids its own verdict.
fingerprint() {
  git -C "$ROOT" rev-parse HEAD >/dev/null 2>&1 || return 1
  local ex=(':(exclude).claude/evidence')
  [ -z "${TASK:-}" ] || ex+=(":(exclude)$TASK/donelog")
  [ -z "${PAIR_DIR:-}" ] || ex+=(":(exclude)$PAIR_DIR/runlog" ":(exclude)$PAIR_DIR/judge" ":(exclude,glob)$PAIR_DIR/.fp-*")
  [ -z "${RESULT:-}" ] || ex+=(":(exclude)$RESULT")
  {
    git -C "$ROOT" rev-parse HEAD
    git -C "$ROOT" status --porcelain -- . "${ex[@]}"
    git -C "$ROOT" diff HEAD -- . "${ex[@]}"
    git -C "$ROOT" ls-files -o --exclude-standard -- . "${ex[@]}" | while IFS= read -r uf; do
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

# --- Task, pair mode, card digest ----------------------------------------------
SLUG=""; TASK=""; CARD=""; PAIR_DIR=""; RUNLOG=""; JUDGE_FILE=""; NAME=""; SAFE_SLUG=""; REPO_ID=""
RESULT=""; SCRATCH=""; LOCK=""; OVER=""
resolve_task() {
  [ -z "$PAIR_DIR" ] || return 0
  [ -f .ai_context/tasks/CURRENT ] || refuse "no active task (.ai_context/tasks/CURRENT missing)"
  SLUG="$(tr -d '[:space:]' < .ai_context/tasks/CURRENT)"
  case "$SLUG" in ''|*/*|*..*) refuse "no active task (.ai_context/tasks/CURRENT names no slug)" ;; esac
  TASK=".ai_context/tasks/$SLUG"; CARD="$TASK/card.md"
  [ -f "$CARD" ] || refuse "$CARD missing — pair runs start once the task card exists"
  [ "$(pair_mode)" = codex ] ||
    refuse "pair is off for this task — .claude/done-lanes has no '@pair codex' and the card header does not say 'pair: codex'"
  if [ "$(card_pair)" = off ] && project_pair; then
    echo "task-pair: the card says 'pair: off' but .claude/done-lanes sets '@pair codex' — a card can only raise pair; the judge runs" >&2
  fi
  PAIR_DIR="$TASK/pair"; RUNLOG="$PAIR_DIR/runlog"; JUDGE_FILE="$PAIR_DIR/judge"
  mkdir -p "$PAIR_DIR"
  # herdr agent names: [a-z][a-z0-9_-]{0,31}, unique per server.
  NAME="$(printf 'judge-%s' "$SLUG" | tr -c 'a-z0-9_\n-' '-' | cut -c1-32)"
  # Judge scratch is keyed by repo path and slug: two clones never share it (R17).
  SAFE_SLUG="$(printf '%s' "$SLUG" | tr -c 'a-z0-9_.-' '-')"
  REPO_ID="$(printf '%s' "$ROOT" | hash_stdin | awk '{print substr($1, 1, 8)}')"
}

# Pair is on when the project's `@pair codex` (bound by evidence.sh trust:
# changing any `@` line needs a re-trust, R7) or the card header says
# codex. A card can raise pair for one task, never lower it.
project_pair() { grep -Eq '^@pair[[:space:]]+codex([[:space:]]|$)' .claude/done-lanes 2>/dev/null; }
card_pair() { sed -nE 's/^<!-- card v4 .*pair:[[:space:]]*([a-z]+).*/\1/p' "$CARD" | head -n 1; }
pair_mode() { if project_pair || [ "$(card_pair)" = codex ]; then echo codex; else echo off; fi; }

# The card digest is scripts/evidence.sh card_norm, byte for byte (02 review
# #1/#11; L1-44 holds the two to it): only a slice line loses its status mark
# and a trailing run of ✓ <name>@<8 hex> tokens, and only the LAST line is
# dropped, only when it is a whole Closed: line in close's format.
TOK='([a-z][a-z0-9-]*@[0-9a-f]{8}|codex@waived)'
CLOSED_RE="^Closed: tree:[0-9a-f]{12} head:[0-9a-f]{12} ✓( $TOK)+ — [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\$"
card_norm() { sed -E -e "/^- \[[ ~ox]\] S[0-9]+ /{s/^- \[[ ~ox]\] /- [ ] /;s/ ✓( $TOK)+\$//;}" -e "\${/$CLOSED_RE/d;}" "$1"; }
card_digest() { local s; s="$(export LC_ALL=C; card_norm "$CARD" | hash_stdin)"; echo "card:${s:0:64}"; }

require_herdr() {
  [ "${HERDR_ENV:-}" = 1 ] || refuse "not inside a herdr-managed pane (HERDR_ENV != 1)"
  command -v herdr >/dev/null 2>&1 || refuse "herdr binary not on PATH"
}

# The project's own Codex hooks would run a second Stop gate / spawn-log
# inside the judge (verified 2026-09-15: Codex hooks are Claude-compatible).
# The judge is always started with hooks off; a judge we did not start
# cannot prove that, so the tripwire is on the state file we wrote.
hooks_tripwire() {
  [ -f "$ROOT/.codex/hooks.json" ] || return 0
  grep -qx 'hooks_off=1' "$JUDGE_FILE" 2>/dev/null && return 0
  refuse ".codex/hooks.json exists and the judge on record was not started with features.hooks=false — remove $JUDGE_FILE and re-run ensure"
}

# Codex shows a trust dialog for an untrusted directory and herdr reports it
# as idle, not blocked. Refuse early instead of typing into the dialog.
trust_check() {
  local cfg="$CODEX_HOME_DIR/config.toml"
  [ -f "$cfg" ] || refuse "Codex config not found at $cfg — trust this repo in Codex first"
  awk -v want="[projects.\"$ROOT\"]" '
    $0 == want { in_sec = 1; next }
    /^\[/ { in_sec = 0 }
    in_sec && /^[[:space:]]*trust_level[[:space:]]*=[[:space:]]*"trusted"/ { found = 1 }
    END { exit found ? 0 : 1 }' "$cfg" \
    || refuse "$ROOT is not trusted in $cfg — open Codex here once and accept the trust prompt"
}

# --- X1: the judge reads CLAUDE.md, all of it -------------------------------------
# Codex reads AGENTS.md whenever it exists and then skips the CLAUDE.md
# fallback, and cuts the project doc at project_doc_max_bytes (32 KiB by
# default). Checked on every ensure, a running judge included (R18).
DOC_MAX=32768
doc_check() {
  [ -f CLAUDE.md ] || refuse "CLAUDE.md missing — the judge reads it as its project doc"
  if { [ -e AGENTS.md ] || [ -L AGENTS.md ]; } && ! cmp -s AGENTS.md CLAUDE.md; then
    refuse "AGENTS.md differs from CLAUDE.md — Codex reads AGENTS.md and skips the CLAUDE.md fallback; delete AGENTS.md or make it a copy or symlink of CLAUDE.md"
  fi
  DOC_MAX=$(( ($(wc -c < CLAUDE.md) / 4096 + 1) * 4096 ))
  [ "$DOC_MAX" -ge 32768 ] || DOC_MAX=32768
}
# A running judge keeps the cap it started with; one started before CLAUDE.md
# grew, or by someone else (no record), would read a cut project doc.
judge_record_check() {
  local have pane
  have="$(sed -n 's/^doc_max_bytes=//p' "$JUDGE_FILE" 2>/dev/null | head -n 1 || true)"
  pane="$(sed -n 's/^pane_id=//p' "$JUDGE_FILE" 2>/dev/null | head -n 1 || true)"
  if [[ "$have" =~ ^[0-9]+$ ]] && [ "$have" -ge "$DOC_MAX" ]; then return 0; fi
  refuse "judge '$NAME' was not started for the current CLAUDE.md (doc_max_bytes=${have:-none}, need $DOC_MAX) — close pane ${pane:-?} and run ensure again"
}

# --- Screen inspection -----------------------------------------------------
screen() { tilde "$(herdr agent read "$NAME" --source visible --lines "${1:-40}" 2>/dev/null || true)"; echo; }

# The label of the modal dialog on a screen ($1), or nothing. herdr reports
# `idle` under all of them; whatever is typed next lands in the dialog.
# Texts recorded on Codex 0.165.0 (2026-10-28) — the trust dialog's 0.154
# wording is kept. A numbered menu (`› 1.`) or any "enter … continue /
# confirm / select" footer is a dialog even when its text is new.
NEW_PICKER='Where should the new conversation run?'
modal_label() {
  if grep -qE 'Trust this folder\?|Do you trust the contents of this directory' <<<"$1"; then echo trust
  elif grep -q 'Update available' <<<"$1" && grep -q 'esc skip' <<<"$1"; then echo update
  elif grep -qiE 'switch to gpt-|approaching rate limits' <<<"$1"; then echo rate-limit
  elif grep -qF "$NEW_PICKER" <<<"$1"; then echo new-thread-picker
  elif grep -qE '[Ee]nter (to )?(continue|confirm|select)|^[[:space:]]*› [0-9]+\. ' <<<"$1"; then echo unknown-dialog
  else return 1
  fi
}
modal_on_screen() { modal_label "$(screen 40)"; }

# esc is sent only where the dialog itself says esc is the harmless answer:
# the rate-limit nudge (esc keeps the current model) and the update notice
# ("esc skip" — enter would run Codex's installer). The trust dialog's esc
# quits Codex; it and every other dialog are the human's. Never enter here.
dismiss_soft() { # $1 label -> the label still on screen afterwards, or nothing
  case "$1" in
    rate-limit|update)
      herdr agent send-keys "$NAME" esc >/dev/null 2>&1 || true
      sleep 1
      modal_on_screen || true ;;
    *) echo "$1" ;;
  esac
}
hand_over() { # $1 what the human must do -> exit 4 with the screen saved
  echo "task-pair: $1:" >&2
  screen 12 | sed 's/^/    /' >&2
  dump_screen "dialog-$(date -u +%Y%m%dT%H%M%SZ).screen.txt"
  RC=4 die "human input required"
}
clear_modals() {
  local m
  m="$(modal_on_screen || true)"
  [ -z "$m" ] || m="$(dismiss_soft "$m")"
  [ -z "$m" ] || hand_over "judge shows a '$m' dialog — answer it in the pane, then retry"
}
# Ready for a prompt: herdr says idle, no dialog, and the last `›` line on
# screen is the composer, not a menu entry.
composer_ready() { # $1 screen
  local last
  case "$(judge_status)" in idle|done) ;; *) return 1 ;; esac
  ! modal_label "$1" >/dev/null || return 1
  last="$(grep -E '^[[:space:]]*› ' <<<"$1" | tail -n 1 || true)"
  [ -n "$last" ] && ! grep -qE '^[[:space:]]*› [0-9]+\. ' <<<"$last"
}

# Model + effort from the Codex status line ("GPT-5.6-Sol high · <cwd> ·
# … · <n> in · <n> out · …"; a narrow pane cuts it after the cwd).
# Observed, never assumed: Codex can switch its own model under rate
# pressure, so every runlog row re-reads it. '?' when the line is not there.
judge_model() {
  local m
  m="$(screen 40 | sed -nE 's/^[[:space:]]*([A-Za-z0-9._-]+( [a-z]+)?) · [/~].*/\1/p' | tail -n 1)"
  echo "${m:-?}"
}
# Token counters from the same line ("12.3k/4.1k"); the difference between
# two runlog rows is what one run cost. '-' when the pane cut them off.
judge_tokens() {
  local t
  t="$(screen 40 | sed -n 's/.*· \([0-9.]*[kKmM]\{0,1\}\) in · \([0-9.]*[kKmM]\{0,1\}\) out.*/\1\/\2/p' | tail -n 1)"
  echo "${t:--}"
}
# The judge's own transcript: the newest Codex rollout whose session_meta
# names this repo as cwd and started after the judge did (a `/new` reset
# opens a new one). Links a result's self-reported evidence to what the
# judge actually ran. '?' when none is found.
judge_rollout() {
  local started best="" best_ts="" f head ts root2
  started="$(sed -n 's/^started=//p' "$JUDGE_FILE" 2>/dev/null | head -1)"
  [ -n "$started" ] || { echo '?'; return; }
  root2="$(cd "$ROOT" && pwd -P)"
  for f in "$CODEX_HOME_DIR"/sessions/*/*/*/rollout-*.jsonl; do
    [ -f "$f" ] || continue
    head="$(head -c 8192 "$f" 2>/dev/null)"
    printf '%s' "$head" | grep -qF -e "\"cwd\":\"$ROOT\"" -e "\"cwd\":\"$root2\"" || continue
    ts="$(printf '%s' "$head" | sed -n 's/^{"timestamp":"\([^"]*\)".*/\1/p' | head -1)"
    [ -n "$ts" ] || continue
    [ "$ts" \> "$started" ] || continue
    if [ -z "$best_ts" ] || [ "$ts" \> "$best_ts" ]; then best="$f"; best_ts="$ts"; fi
  done
  echo "${best:-?}"
}

judge_status() { herdr agent get "$NAME" 2>/dev/null | jstr agent_status || true; }

# --- runlog: append-only, tab-separated, UTC ----------------------------------
# ts  seq  event  stage  unit  base  digest  model  tokens  rollout  detail
# (stage and unit are columns 4-5, as in v3, so readers keep their column
# numbers). model/tokens/rollout are observed at write time — a run's cost
# is the token delta between its start and end rows; rollout is the judge's
# own transcript for that run.
log_row() { # seq event stage unit base digest detail
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$1" "$2" "$3" "$4" "$5" "$6" "$(judge_model)" "$(judge_tokens)" "$(tilde "$(judge_rollout)")" "$7" >> "$RUNLOG"
}
# Evidence for a run that did not settle cleanly: the judge's screen as it
# was, saved next to the packet (a stderr excerpt is not retrievable later).
dump_screen() { # $1 = file name under PAIR_DIR
  screen 80 > "$PAIR_DIR/$1" 2>/dev/null || true
}

# --- ensure ---------------------------------------------------------------
split_direction() {
  local lay w h
  lay="$(herdr pane layout --current 2>/dev/null || true)"
  w="$(printf '%s' "$lay" | sed -n 's/.*"focused":true,"pane_id":"[^"]*","rect":{"height":\([0-9]*\),"width":\([0-9]*\).*/\2/p' | head -1)"
  h="$(printf '%s' "$lay" | sed -n 's/.*"focused":true,"pane_id":"[^"]*","rect":{"height":\([0-9]*\),"width":\([0-9]*\).*/\1/p' | head -1)"
  if [ -n "$w" ] && [ -n "$h" ] && [ "$w" -lt $((h * 2)) ]; then echo down; else echo right; fi
}

ensure() {
  resolve_task; doc_check; require_herdr; trust_check
  local st pane_id resp
  st="$(judge_status)"
  if [ -n "$st" ]; then
    hooks_tripwire; judge_record_check
    echo "task-pair: judge '$NAME' present ($st) — $(judge_model)"
    clear_modals
    return 0
  fi
  resp="$(herdr pane split --current --direction "$(split_direction)" --cwd "$ROOT" --no-focus 2>&1)" \
    || refuse "pane split failed: $resp"
  pane_id="$(printf '%s' "$resp" | jstr pane_id)"
  [ -n "$pane_id" ] || refuse "pane split returned no pane_id: $resp"
  # No model/effort args: the judge runs the user's current Codex default.
  # hooks off (second gate), workspace-write (read-only cannot even mktemp),
  # CLAUDE.md as the project doc (X1: AGENTS.md absent or identical), its
  # cap sized to CLAUDE.md. `started` is taken BEFORE the start so the
  # judge's rollout (created at startup) sorts after it.
  local started; started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  resp="$(herdr agent start "$NAME" --kind codex --pane "$pane_id" --timeout "$START_TIMEOUT_MS" -- \
            -s workspace-write -c features.hooks=false \
            -c 'project_doc_fallback_filenames=["CLAUDE.md"]' -c "project_doc_max_bytes=$DOC_MAX" 2>&1)" || true
  case "$(printf '%s' "$resp" | jstr type)" in
    agent_started) ;;
    *) printf '%s' "$resp" | grep -q agent_not_ready || refuse "agent start failed: $resp" ;;
  esac
  # Recorded before any dialog is looked at: this script started it, so a
  # judge the human then answers (trust, …) is ours on the next ensure.
  {
    echo "name=$NAME"; echo "pane_id=$pane_id"; echo "hooks_off=1"
    echo "doc_max_bytes=$DOC_MAX"; echo "started=$started"
  } > "$JUDGE_FILE"
  sleep 1
  clear_modals   # an update notice at startup is skipped (esc); anything else exits 4
  case "$(judge_status)" in
    idle|done) ;;
    *) hand_over "judge '$NAME' in pane $pane_id is not ready — answer it there, then run ensure again" ;;
  esac
  echo "task-pair: judge '$NAME' started in $pane_id — $(judge_model) (project doc CLAUDE.md, cap $DOC_MAX B)"
}

# --- packet fields, the result contract ------------------------------------
pk_field() { sed -n "s/^$1:[[:space:]]*//p" "$2" | head -1; }

# The result's first six lines hold run verdict base blocker major minor, each
# exactly once, in any order (CRLF is fine). Anything else there is
# bad_header:<first key at fault>; another base is base_mismatch. These are
# the lines evidence.sh codex reads (pair.md §Result contract).
RKEYS="run verdict base blocker major minor"
rfield() { head -n 6 "$2" 2>/dev/null | tr -d '\r' | sed -n "s/^$1: //p" | head -n 1; }
check_result() { # $1 result, $2 packet base -> the reason, or nothing
  local k v
  [ -s "$1" ] || { echo no_result; return; }
  for k in $RKEYS; do
    [ "$(head -n 6 "$1" | tr -d '\r' | grep -c "^$k: ")" = 1 ] || { echo "bad_header:$k"; return; }
  done
  for k in $RKEYS; do
    v="$(rfield "$k" "$1")"
    case "$k:$v" in
      run:completed|run:failed|run:blocked|verdict:pass|verdict:fail|verdict:inconclusive) ;;
      base:*) [ "$v" = "$2" ] || { echo base_mismatch; return; } ;;
      blocker:*|major:*|minor:*) [[ "$v" =~ ^[0-9]+$ ]] || { echo "bad_header:$k"; return; } ;;
      *) echo "bad_header:$k"; return ;;
    esac
  done
}

# Collect after herdr reports a settled state; the first reason found wins.
STATE=""; REASON=""
collect() { # $1 seq, $2 result, $3 base, $4 fp_before, $5 herdr status -> STATE REASON
  local r
  case "$5" in
    blocked) STATE=blocked; REASON=herdr_blocked; return ;;
    idle|done) ;;
    *) STATE=failed; REASON="herdr_$5"; return ;;
  esac
  r="$(check_result "$2" "$3")"
  if [ -n "$r" ]; then STATE=failed; REASON="$r"; return; fi
  # Anything new in pair/ besides the result — gitignored files too, which
  # the fingerprint cannot see — is judge scratch in the mailbox.
  r="$(find "$PAIR_DIR" -mindepth 1 -newer "$PAIR_DIR/.fp-$1" ! -name runlog ! -name judge ! -name '.fp-*' ! -path "$2" 2>/dev/null || true)"
  if [ -n "$r" ]; then
    STATE=failed; REASON=scratch_in_mailbox
    echo "task-pair: the judge wrote into the mailbox (its scratch is $SCRATCH):" >&2
    sed -n '1,5s/^/    /p' <<<"$r" >&2
    return
  fi
  if [ "$(fingerprint || echo nogit)" != "$4" ]; then STATE=failed; REASON=tree_changed; return; fi
  # The judge's own word that it could not check is no result either.
  r="$(rfield run "$2")"
  if [ "$r" != completed ]; then STATE=failed; REASON="judge_run_$r"; return; fi
  STATE=completed
  REASON="verdict=$(rfield verdict "$2") blocker=$(rfield blocker "$2") major=$(rfield major "$2") minor=$(rfield minor "$2")"
}

# Every settled run, failed or not, becomes a record through evidence.sh
# codex (its stderr — e.g. `codex no verdict twice` — passes through). An
# unrecorded run counts for nothing, so a failed write is a failure (6).
finish() { # seq stage unit base digest packet result -> 0 completed · 4 blocked · 6 otherwise
  local m t0 rec rc=0
  log_row "$1" "end:$STATE" "$2" "$3" "$4" "$5" "$REASON"
  [ "$STATE" = completed ] || dump_screen "$1-$2.screen.txt"
  # Post-run dialog sweep: the rate-limit nudge and the update notice get esc
  # (dismiss_soft); anything else is reported, not answered — the run itself
  # is already settled, so this never changes STATE.
  m="$(modal_on_screen || true)"
  [ -z "$m" ] || m="$(dismiss_soft "$m")"
  [ -z "$m" ] || echo "task-pair: WARNING judge shows a '$m' dialog — answer it in the pane before the next send" >&2
  t0="$(sed -n 2p "$PAIR_DIR/.fp-$1" 2>/dev/null || true)"
  [[ "$t0" =~ ^[0-9]+$ ]] || t0="$(date +%s)"
  rec="$(PAIR_MODEL="$(judge_model)" PAIR_ROLLOUT="$(judge_rollout)" PAIR_SECS="$(($(date +%s) - t0))" \
           bash "$ROOT/scripts/evidence.sh" codex "$6" "$7" "$STATE" "$REASON" | tail -n 1)" || rc=$?
  if [ "$rc" != 0 ]; then
    log_row "$1" record_failed "$2" "$3" "$4" "$5" "rc=$rc"
    echo "task-pair: evidence.sh codex failed (rc $rc) — this run is NOT recorded; the result file is kept: $7" >&2
    return 6
  fi
  rm -f "$PAIR_DIR/.fp-$1"
  if [ "$STATE" != completed ]; then echo "task-pair: scratch kept: $SCRATCH"
  else case "$SCRATCH" in /tmp/pair-*/*) rm -rf "$SCRATCH"; rmdir "${SCRATCH%/*}" 2>/dev/null || true ;; esac
  fi
  echo "task-pair: seq=$1 stage=$2 unit=$3 state=$STATE ($REASON) result=$7 record=$rec"
  case "$STATE" in
    completed) return 0 ;;
    blocked) return 4 ;;
    *) return 6 ;;
  esac
}

# --- pid lock: one run per task (D3) ---------------------------------------
# .claude/evidence/locks/pair-<seq>.lock = "<pid> TAB pair TAB <stage> TAB
# <unit> TAB <UTC ts>"; the Stop gate defers while it is alive. Alive is
# guard-patterns.sh's lock_alive — one rule for every lock (R5, ADR-004).
need_guard() {
  # shellcheck source=../.claude/hooks/guard-patterns.sh
  . .claude/hooks/guard-patterns.sh 2>/dev/null || true
  declare -F lock_alive >/dev/null || refuse ".claude/hooks/guard-patterns.sh is missing or predates v4 — re-sync the template"
}
take_lock() { # $1 seq, $2 stage, $3 unit
  local k p d=.claude/evidence/locks
  (umask 077; mkdir -p "$d")
  for k in "$d"/pair-*.lock; do
    [ -f "$k" ] || continue
    p="$(cut -f1 "$k" | head -n 1)"
    lock_alive "$p" && RC=5 die "seq $(lock_seq "$k") is in flight (pid $p) — wait for its notification"
    rm -f "$k"
    echo "task-pair: stale lock ${k##*/} (pid $p is gone) — removed" >&2
  done
  LOCK="$d/pair-$1.lock"
  if ! ( set -C; printf '%s\tpair\t%s\t%s\t%s\n' $$ "$2" "$3" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$LOCK" ) 2>/dev/null; then
    LOCK=""; RC=5 die "seq $1 is in flight — wait for its notification"
  fi
  trap release_lock EXIT
  trap 'exit 5' TERM INT HUP
  for k in "$d"/pair-*.lock; do   # two sends that started together: both back off
    [ "$k" != "$LOCK" ] && [ -f "$k" ] && lock_alive "$(cut -f1 "$k" | head -n 1)" || continue
    release_lock; RC=5 die "seq $(lock_seq "$k") started at the same time — wait for its notification"
  done
}
lock_seq() { local s="${1##*/pair-}"; echo "${s%.lock}"; }
# A file written into pair/ while a run is in flight voids that run (the
# fingerprint and the mailbox check both see it), so packet refuses first.
no_run_in_flight() {
  local k p
  need_guard
  for k in .claude/evidence/locks/pair-*.lock; do
    [ -f "$k" ] || continue
    p="$(cut -f1 "$k" | head -n 1)"
    if lock_alive "$p"; then RC=5 die "seq $(lock_seq "$k") is in flight (pid $p) — wait for its notification; a packet written now would void it"; fi
  done
  for k in "$PAIR_DIR"/.fp-*; do
    if [ -f "$k" ]; then RC=5 die "seq ${k##*.fp-} has not settled — run in the background: task-pair.sh wait ${k##*.fp-}"; fi
  done
}
release_lock() {   # only our own: a refused send never removes another run's lock
  if [ -n "$LOCK" ] && [ "$(cut -f1 "$LOCK" 2>/dev/null)" = "$$" ]; then rm -f "$LOCK"; fi
  LOCK=""
}

# --- quota (pair.md §Quota, U1) ---------------------------------------------
# What the human consented to: starting a pair /task covers the card check
# and one retry (card 2); approving the card covers one run per `codex: yes`
# slice and the final, a retry each, and the rebuttal (slice 2, final 3).
# Used = this unit's `start` rows in the runlog (refused runs and re-attached
# waits are not runs). --over-estimate (bash-guard asks the human) passes.
slice_line() { grep -E "^- \[[ ~ox]\] $1( |\$)" "$CARD" || true; }
codex_yes() { case "${1%% ✓ *}" in *' ; codex: yes'|*' ; codex: yes ; '*) return 0 ;; esac; return 1; }
starts() { # $1 stage, $2 unit ('' = any) -> the count of runlog start rows
  [ -f "$RUNLOG" ] || { echo 0; return; }   # a run whose packet never reached the model (not_started) is no run
  awk -F'\t' -v s="$1" -v u="$2" 'NR == FNR {if ($3 == "end:failed" && $11 == "not_started") ns[$2] = 1; next}
    $3 == "start" && !($2 in ns) && (u == "" || ($4 == s && $5 == u)) {n++} END {print n + 0}' "$RUNLOG" "$RUNLOG"
}
quota() { # $1 stage, $2 unit, $3 1 = --over-estimate, $4 quiet -> OVER=1 when the flag was needed
  local cap=3 used m a d ln
  case "$1" in
    card) cap=2 ;;
    slice) ln="$(slice_line "$2" | head -n 1)"; [ -n "$ln" ] || return 0
           cap=0; if codex_yes "$ln"; then cap=2; fi ;;
  esac
  used="$(starts "$1" "$2")"; OVER=""
  if [ "$1" != card ]; then
    d="$(card_digest)"; d="${d:5:12}"
    a="$(awk -F'\t' '$2 == "APPROVE" {a = $5} END {print a}' "$TASK/donelog" 2>/dev/null || true)"
    if [ "$a" != "$d" ]; then
      [ "$3" = 1 ] || refuse "the card is not approved at card:$d — Codex runs past the card check are covered by the human's approval (evidence.sh approve)"
      OVER=1
    fi
  fi
  if [ "$used" -ge "$cap" ]; then
    [ "$3" = 1 ] || [ "$cap" != 0 ] ||
      refuse "$2 is not tagged codex: yes — a Codex run on it is outside the card's consent; ask the human (--over-estimate), or tag it and re-approve"
    [ "$3" = 1 ] ||
      refuse "codex run $((used + 1)) for $2 is beyond the consented estimate ($cap for $2; pair.md §Quota) — ask the human; on their yes run again with --over-estimate"
    OVER=1
  fi
  [ -z "$4" ] || return 0
  [ -z "$OVER" ] || echo "task-pair: run outside the consented estimate (--over-estimate)" >&2
  m="$(grep -cE '^- \[[ ~ox]\] S[0-9]+ .* ; codex: yes' "$CARD" || true)"
  echo "task-pair: codex run $(($(starts - '') + 1)) for this task ($2: $((used + 1)) of $cap); consented: card 2 + $m codex: yes slice(s) x 2 + final 3 = $((2 * m + 5))"
}

# --- send / wait --------------------------------------------------------------
send() {
  local packet="${1:-}" timeout="$DEFAULT_TIMEOUT_MS" over=0
  [ -n "$packet" ] || die "usage: task-pair.sh send <packet> [--timeout MS] [--over-estimate]"
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --timeout) [[ "${2:-}" =~ ^[0-9]+$ ]] || die "send: --timeout needs milliseconds"; timeout="$2"; shift 2 ;;
      --over-estimate) over=1; shift ;;
      *) die "send: unknown option $1" ;;
    esac
  done
  resolve_task
  packet="${packet#"$ROOT"/}"
  [ -f "$packet" ] || die "packet not found: $packet"
  case "$packet" in "$PAIR_DIR"/*) ;; *) die "packet must live under $PAIR_DIR" ;; esac
  local base_name seq stage unit base digest fp_before abs_packet abs_result st resp
  base_name="$(basename "$packet" .md)"
  seq="${base_name%%-*}"
  [[ "$seq" =~ ^[0-9]+$ ]] || die "packet name must start with a numeric seq: NNN-<stage>[-S<n>].md"
  stage="$(pk_field stage "$packet")"; unit="$(pk_field unit "$packet")"; base="$(pk_field base "$packet")"
  case "$stage" in card|slice|final) ;; *) stage="" ;; esac
  [ -n "$stage" ] && [ -n "$unit" ] && [ -n "$base" ] || die "packet needs 'stage: card|slice|final', 'unit:' and 'base:' lines"
  RESULT="${packet%.md}.result.md"
  [ ! -e "$RESULT" ] || die "result already exists: $RESULT (one packet, one run — run check again for a new packet)"
  # The base must be what the judge will actually see: HEAD, or the card now.
  if [[ "$base" =~ ^[0-9a-f]{7,40}$ ]]; then
    git -C "$ROOT" rev-parse HEAD 2>/dev/null | grep -q "^$base" \
      || RC=6 die "packet base $base is not HEAD — stale packet"
  elif [ "${base#card:}" != "$base" ] && [ "$base" != "$(card_digest)" ]; then
    RC=6 die "packet base $base is not the current card digest — stale packet"
  fi
  quota "$stage" "$unit" "$over" ""
  need_guard; take_lock "$seq" "$stage" "$unit"
  ensure >/dev/null
  st="$(judge_status)"
  case "$st" in
    idle|done) ;;
    blocked) clear_modals; RC=4 die "judge is blocked — inspect the pane" ;;
    *) RC=5 die "judge is '$st' — seq $(inflight_seq) is in flight: run 'task-pair.sh wait $(inflight_seq)' in the background" ;;
  esac
  # Every packet runs in a fresh thread (ADR-030): the judge's memory of
  # earlier stages is anchoring, not evidence — packets carry what it needs.
  fresh_thread "$seq"
  make_scratch "$seq"
  digest="$(hash_stdin < "$packet" | awk '{print $1}')"
  fp_before="$(fingerprint || echo nogit)"
  abs_packet="$ROOT/$packet"; abs_result="$ROOT/$RESULT"
  # The packet goes only into an idle composer: typed into a dialog, its
  # Enter answers the dialog and the text is lost.
  composer_ready "$(screen 40)" || hand_over "the judge is not at an empty prompt — the packet was not sent"
  log_row "$seq" start "$stage" "$unit" "$base" "$digest" "timeout=${timeout}ms${OVER:+ over-estimate}"
  printf '%s\n%s\n' "$fp_before" "$(date +%s)" > "$PAIR_DIR/.fp-$seq"
  resp="$(herdr agent prompt "$NAME" \
    "Read and execute the packet at $abs_packet. It is frozen; do not edit it. Keep every temporary file under $SCRATCH. When finished, write your result to $abs_result in the format the packet specifies, then reply with only that path." \
    --wait --timeout "$timeout" 2>&1)" || true
  settle "$seq" "$stage" "$unit" "$base" "$digest" "$packet" "$RESULT" "$resp"
}

inflight_seq() { local f s="?"; for f in "$PAIR_DIR"/.fp-*; do [ -f "$f" ] && s="${f##*.fp-}"; done; echo "$s"; }

# The judge's scratch lives outside the repo (/tmp: the sandbox writes it):
# kept when a run fails, removed when it completes.
make_scratch() { # $1 seq -> SCRATCH
  local d="/tmp/pair-$REPO_ID-$SAFE_SLUG"
  SCRATCH="$d/$1"
  if [ -e "$d" ] && [ ! -O "$d" ]; then refuse "$d exists and is not yours — remove it"; fi
  (umask 077; mkdir -p "$SCRATCH")
}

settle() { # seq stage unit base digest packet result herdr_response
  local resp="$8" code st fp_before
  fp_before="$(sed -n 1p "$PAIR_DIR/.fp-$1" 2>/dev/null || true)"
  code="$(printf '%s' "$resp" | jstr code)"
  case "$code" in
    timeout)
      log_row "$1" waiting "$2" "$3" "$4" "$5" "herdr timeout — run in the background: task-pair.sh wait $1"
      echo "task-pair: seq=$1 still running — run in the background: task-pair.sh wait $1"; exit 5 ;;
    agent_prompt_stalled) STATE=failed; REASON=stalled; finish "$1" "$2" "$3" "$4" "$5" "$6" "$7"; exit $? ;;
    agent_blocked) STATE=blocked; REASON=herdr_blocked; finish "$1" "$2" "$3" "$4" "$5" "$6" "$7"; exit $? ;;
    "") ;;
    *) STATE=failed; REASON="herdr_$code"; finish "$1" "$2" "$3" "$4" "$5" "$6" "$7"; exit $? ;;
  esac
  st="$(printf '%s' "$resp" | jstr agent_status)"
  [ -n "$st" ] || st="$(judge_status)"
  if [[ "${st:-}" =~ ^(idle|done)$ ]] && [ ! -s "$7" ] && ! turn_started "$1"; then
    # herdr can report idle at once while nothing ran (the prompt landed in
    # a dialog). Give a slow start a few seconds before calling it.
    for _ in $(seq 1 "$START_GRACE_S"); do
      sleep 1
      if [ "$(judge_status)" = working ]; then
        settle "${@:1:7}" "$(herdr agent wait "$NAME" --timeout "$DEFAULT_TIMEOUT_MS" 2>&1 || true)"
      fi
      turn_started "$1" && break
    done
    [ -s "$7" ] || turn_started "$1" || not_started "$@"
  fi
  collect "$1" "$7" "$4" "${fp_before:-nogit}" "${st:-unknown}"
  finish "$1" "$2" "$3" "$4" "$5" "$6" "$7"; exit $?
}

# Did the packet reach the model? Any of: the token counters moved since the
# start row, or a Codex transcript of this repo was written since the run
# began (Codex opens one at a thread's first turn). Both fail only when
# nothing ran — or the pane hides the counters and CODEX_HOME is elsewhere.
turn_started() { # $1 seq
  local t0 t1 f root2
  t0="$(awk -F'\t' -v s="$1" '$2 == s && $3 == "start" {t = $9} END {print t}' "$RUNLOG" 2>/dev/null || true)"
  t1="$(judge_tokens)"
  case "$t0|$t1" in '|'*|'-|'*|'?|'*|*'|-'|*'|?') ;; *) [ "$t0" = "$t1" ] || return 0 ;; esac
  [ -d "$CODEX_HOME_DIR/sessions" ] && [ -f "$PAIR_DIR/.fp-$1" ] || return 1
  root2="$(cd "$ROOT" && pwd -P)"
  while IFS= read -r f; do
    head -c 8192 "$f" 2>/dev/null | grep -qF -e "\"cwd\":\"$ROOT\"" -e "\"cwd\":\"$root2\"" && return 0
  done < <(find "$CODEX_HOME_DIR/sessions" -name 'rollout-*.jsonl' -newer "$PAIR_DIR/.fp-$1" 2>/dev/null)
  return 1
}
# A packet that never reached the model is not a Codex run: no record, no
# quota (starts() skips it), no step toward `codex no verdict twice`.
not_started() { # seq stage unit base digest packet result
  STATE=failed; REASON=not_started
  log_row "$1" end:failed "$2" "$3" "$4" "$5" not_started
  dump_screen "$1-$2.screen.txt"
  rm -f "$PAIR_DIR/.fp-$1"
  case "$SCRATCH" in /tmp/pair-*/*) rm -rf "$SCRATCH"; rmdir "${SCRATCH%/*}" 2>/dev/null || true ;; esac
  echo "task-pair: the packet never reached the model (no result, token counters unchanged, no Codex transcript) — not recorded, not counted against the quota; the screen is in $PAIR_DIR/$1-$2.screen.txt. Look at the judge pane, then run check again." >&2
  echo "task-pair: seq=$1 stage=$2 unit=$3 state=failed (not_started) result=$7 record=none"
  exit 6
}

wait_run() {
  local seq="${1:-}" timeout="$DEFAULT_TIMEOUT_MS"
  [ -n "$seq" ] || die "usage: task-pair.sh wait <seq> [--timeout MS]"
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --timeout) [[ "${2:-}" =~ ^[0-9]+$ ]] || die "wait: --timeout needs milliseconds"; timeout="$2"; shift 2 ;;
      *) die "wait: unknown option $1" ;;
    esac
  done
  resolve_task; require_herdr
  local packet f stage unit base digest resp
  packet=""
  for f in "$PAIR_DIR/$seq"-*.md; do
    case "$f" in *.result.md) ;; *) [ -f "$f" ] && { packet="$f"; break; } ;; esac
  done
  [ -n "$packet" ] || die "no packet with seq $seq under $PAIR_DIR"
  [ -f "$PAIR_DIR/.fp-$seq" ] || die "seq $seq has no run in flight"
  stage="$(pk_field stage "$packet")"; unit="$(pk_field unit "$packet")"; base="$(pk_field base "$packet")"
  digest="$(hash_stdin < "$packet" | awk '{print $1}')"
  RESULT="${packet%.md}.result.md"; SCRATCH="/tmp/pair-$REPO_ID-$SAFE_SLUG/$seq"
  need_guard; take_lock "$seq" "$stage" "$unit"
  resp="$(herdr agent wait "$NAME" --timeout "$timeout" 2>&1)" || true
  settle "$seq" "$stage" "$unit" "$base" "$digest" "$packet" "$RESULT" "$resp"
}

# --- packet: the judge's inputs, frozen by a script, not by memory ---------
# Everything that can fail (lint, evidence.sh show/status, git) runs before
# the file is written: a refused packet leaves nothing behind.
next_seq() {
  local n=0 f b
  for f in "$PAIR_DIR"/[0-9][0-9][0-9]-*.md; do
    [ -f "$f" ] || continue
    b="$(basename "$f")"; b=$((10#${b%%-*}))
    [ "$b" -gt "$n" ] && n="$b"
  done
  printf '%03d' $((n + 1))
}

md_section() { # $1 file, $2 heading ("## Limits") -> that section, up to the next "## " heading
  awk -v h="$2" 'index($0, h) == 1 {f = 1; print; next} f && /^## / {exit} f {print}' "$1" 2>/dev/null || true
}
indent() { sed 's/^/    /'; }
notes_cited() { # the topics the card's slice lines cite (notes: §a, §b), once each
  local ln
  grep -E '^- \[[ ~ox]\] S[0-9]+ .* ; notes: ' "$CARD" | while IFS= read -r ln; do
    ln="${ln%% ✓*}"; printf '%s\n' "${ln#* ; notes: }" | tr ',' '\n'
  done | sed -e 's/^[[:space:]]*//' -e 's/^§//' -e 's/[[:space:]]*$//' | awk 'NF && !s[$0]++'
}
lane_paths() { # $1 = lanes a,b -> their paths as declared in .claude/done-lanes
  local l
  for l in $(printf '%s' "$1" | tr ',' ' '); do
    awk -F' [|] ' -v l="$l" '$1 == l {print $2; exit}' .claude/done-lanes 2>/dev/null || true
  done
}

packet() {
  local stage="${1:-}" unit="" since="" rebuttal="" base head ln="" lanes="" x l f seq file scratch
  local body="" usage="usage: task-pair.sh packet card | packet slice S<n> [--since REF] | packet final [--since REF] [--rebuttal FILE]"
  [ $# -gt 0 ] || die "$usage"
  shift
  case "$stage" in
    card) unit=card; [ $# = 0 ] || die "packet card takes no options" ;;
    slice) unit="${1:-}"; [[ "$unit" =~ ^S[0-9]+$ ]] || die "$usage"; shift ;;
    final) unit=final ;;
    *) die "packet: unknown stage '$stage' (card | slice | final)" ;;
  esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --since) [ $# -ge 2 ] || die "$usage"; since="$2"; shift 2 ;;
      --rebuttal) { [ "$stage" = final ] && [ $# -ge 2 ]; } || die "$usage"; rebuttal="$2"; shift 2 ;;
      *) die "packet: unknown option $1" ;;
    esac
  done
  resolve_task; no_run_in_flight
  head="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)" || die "packet: not a git repo with a HEAD"
  case "$stage" in
    card)
      if ! x="$(bash scripts/evidence.sh lint 2>&1)"; then
        echo "task-pair: card lint fails — fix the card first:" >&2; printf '%s\n' "$x" | indent >&2; exit 3
      fi
      base="$(card_digest)" ;;
    slice)
      ln="$(slice_line "$unit")"
      { [ -n "$ln" ] && [ "$(printf '%s\n' "$ln" | grep -c .)" = 1 ]; } || die "slice $unit not found on the card"
      lanes="$(printf '%s' "${ln%% ✓ *}" | sed -nE 's/.* lanes: ([^;]*).*/\1/p' | tr -d ' ')"
      [ -n "$lanes" ] || die "slice $unit names no lane"
      # since = the HEAD `evidence.sh start` recorded (its open START row): the
      # only since evidence.sh codex binds a slice review to (02 review #5).
      x="$(awk -F'\t' -v s="$unit" '$3 == s && $2 == "START" {r = $5} $3 == s && $2 == "DONE" {r = ""} END {print r}' "$TASK/donelog" 2>/dev/null || true)"
      [[ "$x" =~ ^[0-9a-f]{7,40}$ ]] || refuse "$unit has no open START row in the donelog — run evidence.sh start $unit first"
      x="$(git rev-parse -q --verify "$x^{commit}" || true)"
      since="$(since_ok "$since" "$x" "$unit's START head")"
      # shellcheck disable=SC2046  # lane paths split on purpose
      x="$(git status --porcelain -- $(lane_paths "$lanes") ':(exclude).ai_context' 2>&1 || true)"
      [ -z "$x" ] || refuse "$unit's lane paths have uncommitted changes — commit the slice first (the judge reviews $since..HEAD; evidence.sh codex binds nothing else):"$'\n'"$(printf '%s\n' "$x" | head -n 5 | indent)"
      for l in $(printf '%s' "$lanes" | tr ',' ' '); do
        x="$(bash scripts/evidence.sh show "$l" 2>/dev/null)" || refuse "lane $l has no evidence record yet — run it first (evidence.sh run $l)"
        body="$body"$'\n'"## Lane $l: evidence record and log tail (scripts/evidence.sh show $l, verbatim)"$'\n'"$(printf '%s\n' "$x" | indent)"$'\n'
      done
      base="$head" ;;
    final)
      x="$(sed -nE 's/^<!-- card v4 .* base: ([0-9a-f]+) .*/\1/p' "$CARD" | head -n 1)"
      [ -n "$x" ] || refuse "the card header has no base: — fix the card (evidence.sh lint)"
      x="$(git rev-parse -q --verify "$x^{commit}" || true)"
      since="$(since_ok "$since" "$x" "the card's base:")"
      x="$(git status --porcelain -- . ':(exclude).ai_context' 2>&1 || true)"
      [ -z "$x" ] || refuse "the final check judges committed work — commit first (changes outside .ai_context/):"$'\n'"$(printf '%s\n' "$x" | head -n 5 | indent)"
      if [ -n "$rebuttal" ]; then
        [ -f "$rebuttal" ] || die "packet: rebuttal file not found: $rebuttal"
        for f in "$PAIR_DIR"/*-final-rebuttal.md; do
          if [ -f "$f" ] && [ "$(pk_field base "$f")" = "$head" ]; then
            refuse "one rebuttal round per base — what is still open goes to the human"
          fi
        done
      fi
      body="$(bash scripts/evidence.sh status 2>&1 || true)"
      base="$head" ;;
  esac
  seq="$(next_seq)"
  case "$stage" in
    card) file="$PAIR_DIR/$seq-card.md" ;;
    slice) file="$PAIR_DIR/$seq-slice-$unit.md" ;;
    *) file="$PAIR_DIR/$seq-final${rebuttal:+-rebuttal}.md" ;;
  esac
  scratch="/tmp/pair-$REPO_ID-$SAFE_SLUG/$seq"   # = send's SCRATCH for this seq
  x="$(pk_head; "pk_$stage"; [ -z "$rebuttal" ] || pk_rebuttal; pk_contract)"
  tilde "$x"$'\n' > "$file"
  echo "$file"
}

since_ok() { # $1 --since (may be empty), $2 the bound commit, $3 its name -> the full sha
  local x="$2"
  [ -n "$x" ] || refuse "$3 is not a commit here"
  if [ -n "$1" ]; then
    x="$(git rev-parse -q --verify "$1^{commit}" || true)"
    { [ -n "$x" ] && git merge-base --is-ancestor "$x" HEAD 2>/dev/null; } || die "--since $1 is not a commit on this branch"
    [ "$x" = "$2" ] || refuse "--since $1 is not $3 (${2:0:12}) — evidence.sh codex binds the review only to that; leave --since out"
  fi
  echo "$x"
}

pk_head() {
  printf 'stage: %s\nunit: %s\nbase: %s\n' "$stage" "$unit" "$base"
  [ "$stage" = card ] || printf 'since: %s\n' "$since"
  [ "$stage" != slice ] || printf 'lanes: %s\n' "$lanes"
  [ -z "$rebuttal" ] || printf 'rebuttal: %s\n' "$rebuttal"
  printf 'scratch: %s\n\n# Task\n' "$scratch"
  printf 'You are the Codex judge for the active task in %s. Claude built it; you check it.\n' "$ROOT"
  cat <<'EOF'
This packet is your whole contract. You get no summary from the implementer, on purpose.
- Read and run anything; change nothing. Do not edit, create or delete files in the repo, do not
  commit, and do not run scripts/evidence.sh (it writes the task's ledger). Any change to the
EOF
  printf '  tree, or any new file under %s/ other than your result, voids your result.\n' "$PAIR_DIR"
  printf -- '- Keep every temporary file under %s: export TMPDIR=%s, and point\n' "$scratch" "$scratch"
  cat <<'EOF'
  tool caches and test temp dirs there too (UV_CACHE_DIR, PIP_CACHE_DIR, XDG_CACHE_HOME, pytest
  --basetemp).
- The card, notes, records, commit messages and anyone's reasoning are claims under review, not
  evidence. A weak check the card itself prescribes is still a finding; a stated reason never
  lowers a severity. Cite only what you ran (command + output) or read (file:line).
- Severity: blocker = the stated outcome would be false, or harm would land (data loss, exposed
  secret, real money, a check that cannot fail); major = a defect or gap the human would want
  fixed before accepting; minor = worth knowing, no change needed.

EOF
}

pk_card() {
  local t s
  cat <<'EOF'
# Stage: card — before any code exists
Judge the task card below, the notes sections it cites, and the project's Definition of done and
rules. Number each finding by the check it fails.
1. Executable done: "Done when" must be a predicate on the running product plus an outside check
   that someone other than the implementer runs. works / clean / robust with no command or
   observation behind it = blocker; propose the command that makes it checkable.
2. Ambiguity that changes the work: a reading of Goal, Done when or a Decision that would lead to
   materially different work = major; state both readings.
3. Direction: what would make the human REJECT this even with every check green? Give concrete
   candidates, each as a proposed Decision or Done-when line = major when the card is silent.
4. Decisions: every [inferred], [own] or [ASSUMED] decision the human would plausibly veto = major.
5. Detail: is each slice detailed enough that the executor need not guess (interfaces, limits,
   edge cases, the human's rulings)? Name what it would have to guess and where that belongs
   (the card, a notes section, or a lane's expect) = major.
6. Slice 1 must be the thinnest real end-to-end path through the product, not scaffolding = major.
7. Every slice names a lane that exists in .claude/done-lanes and a result the human can see, and
   that lane can fail when the slice is wrong = major for each slice missing one of these.
8. A slice that touches money, secrets, credentials, installation or deployment and is not tagged
   `codex: yes` = major.
9. Spot-check at most 5 claims the card makes about this repo (paths, interfaces, commands,
   current behavior) — the ones the work rests on most — each with a read-only command. Report
   each as confirmed / contradicted / unverifiable with the command and its output. A
   contradicted load-bearing claim = blocker; an unverifiable one = minor.
verdict pass = no blocker and no major.

EOF
  printf '## Card (frozen; digest %s)\n' "$base"; indent < "$CARD"
  printf '\n## Notes sections the card cites\n'
  t="$(notes_cited)"
  [ -n "$t" ] || echo "    (none cited)"
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    x="$(md_section "$TASK/notes.md" "## $s")"
    if [ -n "$x" ]; then printf '### §%s\n' "$s"; printf '%s\n' "$x" | indent
    else printf '    §%s: NOT FOUND in notes.md\n' "$s"; fi
  done <<<"$t"
  for s in 'Definition of done' 'Project rules'; do
    printf '\n## CLAUDE.md — %s\n' "$s"
    x="$(md_section CLAUDE.md "## $s")"
    if [ -n "$x" ]; then printf '%s\n' "$x" | indent; else printf "    (CLAUDE.md has no '## %s' section)\n" "$s"; fi
  done
  echo
}

pk_slice() {
  printf '# Stage: slice %s — one finished slice, before it is marked done\n' "$unit"
  printf "Below: the slice line from the card, the diff since %s, and each lane's\n" "$since"
  cat <<'EOF'
evidence record and log tail. Judge the code and the runs, not a story.
1. Re-run each lane yourself: its command is the last column (cmd) of its line in
   .claude/done-lanes; run it exactly as declared, from the repo root, with the scratch exports.
   If you cannot — it runs longer than 10 minutes, needs network, hardware or credentials your
   sandbox lacks, or would write tracked files — say which, rely on the record and log below, and
   run at least one narrower real execution of the changed behavior. A failure your sandbox
   causes (EPERM on a socket, no network) makes that claim INCONCLUSIVE, not a product failure;
   quote the error.
2. Compare with the record: exit code, executed count > 0, every expect marker. An executed count
   of 0 proves nothing.
EOF
  printf '3. Read the full diff (git diff %s). Weakened or deleted tests, new skips, loosened\n' "$since"
  cat <<'EOF'
   tolerances, expected values computed by the code under test, and a new guard / retry / clamp /
   swallowed error that hides a bad state are findings. Changes the slice line does not cover =
   minor scope creep unless they break something.
4. Check of a check: where the diff adds or changes a check (test, gate, probe, judge, selftest,
   mock), build an input on which it passes while the real behavior fails, and run it — or say
   why none exists.
5. One line per claim the slice line and the records make:
   `VERIFIED|NOT VERIFIED|INCONCLUSIVE — level <1-5> — <claim> — <command + output, or file:line>`
   Levels: 1 stated, 2 file:line read, 3 failure path reasoned, 4 code run, 5 reproduced in the
   product. verdict pass = every claim VERIFIED at level 4 or 5 and no blocker or major; any NOT
   VERIFIED = fail; otherwise inconclusive.

## Slice line
EOF
  printf '%s\n' "$ln" | indent
  printf '\n## Diff since %s (stat; read the full diff yourself)\n' "$since"
  git diff --stat "$since" 2>/dev/null | indent || true
  x="$(git ls-files -o --exclude-standard -- . ':(exclude).claude/evidence' ":(exclude)$TASK/donelog" ":(exclude)$PAIR_DIR" 2>/dev/null | head -n 20 || true)"
  printf '    untracked: %s\n' "$(printf '%s' "${x:-none}" | tr '\n' ' ')"
  printf '%s\n' "$body"
}

pk_final() {
  cat <<'EOF'
# Stage: final — the whole task, before it closes
EOF
  printf 'HEAD (the base above) is under judgment; the task started at %s:\n' "$since"
  printf 'read git diff %s..HEAD and git log %s..HEAD. Below: the card, the diff\n' "$since" "$since"
  cat <<'EOF'
stat, the commits and the evidence status. Work through every item; a finding names its item.
List confirmed risks apart from checked-and-cleared ones.
Correctness
  C1. Re-run every lane the card names, by the slice rules: exact cmd, scratch exports, or say why
      not and run a narrower real execution.
  C2. Observe "Done when" and each [x] slice's visible result directly — run the product, don't
      read about it.
Regression
  R1. What else can this diff break? Run the suite or build; probe the neighbours of changed code.
  R2. Name the one fact that makes the diff safe and prove it by running code. Look where grep
      can't: serialized formats, schemas, config flags, other programs reading the same bytes,
      persisted state.
  R3. A second way to do what the code already does one way, or a new list someone must keep in
      sync by hand = finding.
Test integrity
  T1. Loosened assertions, skips, tolerances or deleted cases = fail unless a [human] Decision on
      the card allows them.
  T2. Each new or changed test must go red when the behavior breaks and stay green under a
      behavior-preserving change; one that fails either while it is a requirement's only proof =
      blocker.
EOF
  printf '  T3. git log -p %s..HEAD -- %s .claude/done-lanes: a lane command or\n' "$since" "$CARD"
  cat <<'EOF'
      expect narrowed, or a Done-when weakened, without a [human] Decision = blocker.
  T4. Every lane the status shows stale or missing is a gap: name what it leaves unproven = major.
verdict pass = no blocker and no major.

## Card
EOF
  indent < "$CARD"
  printf '\n## Diff stat %s..HEAD\n' "$since"
  git diff --stat "$since..HEAD" 2>/dev/null | indent || true
  printf '\n## Commits\n'
  git log --oneline -n 50 "$since..HEAD" 2>/dev/null | indent || true
  printf '\n## Evidence status (scripts/evidence.sh status, verbatim)\n'
  printf '%s\n' "$body" | indent
  echo
}

pk_rebuttal() {
  cat <<'EOF'
# Rebuttal round (one per base)
The findings below were raised on this same base — by the Claude checker, or as the
orchestrator's dispute of your previous result, each dispute with its command and output. For
EACH: reproduce it (command + output) or refute it (command + output). One you can neither
reproduce nor refute stays open at its original severity. Your result replaces the previous
final result for this base.

EOF
  sed 's/^/> /' "$rebuttal"
  echo
}

pk_contract() {
  printf '# Result contract\nWrite %s (relative to the repository root, your working directory). Its first six lines must be exactly these,\n' "${file%.md}.result.md"
  printf 'in this order, with nothing before them:\nrun: completed|failed|blocked\nverdict: pass|fail|inconclusive\n'
  printf 'base: %s\nblocker: <count>\nmajor: <count>\nminor: <count>\n' "$base"
  cat <<'EOF'
run: completed = you carried out this packet; failed or blocked = you could not (say why below).
Counts are integers, 0 when none, and match the findings below.
Then a blank line, the findings — `<n>. <blocker|major|minor> — <check id> — <what is wrong> —
<command + output, or file:line> — <fix>` —, then (slice) the claim lines, then the commands you
ran. When done, reply with only the result path.
EOF
}

# --- fresh judge context (a slash command, no model turn) --------------------
# `/new` to the judge, then wait for an empty composer. Codex 0.165.0 first
# asks where the new conversation runs; the one answer given here is enter
# on the highlighted "1. Use current Git worktree". Any other screen is the
# human's: the packet is never typed into a dialog. The TUI redraw after
# /new can read as `working` for a moment, so poll before calling it stuck.
# $1 = seq to attribute the runlog row to.
fresh_thread() {
  local seq="$1" s picked=0 _i
  clear_modals
  composer_ready "$(screen 40)" || hand_over "the judge is not at an empty prompt — /new was not sent"
  herdr agent prompt "$NAME" "/new" >/dev/null 2>&1 || refuse "sending /new failed"
  for _i in $(seq 1 15); do
    sleep 1   # the screen before /new also shows a composer
    s="$(screen 40)"
    if grep -qF "$NEW_PICKER" <<<"$s"; then
      if [ "$picked" = 0 ]; then   # once; then wait for it to close
        grep -qE '^[[:space:]]*› 1\. Use current Git worktree' <<<"$s" ||
          hand_over "the judge's new-thread picker has another choice highlighted — the packet was not sent"
        herdr agent send-keys "$NAME" enter >/dev/null 2>&1 || hand_over "could not answer the new-thread picker"
        picked=1
      fi
    elif composer_ready "$s"; then
      if [ "$picked" = 1 ]; then s="/new + current worktree"; else s=/new; fi
      log_row "$seq" reset - - - - "$s"
      return 0
    fi
  done
  hand_over "the judge did not come back to an empty prompt after /new — the packet was not sent"
}

# check = packet + send: the quota is asked before the packet is written,
# so a refused run leaves no packet behind.
check_cmd() {
  local a=() x over=0 unit="" pk
  for x in "$@"; do if [ "$x" = --over-estimate ]; then over=1; else a+=("$x"); fi; done
  resolve_task
  case "${a[0]:-}" in card|final) unit="${a[0]}" ;; slice) unit="${a[1]:-}" ;; esac
  if [ "$unit" = card ] || [ "$unit" = final ] || [[ "$unit" =~ ^S[0-9]+$ ]]; then
    quota "${a[0]}" "$unit" "$over" quiet
  fi
  pk="$(packet ${a[@]+"${a[@]}"})" || exit $?
  echo "task-pair: packet $pk"
  if [ "$over" = 1 ]; then send "$pk" --over-estimate; else send "$pk"; fi
}

cmd="${1:-}"
[ $# -gt 0 ] && shift
case "$cmd" in
  ensure) ensure ;;
  check) check_cmd "$@" ;;
  packet) packet "$@" ;;
  send) send "$@" ;;
  wait) wait_run "$@" ;;
  digest) resolve_task; card_digest ;;
  fingerprint)
    s="$(tr -d '[:space:]' < .ai_context/tasks/CURRENT 2>/dev/null || true)"
    if [ -n "$s" ]; then TASK=".ai_context/tasks/$s"; PAIR_DIR="$TASK/pair"; fi
    fingerprint ;;
  *) echo "Usage: task-pair.sh <ensure|check card|check slice S<n> [--since REF]|check final [--since REF] [--rebuttal FILE]|packet …|send <packet> [--over-estimate]|wait <seq>|digest|fingerprint>" >&2; exit 2 ;;
esac
