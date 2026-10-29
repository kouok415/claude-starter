#!/usr/bin/env bash
# task-pair.sh — drive the Codex judge of a /task over herdr (pair on).
#
# The skill (pair.md) decides WHEN to ask; this script asks the same way
# every time. Files are the contract: `tasks/<slug>/pair/NNN-<stage>[-S<n>].md`
# packet in, `.result.md` out. herdr starts the agent, submits, waits and
# reports `blocked`. The script decides only run_state and never prints a
# verdict of its own; every settled run becomes an evidence record through
# `scripts/evidence.sh codex` (workshop ADR-028, ADR-030, ADR-039), which
# binds the result to the judge's own write in its Codex transcript.
#
#   ensure                                  find or start the judge
#   check card                              write the card packet, send it
#   check slice S<n> [--since REF]          REF: the HEAD `evidence.sh start` recorded
#   check final [--since REF] [--rebuttal F]  REF: the card's base:
#   packet <same as check>                  write the packet only, print its path
#   send <packet> [--timeout MS] [--over-estimate]  /new, prompt, wait, collect, record
#   wait <seq> [--timeout MS]               re-attach to a run in flight, or retry its record
#   digest                                  card:<sha256>, status marks excluded
#   fingerprint                             tree fingerprint (test seam)
#
# REF defaults to that commit and must be it: evidence.sh codex binds a
# review only to the content since there. Run check/send/wait in the
# background: one run can take an hour. A run past what the human consented
# to (pair.md §Quota) is refused (3), and so is a check of content whose
# last completed review failed; --over-estimate is for after their yes.
# Run state is the ledger's, not memory: .claude/evidence/pair/<slug>/
# (gitignored, Edit-denied) holds the judge record, fp-<seq> (a run in
# flight; parked-<seq> while the judge is blocked in it), settle-<seq> (while
# its record is written), unrecorded-<seq> (a settled run whose record
# failed) and the not_started ledger.
# Exit: 0 completed + recorded (the verdict is in the result); 2 usage;
# 3 refused; 4 the judge needs the human (a dialog; blocked mid-run: answer
# it, then wait <seq>); 5 in flight / herdr wait timed out (run wait <seq>);
# 6 no usable result, not_started, or the record failed (wait <seq> retries).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
DEFAULT_TIMEOUT_MS=7200000   # send runs in the background; this is herdr's own wait, not a tool-call cap
START_TIMEOUT_MS=60000
START_GRACE_S="${TASK_PAIR_START_GRACE_S:-10}"   # a turn that shows no sign of starting gets this many polls (tests shorten it)
NEW_WAIT_S="${TASK_PAIR_NEW_WAIT_S:-15}"          # how long /new may take to show (tests shorten it)
# The pauses between two looks at the judge. The defaults are what live
# Codex/herdr need — a repaint, a dialog closing after esc, a judge settling
# after its start, a turn that shows only after herdr reported a stall, /new
# taking effect — and stay as they are; the overrides exist for the test
# suite, whose fake herdr answers at once.
POLL_S="${TASK_PAIR_POLL_S:-1}"             # blank-read retry, after esc, after the start, each not_started grace poll
NEW_POLL_S="${TASK_PAIR_NEW_POLL_S:-0.25}"  # /new: NEW_WAIT_S*4 screen reads this far apart; 4 of them are "a full second"
CODEX_LEDGER=.claude/evidence/codex.jsonl

# Paths under $HOME are written as ~/…: pair/ is tracked, and a home path
# names the user (runlog, packets, screen dumps, messages).
# shellcheck disable=SC2088  # t is a literal ~/ on purpose
tilde() { local t='~/'; if [ -n "${HOME:-}" ] && [ "$HOME" != / ]; then printf '%s' "${1//"$HOME"\//$t}"; else printf '%s' "$1"; fi; }
# Codex wraps long lines at the pane width, sometimes inside $HOME: a line
# that ends with the start of "$HOME/" is joined to the next one when that
# one (indent dropped) completes it, so tilde() sees the whole path (M5).
unwrap_home() {
  if [ -z "${HOME:-}" ] || [ "$HOME" = / ]; then cat; return; fi
  awk -v h="$HOME/" '
    { L[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        s = L[i]
        while (i < NR) {
          n = L[i + 1]; sub(/^[[:space:]]+/, "", n); j = 0
          for (k = length(h) - 1; k >= 1 && !j; k--)
            if (length(s) >= k && substr(s, length(s) - k + 1) == substr(h, 1, k) && index(n, substr(h, k + 1)) == 1) j = k
          if (!j) break
          s = s n; i++
        }
        print s
      }
    }'
}
die() { echo "task-pair: $(tilde "$*")" >&2; exit "${RC:-2}"; }
refuse() { RC=3 die "$@"; }

# --- JSON helpers (herdr prints compact JSON; no jq in the template) -------
jstr() { # $1 = key -> a string value of that key on stdin
  sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
}
rec_get() { # $1 = an evidence.sh record (flat JSON, no quotes inside values), $2 = key -> its value
  sed -n "s/.*\"$2\":\"\{0,1\}\([^\",}]*\).*/\1/p" <<<"$1" | head -n 1
}

hash_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256
  else cksum
  fi
}

# HEAD + status + diff + untracked content, minus what is machine-written
# while a run is in flight: the runlog, this run's result, the donelog,
# .ai_context/defects.csv and .claude/evidence/ — the gate, spawn-log and a
# parallel checker write those during every run (R16; defects.csv gets a row
# from spawn-log's `evidence.sh check` of a failing checker and from
# `evidence.sh codex` with blocker/major findings). Everything else under
# pair/ (packets, old results) counts: a judge that touched anything voids
# its own verdict.
# Untracked files: "<path> <sha256>" up to 1 MiB, "<path> <size|?> <mtime|?>"
# above (or unreadable). Readable plain files are sized by one stat and hashed
# by one hasher run; anything else — or a stat or hasher answering short —
# goes one file at a time (fp_one), so the lines are the same either way.
fp_one() { # $1 = a name as ls-files -o prints it -> its fingerprint line
  local p="$ROOT/$1" sz
  sz="$(wc -c < "$p" 2>/dev/null | tr -d ' ' || true)"
  if [ -n "$sz" ] && [ "$sz" -le 1048576 ]; then
    printf '%s %s\n' "$1" "$(hash_stdin < "$p" | awk '{print $1}')"
  else
    printf '%s %s %s\n' "$1" "${sz:-?}" \
      "$(stat -c %Y "$p" 2>/dev/null || stat -f %m "$p" 2>/dev/null || echo '?')"
  fi
}
fp_untracked() { # stdin: ls-files -o names -> their fingerprint lines, in order
  local uf i j=0 k=0 ok=1 m names=() plain=() sizes=() small=() sums=() hs
  while IFS= read -r uf; do names+=("$uf"); done
  [ ${#names[@]} -gt 0 ] || return 0
  for uf in "${names[@]}"; do
    if [ -f "$ROOT/$uf" ] && [ -r "$ROOT/$uf" ]; then plain+=("$ROOT/$uf"); fi
  done
  if [ ${#plain[@]} -gt 0 ]; then
    m="$(stat -L -c %s -- "${plain[@]}" 2>/dev/null || stat -L -f %z -- "${plain[@]}" 2>/dev/null)" || ok=""
    [ -z "$m" ] || while IFS= read -r i; do sizes+=("$i"); done <<< "$m"
    [ ${#sizes[@]} = ${#plain[@]} ] || ok=""
    for i in ${sizes[@]+"${sizes[@]}"}; do
      case "$i" in ''|*[!0-9]*) ok="" ;; esac
    done
  fi
  if [ -n "$ok" ] && [ ${#plain[@]} -gt 0 ]; then
    for ((i = 0; i < ${#plain[@]}; i++)); do
      if [ "${sizes[i]}" -le 1048576 ]; then small+=("${plain[i]}"); fi
    done
    if [ ${#small[@]} -gt 0 ]; then
      if command -v sha256sum >/dev/null 2>&1; then hs=(sha256sum)
      elif command -v shasum >/dev/null 2>&1; then hs=(shasum -a 256)
      else hs=(cksum)
      fi
      m="$("${hs[@]}" -- "${small[@]}" 2>/dev/null)" || ok=""
      [ -z "$m" ] || while read -r i _; do sums+=("$i"); done <<< "$m"
      [ ${#sums[@]} = ${#small[@]} ] || ok=""
      # a bare digest only: a hasher escapes some names with a leading backslash
      for i in ${sums[@]+"${sums[@]}"}; do
        if [ "${hs[0]}" = cksum ]; then case "$i" in ''|*[!0-9]*) ok="" ;; esac
        else case "$i" in *[!0-9a-f]*) ok="" ;; esac; [ ${#i} = 64 ] || ok=""
        fi
      done
    fi
  fi
  for uf in "${names[@]}"; do
    if [ -n "$ok" ] && [ $j -lt ${#plain[@]} ] && [ "${plain[j]}" = "$ROOT/$uf" ]; then
      if [ "${sizes[j]}" -le 1048576 ]; then
        printf '%s %s\n' "$uf" "${sums[k]}"
        k=$((k + 1))
      else
        fp_one "$uf"
      fi
      j=$((j + 1))
    else
      if [ $j -lt ${#plain[@]} ] && [ "${plain[j]}" = "$ROOT/$uf" ]; then j=$((j + 1)); fi
      fp_one "$uf"
    fi
  done
}
fingerprint() {
  git -C "$ROOT" rev-parse HEAD >/dev/null 2>&1 || return 1
  local ex=(':(exclude).claude/evidence' ':(exclude).ai_context/defects.csv')
  [ -z "${TASK:-}" ] || ex+=(":(exclude)$TASK/donelog")
  [ -z "${PAIR_DIR:-}" ] || ex+=(":(exclude)$PAIR_DIR/runlog")
  [ -z "${RESULT:-}" ] || ex+=(":(exclude)$RESULT")
  {
    git -C "$ROOT" rev-parse HEAD
    git -C "$ROOT" status --porcelain -- . "${ex[@]}"
    git -C "$ROOT" diff HEAD -- . "${ex[@]}"
    git -C "$ROOT" ls-files -o --exclude-standard -- . "${ex[@]}" | fp_untracked
  } 2>/dev/null | hash_stdin | awk '{print $1}'
}

# --- Task, pair mode, card digest ----------------------------------------------
SLUG=""; TASK=""; CARD=""; PAIR_DIR=""; RUNLOG=""; JUDGE_FILE=""; NAME=""; SAFE_SLUG=""; REPO_ID=""; EVP=""
RESULT=""; SCRATCH=""; LOCK=""; OVER=""; PRECHECKED=""
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
  PAIR_DIR="$TASK/pair"; RUNLOG="$PAIR_DIR/runlog"
  mkdir -p "$PAIR_DIR"
  # Judge scratch and the judge itself are keyed by repo path and slug: two
  # checkouts of one task never share either (R17, pair review M4).
  SAFE_SLUG="$(printf '%s' "$SLUG" | tr -c 'a-z0-9_.-' '-')"
  REPO_ID="$(printf '%s' "$ROOT" | hash_stdin | awk '{print substr($1, 1, 8)}')"
  # herdr agent names: [a-z][a-z0-9_-]{0,31}, unique per server.
  NAME="$(printf 'judge-%s-%s' "$REPO_ID" "$SLUG" | tr -c 'a-z0-9_\n-' '-' | cut -c1-32)"
  EVP=".claude/evidence/pair/$SAFE_SLUG"; JUDGE_FILE="$EVP/judge"
}
# Run state lives with the ledger, not in tracked pair/: .claude/evidence/ is
# gitignored and Edit-denied, so what a run left behind is not the main
# session's to rewrite (pair review C1).
mk_evp() {
  git check-ignore -q .claude/evidence/x 2>/dev/null ||
    refuse ".claude/evidence/ is not gitignored — add it to .gitignore first (the judge record, run state and Codex records live there)"
  (umask 077; mkdir -p "$EVP")
}
fp_get() { sed -n "s/^$1=//p" "$2" 2>/dev/null | head -n 1 || true; }

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
  refuse ".codex/hooks.json exists and the judge on record was not started with features.hooks=false — close its pane and run ensure again"
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
# Codex reads AGENTS.override.md, then AGENTS.md, whenever one exists and
# then skips the CLAUDE.md fallback, and cuts the project doc at
# project_doc_max_bytes (32 KiB by default). Checked on every ensure, a
# running judge included (R18; AGENTS.override.md: pair review L2).
DOC_MAX=32768
doc_check() {
  local f
  [ -f CLAUDE.md ] || refuse "CLAUDE.md missing — the judge reads it as its project doc"
  for f in AGENTS.override.md AGENTS.md; do
    { [ -e "$f" ] || [ -L "$f" ]; } && ! cmp -s "$f" CLAUDE.md || continue
    case "$f" in
      AGENTS.md) refuse "AGENTS.md differs from CLAUDE.md — Codex reads AGENTS.md and skips the CLAUDE.md fallback; delete it or make it a copy or symlink of CLAUDE.md" ;;
      *) refuse "AGENTS.override.md differs from CLAUDE.md — Codex reads it before AGENTS.md and skips the CLAUDE.md fallback; delete it or make it a copy or symlink of CLAUDE.md" ;;
    esac
  done
  DOC_MAX=$(( ($(wc -c < CLAUDE.md) / 4096 + 1) * 4096 ))
  [ "$DOC_MAX" -ge 32768 ] || DOC_MAX=32768
}
# A running judge keeps the cap it started with; one started before CLAUDE.md
# grew, or by someone else (no record), would read a cut project doc.
judge_record_check() {
  local have
  have="$(fp_get doc_max_bytes "$JUDGE_FILE")"
  if [[ "$have" =~ ^[0-9]+$ ]] && [ "$have" -ge "$DOC_MAX" ]; then return 0; fi
  refuse "judge '$NAME' was not started for the current CLAUDE.md (doc_max_bytes=${have:-none}, need $DOC_MAX) — close pane ${J_PANE:-?} and run ensure again"
}
# The judge is this checkout's (M4): herdr runs it in ROOT (logical or
# physical path) and in the pane its record names.
judge_identity_check() {
  local rec
  [ "$J_CWD" = "$ROOT" ] || [ "$J_CWD" = "$(cd "$ROOT" && pwd -P)" ] ||
    refuse "judge '$NAME' runs in ${J_CWD:-?}, not in this checkout ($ROOT) — close pane ${J_PANE:-?} and run ensure again"
  rec="$(fp_get pane_id "$JUDGE_FILE")"
  [ -n "$J_PANE" ] && [ "$J_PANE" = "$rec" ] ||
    refuse "judge '$NAME' is in pane ${J_PANE:-?} but its record says ${rec:-none} — close pane ${J_PANE:-?} and run ensure again"
}

# --- Screen inspection -----------------------------------------------------
screen() { tilde "$( (herdr agent read "$NAME" --source visible --lines "${1:-40}" 2>/dev/null || true) | unwrap_home)"; echo; }

# A Codex dialog replaces the composer: its footer ("enter … · esc …") is the
# last line on screen, its header and options sit right above it. Only that
# bottom block is read (H3): the transcript above — a quoted dialog, this
# script's own source on the judge's screen — never counts as a dialog.
# Texts recorded on Codex 0.165.0 (2026-10-28); the trust dialog's 0.154
# wording is kept.
DIALOG_FOOTER='[Ee]nter (to )?(continue|confirm|select)|esc (to )?(skip|quit|back|cancel|go back)'
NEW_PICKER='Where should the new conversation run?'
dialog_block() { # $1 screen -> the lines of the dialog at its bottom, or nothing
  awk -v f="$DIALOG_FOOTER" '
    { L[NR] = $0 }
    END {
      n = NR
      while (n > 0 && L[n] ~ /^[[:space:]]*$/) n--
      if (n == 0 || L[n] !~ f) exit
      for (i = n; i > 0; i--) {
        if (L[i] ~ /^• / || (L[i] ~ /^› / && L[i] !~ /^› [0-9]+\. /) || L[i] ~ / in · [^·]* out/) break
        b = L[i] "\n" b
      }
      printf "%s", b
    }' <<<"$1"
}
modal_label() { # $1 screen -> the label of its dialog; rc 1 when there is none. herdr reports idle under all of them
  local b
  b="$(dialog_block "$1")"
  [ -n "$b" ] || return 1
  if grep -qE 'Trust this folder\?|Do you trust the contents of this directory' <<<"$b"; then echo trust
  elif grep -q 'Update available' <<<"$b" && grep -q 'esc skip' <<<"$b"; then echo update
  elif grep -qiE 'switch to gpt-|approaching rate limits' <<<"$b"; then echo rate-limit
  elif grep -qF "$NEW_PICKER" <<<"$b"; then echo new-thread-picker
  else echo unknown-dialog
  fi
}
modal_on_screen() { modal_label "$(screen 40)"; }

# esc is sent only where the dialog itself says esc is the harmless answer:
# the rate-limit nudge (esc keeps the current model) and the update notice
# ("esc skip" — enter would run Codex's installer), and only to a judge
# herdr reports idle (H3: to a working judge esc is "interrupt"). The trust
# dialog's esc quits Codex; it and every other dialog are the human's.
dismiss_soft() { # $1 label -> the label still on screen afterwards, or nothing
  case "$1" in
    rate-limit|update)
      case "$(judge_status)" in idle|done) ;; *) echo "$1"; return 0 ;; esac
      herdr agent send-keys "$NAME" esc >/dev/null 2>&1 || true
      sleep "$POLL_S"
      modal_on_screen || true ;;
    *) echo "$1" ;;
  esac
}
hand_over() { # $1 what the human must do -> exit 4 with the screen saved
  echo "task-pair: $1:" >&2
  show_screen "dialog-$(date -u +%Y%m%dT%H%M%SZ).screen.txt"
  RC=4 die "human input required"
}
clear_modals() {
  local m
  m="$(modal_on_screen || true)"
  [ -z "$m" ] || m="$(dismiss_soft "$m")"
  [ -z "$m" ] || hand_over "judge shows a '$m' dialog — answer it in the pane, then retry"
}
# Ready for a prompt: herdr says idle, no dialog, and the last `›` line on
# screen is the EMPTY composer (L3): a placeholder, never a draft someone
# typed (it would turn /new into "<draft>/new", a model turn).
EMPTY_COMPOSER='› (Ask Codex to do anything|Explain this codebase|Summarize recent commits|Implement \{feature\}|Find and fix a bug in @filename|Write tests for @filename|Improve documentation in @filename|Run /review on my current changes|Use /skills to list available skills)[[:space:]]*$'
composer_ready() { # $1 screen
  local last
  case "$(judge_status)" in idle|done) ;; *) return 1 ;; esac
  ! modal_label "$1" >/dev/null || return 1
  last="$(grep -E '^[[:space:]]*› ' <<<"$1" | tail -n 1 || true)"
  grep -qE "^[[:space:]]*$EMPTY_COMPOSER" <<<"$last"
}
# One read can catch a repaint (a blank screen, seen live): three reads, a
# second (POLL_S) apart, before calling the judge not ready (L6).
wait_composer() { # -> the screen once the judge sits at an empty prompt; rc 1 otherwise
  local s _i
  for _i in 1 2 3; do
    s="$(screen 40)"
    if composer_ready "$s"; then printf '%s' "$s"; return 0; fi
    [ "$_i" = 3 ] || sleep "$POLL_S"
  done
  return 1
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
tokens_of() { sed -n 's/.*· \([0-9.]*[kKmM]\{0,1\}\) in · \([0-9.]*[kKmM]\{0,1\}\) out.*/\1\/\2/p' <<<"$1" | tail -n 1; }
judge_tokens() { local t; t="$(tokens_of "$(screen 40)")"; echo "${t:--}"; }
tok_n() { # "12.3k" -> 12300; nothing when it is no count
  awk -v t="$1" 'BEGIN { if (t !~ /^[0-9.]+[kKmM]?$/) exit; m = 1; if (t ~ /[kK]$/) m = 1000; if (t ~ /[mM]$/) m = 1000000
    sub(/[kKmM]$/, "", t); printf "%d\n", t * m }'
}
# The judge's transcript of one run: a Codex rollout written since the run
# began (newer than its fp file), in a day dir from the day before the run
# on, whose session_meta names this repo and which holds this packet's path
# (the prompt). Looked up only after the prompt, never per runlog row (L1).
day_of() { date -d "@$1" +%Y/%m/%d 2>/dev/null || date -r "$1" +%Y/%m/%d; }
judge_rollout() { # $1 seq, $2 packet -> path, or '?'
  local fp="$EVP/fp-$1" t0 day0 d f h ts best="" best_ts="" root2
  { [ -f "$fp" ] && [ -d "$CODEX_HOME_DIR/sessions" ]; } || { echo '?'; return 0; }
  t0="$(fp_get t0 "$fp")"; [[ "$t0" =~ ^[0-9]+$ ]] || t0="$(date +%s)"
  day0="$(day_of $((t0 - 86400)) || echo 0000/00/00)"
  root2="$(cd "$ROOT" && pwd -P)"
  for d in "$CODEX_HOME_DIR"/sessions/[0-9]*/[0-9]*/[0-9]*; do
    [ -d "$d" ] || continue
    [[ "${d#"$CODEX_HOME_DIR"/sessions/}" < "$day0" ]] && continue
    while IFS= read -r f; do
      h="$(head -c 8192 "$f" 2>/dev/null || true)"
      grep -qF -e "\"cwd\":\"$ROOT\"" -e "\"cwd\":\"$root2\"" <<<"$h" || continue
      grep -qF -- "$2" "$f" 2>/dev/null || continue
      ts="$(sed -n 's/^{"timestamp":"\([^"]*\)".*/\1/p' <<<"$h" | head -n 1)"
      if [ -z "$best" ] || [[ "$ts" > "$best_ts" ]]; then best="$f"; best_ts="$ts"; fi
    done < <(find "$d" -maxdepth 1 -name 'rollout-*.jsonl' -newer "$fp" 2>/dev/null)
  done
  echo "${best:-?}"
}

judge_info() { # -> J_ST J_CWD J_PANE from one herdr agent get
  local j
  j="$(herdr agent get "$NAME" 2>/dev/null || true)"
  J_ST="$(jstr agent_status <<<"$j")"; J_CWD="$(jstr cwd <<<"$j")"; J_PANE="$(jstr pane_id <<<"$j")"
}
J_ST=""; J_CWD=""; J_PANE=""
judge_status() { herdr agent get "$NAME" 2>/dev/null | jstr agent_status || true; }

# --- runlog: append-only, tab-separated, UTC ----------------------------------
# ts  seq  event  stage  unit  base  digest  model  tokens  rollout  detail
# (stage and unit are columns 4-5, as in v3, so readers keep their column
# numbers). model/tokens are observed at write time — a run's cost is the
# token delta between its start and end rows; rollout (end rows only, '-'
# elsewhere, '?' when none was found) is the judge's own transcript of it.
# Events: reset, start, waiting, blocked, end:<state>, record_failed.
log_row() { # seq event stage unit base digest detail [rollout]
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$1" "$2" "$3" "$4" "$5" "$6" "$(judge_model)" "$(judge_tokens)" "$(tilde "${8:--}")" "$7" >> "$RUNLOG"
}
# The project's secret scan (.claude/gitleaks.toml) on a file in tracked pair/
# (a screen, a result): a hit or a failed scan moves it to
# .claude/evidence/logs/ (local, gitignored) and leaves a stub naming why
# (M5). Without gitleaks only the internal-IP rule runs (rc 3); the file
# stays, as the pre-commit scan would let it.
scan_ok() { local r=0; bash scripts/precommit-gitleaks.sh --scan-file "$1" >/dev/null 2>&1 || r=$?; [ "$r" = 0 ] || [ "$r" = 3 ]; }
withhold() { # $1 file under pair/, $2 what -> the path that holds its content now
  local o rc=0 w to=".claude/evidence/logs/pair-$SAFE_SLUG-${1##*/}"
  o="$(bash scripts/precommit-gitleaks.sh --scan-file "$1" 2>/dev/null)" || rc=$?
  if [ "$rc" = 0 ] || [ "$rc" = 3 ]; then echo "$1"; return 0; fi
  case "$rc:$o" in
    1:|1:scan-error) w="the secret scan failed" ;;
    1:*) w="secret scan hit: $(printf '%s' "$o" | tr '\n' ' ' | sed 's/ $//')" ;;
    *) w="the secret scan failed (rc $rc)" ;;
  esac
  (umask 077; mkdir -p .claude/evidence/logs; mv -f "$1" "$to")
  printf '%s withheld (%s): it is in %s, local only — read it there; never commit or paste it\n' "$2" "$w" "$to" > "$1"
  echo "task-pair: $2 withheld ($w): $to" >&2
  echo "$to"
}
# The judge's screen as it was (a stderr excerpt is not retrievable later):
# saved next to the packet once the scan passes, else withheld; $2 = local
# saves it straight to .claude/evidence/logs/ (a run still in flight: a new
# file in pair/ would void it).
save_screen() { # $1 file name, $2 local -> the path holding it
  local f="$PAIR_DIR/$1"
  if [ -n "${2:-}" ]; then f=".claude/evidence/logs/pair-$SAFE_SLUG-$1"; (umask 077; mkdir -p .claude/evidence/logs); fi
  screen 80 > "$f" 2>/dev/null || true
  if [ -n "${2:-}" ]; then echo "$f"; else withhold "$f" screen; fi
}
show_screen() { # $1 file name, $2 local -> a 12-line excerpt on stderr, unless the secret scan withheld it
  local f o=0
  f="$(save_screen "$1" "${2:-}")"
  case "$f" in "$PAIR_DIR"/*) ;; *) scan_ok "$f" || o=1 ;; esac
  if [ "$o" = 0 ]; then tail -n 12 "$f" | sed 's/^/    /' >&2
  else echo "    (screen not shown: the secret scan did not pass — $f)" >&2; fi
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
  resolve_task; doc_check; require_herdr; trust_check; mk_evp
  local pane_id resp started
  judge_info
  if [ -n "$J_ST" ]; then
    hooks_tripwire; judge_record_check; judge_identity_check
    echo "task-pair: judge '$NAME' present ($J_ST) — $(judge_model)"
    # Keys go only to an idle judge (H3): a dialog under a working or
    # blocked one is left alone; send reports the status.
    case "$J_ST" in idle|done) clear_modals ;; esac
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
  started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
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
    echo "name=$NAME"; echo "pane_id=$pane_id"; echo "cwd=$ROOT"; echo "hooks_off=1"
    echo "doc_max_bytes=$DOC_MAX"; echo "started=$started"
  } > "$JUDGE_FILE"
  sleep "$POLL_S"
  case "$(judge_status)" in
    idle|done) clear_modals ;;   # an update notice at startup is skipped (esc); anything else exits 4
    *) hand_over "judge '$NAME' in pane $pane_id is not ready — answer it there, then run ensure again" ;;
  esac
  echo "task-pair: judge '$NAME' started in $pane_id — $(judge_model) (project doc CLAUDE.md, cap $DOC_MAX B)"
}

# --- packet fields, the result contract ------------------------------------
pk_field() { sed -n "s/^$1:[[:space:]]*//p" "$2" | head -1; }

# The result's first six lines hold run verdict base blocker major minor, each
# exactly once, in any order (CRLF is fine). Anything else there is
# bad_header:<first key at fault>; another base is base_mismatch; counts
# that are not the number of `<n>. <severity> — …` finding lines below are
# bad_header:counts (M6). These are the lines evidence.sh codex reads
# (pair.md §Result contract).
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
  for k in blocker major minor; do
    [ "$(tail -n +7 "$1" | tr -d '\r' | grep -cE "^[0-9]+\. $k (—|--?) " || true)" = "$(rfield "$k" "$1")" ] ||
      { echo bad_header:counts; return; }
  done
}

# Collect after herdr reports a settled state; the first reason found wins.
STATE=""; REASON=""
collect() { # $1 seq, $2 result, $3 base, $4 fp_before, $5 herdr status, $6 herdr error code -> STATE REASON
  local r
  case "$5" in
    idle|done) ;;
    *) STATE=failed; REASON="herdr_${6:-${5:-gone}}"; return ;;
  esac
  r="$(check_result "$2" "$3")"
  if [ -n "$r" ]; then STATE=failed; REASON="$r"; return; fi
  # Anything new in pair/ besides the result — gitignored files too, which
  # the fingerprint cannot see — is judge scratch in the mailbox.
  r="$(find "$PAIR_DIR" -mindepth 1 -newer "$EVP/fp-$1" ! -name runlog ! -path "$2" 2>/dev/null || true)"
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
finish() { # seq stage unit base digest packet result -> 0 completed · 6 otherwise
  local m ro at="$7"
  ro="$(judge_rollout "$1" "$6")"
  log_row "$1" "end:$STATE" "$2" "$3" "$4" "$5" "$REASON" "$ro"
  [ "$STATE" = completed ] || save_screen "$1-$2.screen.txt" >/dev/null
  # Post-run dialog sweep: the rate-limit nudge and the update notice get esc
  # (dismiss_soft); anything else is reported, not answered — the run itself
  # is already settled, so this never changes STATE.
  m="$(modal_on_screen || true)"
  [ -z "$m" ] || m="$(dismiss_soft "$m")"
  [ -z "$m" ] || echo "task-pair: WARNING judge shows a '$m' dialog — answer it in the pane before the next send" >&2
  [ ! -s "$7" ] || at="$(withhold "$7" result)"
  { cat "$EVP/fp-$1"; echo "state=$STATE"; echo "reason=$REASON"; echo "rollout=$ro"; echo "result_at=$at"
    echo "model=$(judge_model)"; } > "$EVP/settle-$1"
  record_run "$1" "$2" "$3" "$6" "$7" "$EVP/settle-$1"
}
# The record and the cleanup after it are one step (L7): signals wait, and
# a packet that already has a record in this task is never recorded twice.
recorded() { # $1 packet sha -> the id of this task's record of it, if any
  [ -f "$CODEX_LEDGER" ] || return 0
  A="\"packet_sha\":\"$1\"" B="\"task\":\"$SLUG\"," awk 'index($0, ENVIRON["A"]) && index($0, ENVIRON["B"]) {r = $0} END {if (r != "") print r}' \
    "$CODEX_LEDGER" | sed -n 's/^{"id":"\([^"]*\)".*/\1/p'
}
record_run() { # seq stage unit packet result statefile -> the summary line; rc 0 completed · 6 otherwise
  local f="$6" rec="" rc=0 st why at t0 dg
  st="$(fp_get state "$f")"; why="$(fp_get reason "$f")"; at="$(fp_get result_at "$f")"
  t0="$(fp_get t0 "$f")"; [[ "$t0" =~ ^[0-9]+$ ]] || t0="$(date +%s)"
  dg="$(hash_stdin < "$4" | awk '{print $1}')"
  trap '' TERM INT HUP
  rec="$(recorded "$dg")"
  if [ -z "$rec" ]; then
    rec="$(PAIR_MODEL="$(fp_get model "$f")" PAIR_ROLLOUT="$(fp_get rollout "$f")" PAIR_SINCE="$(fp_get since "$f")" \
             PAIR_SECS="$(($(date +%s) - t0))" PAIR_RESULT_PATH="$5" \
             bash "$ROOT/scripts/evidence.sh" codex "$4" "${at:-$5}" "$st" "$why" | tail -n 1)" || rc=$?
  fi
  if [ "$rc" != 0 ]; then
    log_row "$1" record_failed "$2" "$3" "$(pk_field base "$4")" "$dg" "rc=$rc"
    [ "$f" = "$EVP/unrecorded-$1" ] || mv -f "$f" "$EVP/unrecorded-$1"
    rm -f "$EVP/fp-$1"
    trap 'exit 5' TERM INT HUP
    echo "task-pair: evidence.sh codex failed (rc $rc) — this run is NOT recorded (it still counts against the quota); the result is kept: ${at:-$5}. Fix what evidence.sh printed, then retry the record in the background: task-pair.sh wait $1 (a new check is not blocked by it)" >&2
    return 6
  fi
  rm -f "$EVP/fp-$1" "$EVP/settle-$1" "$EVP/unrecorded-$1"
  trap 'exit 5' TERM INT HUP
  if [ "$st" != completed ]; then echo "task-pair: scratch kept: $SCRATCH"
  else case "$SCRATCH" in /tmp/pair-*/*) rm -rf "$SCRATCH"; rmdir "${SCRATCH%/*}" 2>/dev/null || true ;; esac
  fi
  echo "task-pair: seq=$1 stage=$2 unit=$3 state=$st ($why) result=${at:-$5} record=$rec"
  [ "$st" = completed ] || return 6
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
# fingerprint and the mailbox check both see it), so packet and send refuse
# first. A run whose record failed (unrecorded-<seq>) blocks nothing (M8).
no_run_in_flight() {
  local k p s
  need_guard
  for k in .claude/evidence/locks/pair-*.lock; do
    [ -f "$k" ] || continue
    p="$(cut -f1 "$k" | head -n 1)"
    if lock_alive "$p"; then RC=5 die "seq $(lock_seq "$k") is in flight (pid $p) — wait for its notification; a packet written now would void it"; fi
  done
  for k in "$EVP"/fp-*; do
    [ -f "$k" ] || continue
    s="${k##*/fp-}"
    if [ -f "$EVP/parked-$s" ]; then
      RC=4 die "seq $s: the judge is blocked mid-run, waiting for you in its pane (an approval or a question) — answer it there, then run in the background: task-pair.sh wait $s"
    fi
    RC=5 die "seq $s has not settled — run in the background: task-pair.sh wait $s"
  done
}
release_lock() {   # only our own: a refused send never removes another run's lock
  if [ -n "$LOCK" ] && [ "$(cut -f1 "$LOCK" 2>/dev/null)" = "$$" ]; then rm -f "$LOCK"; fi
  LOCK=""
}

# --- quota (pair.md §Quota, U1) and what a run may review -----------------------
# What the human consented to: starting a pair /task covers the card check
# and one retry (card 2); approving the card covers one run per `codex: yes`
# slice and the final, a retry each, and the rebuttal (slice 2, final 3).
# Used = this task's Codex records of the unit in the ledger plus its runs not
# yet recorded (in flight, or record_failed): the tracked runlog is no source
# (M7). A not_started attempt is no run and is never counted.
# --over-estimate (bash-guard asks the human) passes.
slice_line() { grep -E "^- \[[ ~ox]\] $1( |\$)" "$CARD" || true; }
codex_yes() { case "${1%% ✓ *}" in *' ; codex: yes'|*' ; codex: yes ; '*) return 0 ;; esac; return 1; }
used_runs() { # $1 stage, $2 unit ('' '' = every unit) -> the count
  local n=0 f a="\"lane\":\"codex-$1\",\"unit\":\"$2\","
  [ -n "$1" ] || a='"lane":"codex-'
  [ ! -f "$CODEX_LEDGER" ] ||
    n="$(A="$a" B="\"task\":\"$SLUG\"," awk 'index($0, ENVIRON["A"]) && index($0, ENVIRON["B"]) {n++} END {print n + 0}' "$CODEX_LEDGER")"
  for f in "$EVP"/fp-* "$EVP"/unrecorded-*; do
    [ -f "$f" ] || continue
    if [ -z "$1" ] || [ "$(fp_get stage "$f") $(fp_get unit "$f")" = "$1 $2" ]; then n=$((n + 1)); fi
  done
  echo "$n"
}
# A Codex run reviews the card (card/card), a slice on it (slice/S<n>) or
# the task (final/final) — nothing a hand-written packet names besides (M7).
unit_check() { # $1 stage, $2 unit
  case "$1:$2" in
    card:card|final:final) return 0 ;;
    slice:S*) [[ "$2" =~ ^S[0-9]+$ ]] && [ "$(slice_line "$2" | grep -c . || true)" = 1 ] && return 0 ;;
  esac
  refuse "a packet with stage '$1' and unit '$2' names nothing on this card — a Codex run reviews the card (card/card), a slice on it (slice/S<n>) or the task (final/final)"
}
quota() { # $1 stage, $2 unit, $3 1 = --over-estimate, $4 quiet -> OVER=1 when the flag was needed
  local cap=3 used m a d ln
  case "$1" in
    card) cap=2 ;;
    slice) ln="$(slice_line "$2" | head -n 1)"; cap=0; if codex_yes "$ln"; then cap=2; fi ;;
  esac
  used="$(used_runs "$1" "$2")"; OVER=""
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
  echo "task-pair: codex run $(($(used_runs '' '') + 1)) for this task ($2: $((used + 1)) of $cap); consented: card 2 + $m codex: yes slice(s) x 2 + final 3 = $((2 * m + 5))"
}
# A failed review is not asked again at the same content (M2): change the
# content, or the human waives. The final's one rebuttal round is per
# content too — the final tree evidence.sh binds, not HEAD (a memory commit
# moves HEAD, not the tree) — and only a completed rebuttal run spends it (M3).
unit_tree() { # $1 stage, $2 unit -> the content a review of it binds to now
  if [ "$1" = card ]; then card_digest; else bash scripts/evidence.sh status --tree "$2" 2>/dev/null || true; fi
}
last_completed() { # $1 stage, $2 unit, $3 tree -> this task's latest completed Codex record of it there
  [ -f "$CODEX_LEDGER" ] || return 0
  A="\"lane\":\"codex-$1\",\"unit\":\"$2\",\"tree\":\"$3\",\"task\":\"$SLUG\"," \
    awk 'index($0, ENVIRON["A"]) && index($0, "\"run_state\":\"completed\"") {r = $0} END {if (r != "") print r}' "$CODEX_LEDGER"
}
review_gate() { # $1 stage, $2 unit, $3 non-empty for a rebuttal packet
  local t r f n=0 s
  t="$(unit_tree "$1" "$2")"
  [ -n "$t" ] || refuse "evidence.sh status --tree $2 failed — fix what bash scripts/evidence.sh status reports first"
  r="$(last_completed "$1" "$2" "$t")"
  if [ -n "$3" ]; then
    [ -n "$r" ] || refuse "a rebuttal answers a completed final review of this content (tree:${t:0:12}); there is none — run check final first"
    for f in "$PAIR_DIR"/*-final-rebuttal.md; do
      [ -f "$f" ] || continue
      s="$(hash_stdin < "$f" | awk '{print $1}')"
      if A="\"packet_sha\":\"$s\"" B="\"tree\":\"$t\"," awk 'index($0, ENVIRON["A"]) && index($0, ENVIRON["B"]) && index($0, "\"run_state\":\"completed\"") {f = 1} END {exit !f}' "$CODEX_LEDGER"; then
        n=$((n + 1))
      fi
    done
    [ "$n" = 0 ] || refuse "one rebuttal round per content (tree:${t:0:12}) — what is still open goes to the human"
  elif [ -n "$r" ] && { [ "$(rec_get "$r" verdict)" = fail ] || [ "$(rec_get "$r" critical)" != 0 ] || [ "$(rec_get "$r" high)" != 0 ]; }; then
    refuse "the latest completed $2 review at this content failed — change the content or ask the human to waive$([ "$1" != final ] || echo " (or put what you dispute to the judge once: check final --rebuttal FILE)")"
  fi
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
  local base_name seq stage unit base digest fp_before st s resp
  base_name="$(basename "$packet" .md)"
  seq="${base_name%%-*}"
  [[ "$seq" =~ ^[0-9]+$ ]] || die "packet name must start with a numeric seq: NNN-<stage>[-S<n>].md"
  stage="$(pk_field stage "$packet")"; unit="$(pk_field unit "$packet")"; base="$(pk_field base "$packet")"
  case "$stage" in card|slice|final) ;; *) stage="" ;; esac
  [ -n "$stage" ] && [ -n "$unit" ] && [ -n "$base" ] || die "packet needs 'stage: card|slice|final', 'unit:' and 'base:' lines"
  unit_check "$stage" "$unit"
  RESULT="${packet%.md}.result.md"
  [ ! -e "$RESULT" ] || die "result already exists: $RESULT (one packet, one run — run check again for a new packet)"
  # The base must be what the judge will actually see: HEAD, or the card now.
  if [[ "$base" =~ ^[0-9a-f]{7,40}$ ]]; then
    git -C "$ROOT" rev-parse HEAD 2>/dev/null | grep -q "^$base" \
      || refuse "packet base $base is not HEAD — stale packet; run check again for a new one"
  elif [ "${base#card:}" != "$base" ] && [ "$base" != "$(card_digest)" ]; then
    refuse "packet base $base is not the current card digest — stale packet; run check again for a new one"
  fi
  mk_evp
  quota "$stage" "$unit" "$over" ""
  [ -n "$PRECHECKED" ] || review_gate "$stage" "$unit" "$(pk_field rebuttal "$packet")"
  no_run_in_flight
  take_lock "$seq" "$stage" "$unit"
  ensure >/dev/null
  st="$(judge_status)"
  case "$st" in
    idle|done) ;;
    blocked) RC=4 die "the judge is blocked (an approval or a question in its pane) — answer it there, then retry" ;;
    *) s="$(inflight_seq)"
       if [ -n "$s" ] && [ -f "$EVP/fp-$s" ]; then RC=5 die "judge is '$st' — seq $s is in flight: run 'task-pair.sh wait $s' in the background"; fi
       RC=5 die "judge is '${st:-gone}' and no run of this task is in flight${s:+ (the last one started: seq $s)} — let it finish, or stop it in its pane, then retry" ;;
  esac
  # Every packet runs in a fresh thread (ADR-030): the judge's memory of
  # earlier stages is anchoring, not evidence — packets carry what it needs.
  fresh_thread "$seq"
  make_scratch "$seq"
  digest="$(hash_stdin < "$packet" | awk '{print $1}')"
  fp_before="$(fingerprint || echo nogit)"
  # The packet goes only into an empty composer: typed into a dialog, its
  # Enter answers the dialog and the text is lost.
  wait_composer >/dev/null || hand_over "the judge is not at an empty prompt — the packet was not sent"
  log_row "$seq" start "$stage" "$unit" "$base" "$digest" "timeout=${timeout}ms${OVER:+ over-estimate}"
  { echo "fp=$fp_before"; echo "t0=$(date +%s)"; echo "since=$(date -u +%Y-%m-%dT%H:%M:%S).000Z"
    echo "stage=$stage"; echo "unit=$unit"; } > "$EVP/fp-$seq"
  # Repo-relative paths (the judge runs in ROOT): no home path reaches its
  # screen or transcript from here (M5). One apply_patch write of the
  # result is what evidence.sh codex binds (C1).
  resp="$(herdr agent prompt "$NAME" \
    "Read and execute the packet at $packet; its paths are relative to the repository root, your working directory. It is frozen; do not edit it. Keep every temporary file under $SCRATCH. When finished, write your result to $RESULT once, with your file-edit tool (apply_patch) and not through a shell command, in the format the packet specifies, then reply with only that path." \
    --wait --timeout "$timeout" 2>&1)" || true
  settle "$seq" "$stage" "$unit" "$base" "$digest" "$packet" "$RESULT" "$resp"
}

# The seq of this task's run in flight: its fp file; else the last runlog
# start row without an end row (H2); nothing when there is none.
inflight_seq() {
  local f s=""
  for f in "$EVP"/fp-*; do [ -f "$f" ] && s="${f##*/fp-}"; done
  [ -n "$s" ] || s="$(awk -F'\t' '$3 == "start" {o[$2] = 1} $3 ~ /^end:/ {delete o[$2]} END {for (k in o) if (k > m) m = k; print m}' "$RUNLOG" 2>/dev/null || true)"
  echo "$s"
}

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
  fp_before="$(fp_get fp "$EVP/fp-$1")"
  code="$(printf '%s' "$resp" | jstr code)"
  case "$code" in
    timeout)
      log_row "$1" waiting "$2" "$3" "$4" "$5" "herdr timeout — run in the background: task-pair.sh wait $1"
      echo "task-pair: seq=$1 still running — run in the background: task-pair.sh wait $1"; exit 5 ;;
    agent_blocked) unsent 4 herdr_blocked "${@:1:7}" ;;   # herdr refused the prompt: nothing was typed (H1)
  esac
  st="$(printf '%s' "$resp" | jstr agent_status)"
  if [ -n "$code" ] || [ -z "$st" ]; then st="$(judge_status)"; fi
  case "$st" in
    working) reattach "$@" ;;
    blocked) parked "$@" ;;
  esac
  # herdr can report idle, or a stall, at once while nothing ran (the prompt
  # landed in a dialog; the turn starts late): only a turn that never shows
  # is not_started — whatever herdr's code said (H1).
  if [ ! -s "$7" ] && ! turn_started "$1" "$6"; then
    for _ in $(seq 1 "$START_GRACE_S"); do
      sleep "$POLL_S"
      case "$(judge_status)" in working) reattach "$@" ;; blocked) parked "$@" ;; esac
      turn_started "$1" "$6" && break
    done
    [ -s "$7" ] || turn_started "$1" "$6" || unsent 6 not_started "${@:1:7}"
  fi
  collect "$1" "$7" "$4" "${fp_before:-nogit}" "${st:-}" "$code"
  finish "$1" "$2" "$3" "$4" "$5" "$6" "$7" || exit $?
  exit 0
}
reattach() { settle "${@:1:7}" "$(herdr agent wait "$NAME" --timeout "$DEFAULT_TIMEOUT_MS" 2>&1 || true)"; }

# herdr says blocked mid-turn: the judge waits for the human (an approval, a
# question). Nothing has settled (H2): no record, the run stays in flight,
# and wait <seq> re-attaches once the human has answered.
parked() { # seq stage unit base digest packet result
  log_row "$1" blocked "$2" "$3" "$4" "$5" "the judge waits for the human — answer its pane, then: task-pair.sh wait $1"
  date -u +%Y-%m-%dT%H:%M:%SZ > "$EVP/parked-$1"
  echo "task-pair: seq=$1 the judge is blocked mid-run, waiting for you in its pane (an approval or a question):" >&2
  show_screen "$1-$2-blocked.screen.txt" local
  echo "task-pair: answer it there, then run in the background: task-pair.sh wait $1 — nothing is recorded until it settles, and no new check starts" >&2
  exit 4
}

# Did the packet reach the model? Either the token counters rose since the
# start row (a fall is the /new reset, never a turn: M1), or this run's
# Codex transcript exists (judge_rollout). Both fail only when nothing ran —
# or the pane hides the counters and CODEX_HOME is elsewhere.
turn_started() { # $1 seq, $2 packet
  local t0 t1 a0 b0 a1 b1
  t0="$(awk -F'\t' -v s="$1" '$2 == s && $3 == "start" {t = $9} END {print t}' "$RUNLOG" 2>/dev/null || true)"
  t1="$(judge_tokens)"
  if [[ "$t0" == */* && "$t1" == */* ]]; then
    a0="$(tok_n "${t0%/*}")"; b0="$(tok_n "${t0#*/}")"; a1="$(tok_n "${t1%/*}")"; b1="$(tok_n "${t1#*/}")"
    if [ -n "$a0" ] && [ -n "$b0" ] && [ -n "$a1" ] && [ -n "$b1" ] && { [ "$a1" -gt "$a0" ] || [ "$b1" -gt "$b0" ]; }; then return 0; fi
  fi
  [ "$(judge_rollout "$1" "$2")" != '?' ]
}
# A packet that never reached the model is not a Codex run: no record, no
# quota, no step toward `codex no verdict twice`; the not_started ledger
# keeps the attempt.
unsent() { # rc why seq stage unit base digest packet result
  local rc="$1" why="$2" f
  shift 2
  STATE=failed; REASON=not_started
  log_row "$1" end:failed "$2" "$3" "$4" "$5" "$why"
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" "$why" >> "$EVP/not_started"
  rm -f "$EVP/fp-$1"
  f="$(save_screen "$1-$2.screen.txt")"
  case "$SCRATCH" in /tmp/pair-*/*) rm -rf "$SCRATCH"; rmdir "${SCRATCH%/*}" 2>/dev/null || true ;; esac
  if [ "$why" = herdr_blocked ]; then
    echo "task-pair: herdr did not submit the packet — the judge is blocked (an approval or a question in its pane); not recorded, not counted against the quota. Answer it there, then run check again." >&2
  else
    echo "task-pair: the packet never reached the model (no result, token counters did not rise, no Codex transcript of it) — not recorded, not counted against the quota; the screen is in $f. Look at the judge pane, then run check again." >&2
  fi
  echo "task-pair: seq=$1 stage=$2 unit=$3 state=failed ($why) result=$7 record=none"
  exit "$rc"
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
  [[ "$seq" =~ ^[0-9]+$ ]] || die "wait: <seq> is the number a packet's name starts with"
  resolve_task
  local packet f stage unit base digest resp
  packet=""
  for f in "$PAIR_DIR/$seq"-*.md; do
    case "$f" in *.result.md) ;; *) [ -f "$f" ] && { packet="$f"; break; } ;; esac
  done
  [ -n "$packet" ] || die "no packet with seq $seq under $PAIR_DIR"
  stage="$(pk_field stage "$packet")"; unit="$(pk_field unit "$packet")"; base="$(pk_field base "$packet")"
  RESULT="${packet%.md}.result.md"; SCRATCH="/tmp/pair-$REPO_ID-$SAFE_SLUG/$seq"
  if [ -f "$EVP/unrecorded-$seq" ]; then   # settled, its record failed (M8): record it now, the judge is not asked again
    need_guard; take_lock "$seq" "$stage" "$unit"
    record_run "$seq" "$stage" "$unit" "$packet" "$RESULT" "$EVP/unrecorded-$seq" || exit $?
    exit 0
  fi
  [ -f "$EVP/fp-$seq" ] || die "seq $seq has no run in flight"
  require_herdr
  digest="$(hash_stdin < "$packet" | awk '{print $1}')"
  need_guard; take_lock "$seq" "$stage" "$unit"
  rm -f "$EVP/parked-$seq"
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
    b="${f##*/}"; b=$((10#${b%%-*}))
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
  local stage="${1:-}" unit="" since="" rebuttal="" base head ln="" lanes="" x l f seq file scratch s
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
      # done refuses a slice whose lanes are not fresh: a Codex check before
      # that is spent twice (L4).
      x="$(bash scripts/evidence.sh status 2>/dev/null || true)"
      for l in $(printf '%s' "$lanes" | tr ',' ' '); do
        s="$(sed -n "s/^lane $l: \([a-z]*\).*/\1/p" <<<"$x" | head -n 1)"
        [ "$s" = fresh ] || refuse "lane $l is ${s:-not in evidence.sh status} — run it first (bash scripts/evidence.sh run $l): done refuses a slice whose lanes are not fresh, so a Codex check now would be spent twice"
      done
      base="$head" ;;
    final)
      # close refuses while a slice is not [x]: the final check judges the finished task (L4).
      x="$(sed -nE 's/^- \[([ ~o])\] (S[0-9]+) .*/\2 [\1]/p' "$CARD" | tr '\n' ' ')"
      [ -z "$x" ] || refuse "the final check judges the finished task — not done yet: ${x% } (evidence.sh done each slice first)"
      x="$(sed -nE 's/^<!-- card v4 .* base: ([0-9a-f]+) .*/\1/p' "$CARD" | head -n 1)"
      [ -n "$x" ] || refuse "the card header has no base: — fix the card (evidence.sh lint)"
      x="$(git rev-parse -q --verify "$x^{commit}" || true)"
      since="$(since_ok "$since" "$x" "the card's base:")"
      x="$(git status --porcelain -- . ':(exclude).ai_context' 2>&1 || true)"
      [ -z "$x" ] || refuse "the final check judges committed work — commit first (changes outside .ai_context/):"$'\n'"$(printf '%s\n' "$x" | head -n 5 | indent)"
      [ -z "$rebuttal" ] || [ -f "$rebuttal" ] || die "packet: rebuttal file not found: $rebuttal"
      body="$(bash scripts/evidence.sh status 2>&1 || true)"
      base="$head" ;;
  esac
  review_gate "$stage" "$unit" "$rebuttal"
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
# Rebuttal round (one per content)
The findings below were raised on this same content — by the Claude checker, or as the
orchestrator's dispute of your previous result, each dispute with its command and output. For
EACH: reproduce it (command + output) or refute it (command + output). One you can neither
reproduce nor refute stays open at its original severity. Your result replaces the previous
final result for this content.

EOF
  sed 's/^/> /' "$rebuttal"
  echo
}

pk_contract() {
  printf '# Result contract\nWrite %s (relative to the repository root, your working directory) once, with your\n' "${file%.md}.result.md"
  cat <<'EOF'
file-edit tool (apply_patch, `*** Add File:`) — never through a shell command, never edited afterwards:
the record binds your result to that write in your Codex transcript; written any other way it approves
nothing. Its first six lines must be exactly these, in this order, with nothing before them:
EOF
  printf 'run: completed|failed|blocked\nverdict: pass|fail|inconclusive\n'
  printf 'base: %s\nblocker: <count>\nmajor: <count>\nminor: <count>\n' "$base"
  cat <<'EOF'
run: completed = you carried out this packet; failed or blocked = you could not (say why below).
Counts are integers, 0 when none: each is the number of finding lines of that severity below.
Then a blank line, the findings, one line each — `<n>. <blocker|major|minor> — <check id> — <what is
wrong> — <command + output, or file:line> — <fix>` —, then (slice) the claim lines, then the commands
you ran. When done, reply with only the result path.
EOF
}

# --- fresh judge context (a slash command, no model turn) --------------------
# `/new` to the judge, then wait until it visibly took effect (M1): a screen
# with a conversation on it changes (the transcript clears, the counters
# reset) or the picker opens — a packet typed while /new is still opening is
# lost. Codex 0.165.0 first asks where the new conversation runs; the one
# answer given here is enter on the highlighted "1. Use current Git
# worktree", to an idle judge (H3). Any other screen is the human's: the
# packet is never typed into a dialog. $1 = seq to attribute the runlog row to.
fresh_thread() {
  local seq="$1" s s0 picked=0 conv=0 n=0
  clear_modals
  s0="$(wait_composer)" || hand_over "the judge is not at an empty prompt — /new was not sent"
  if grep -qE '^(• |› )' <<<"$(grep -vE "^[[:space:]]*$EMPTY_COMPOSER" <<<"$s0" || true)" ||
     [[ "$(tokens_of "$s0")" =~ [1-9] ]]; then conv=1; fi
  herdr agent prompt "$NAME" "/new" >/dev/null 2>&1 || hand_over "sending /new to the judge failed — the packet was not sent"
  # Looked at four times a second (NEW_POLL_S); a screen with no conversation
  # on it cannot show the change, so it is taken only after a full second.
  while [ "$n" -lt $((NEW_WAIT_S * 4)) ]; do
    sleep "$NEW_POLL_S"; n=$((n + 1))
    s="$(screen 40)"
    if [ "$(modal_label "$s" || true)" = new-thread-picker ]; then
      if [ "$picked" = 0 ]; then   # once; then wait for it to close
        grep -qE '^[[:space:]]*› 1\. Use current Git worktree' <<<"$(dialog_block "$s")" ||
          hand_over "the judge's new-thread picker has another choice highlighted — the packet was not sent"
        case "$(judge_status)" in idle|done) ;; *) hand_over "the judge is not idle while its new-thread picker is open — the packet was not sent" ;; esac
        herdr agent send-keys "$NAME" enter >/dev/null 2>&1 || hand_over "could not answer the new-thread picker"
        picked=1
      fi
    elif composer_ready "$s" && { [ "$picked" = 1 ] || [ "$s" != "$s0" ] || { [ "$conv" = 0 ] && [ "$n" -ge 4 ]; }; }; then
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
    unit_check "${a[0]}" "$unit"; mk_evp
    quota "${a[0]}" "$unit" "$over" quiet
  fi
  pk="$(packet ${a[@]+"${a[@]}"})" || exit $?
  echo "task-pair: packet $pk"
  PRECHECKED=1   # packet ran review_gate
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
