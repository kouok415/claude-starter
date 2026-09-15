#!/usr/bin/env bash
# task-pair.sh — drive the Codex judge pane of a `pair-codex` /task over herdr.
#
# The pen for the pair protocol (workshop ADR-028): the skill decides WHAT to
# ask, this script does the asking deterministically. Files are the contract
# (`tasks/<slug>/pair/NNN-<role>[-M<n>].md` packet in, `.result.md` out);
# herdr only starts the agent, submits the prompt, waits, and reports
# `blocked`. Four events are recorded separately and never inferred from
# one another: the herdr state, the result file's existence, the verdict
# the judge wrote, and the verify the gate runs. This script NEVER prints a
# verdict of its own — `run_state` is the only thing it decides.
#
#   ensure                  find or start the judge (idempotent)
#   send <packet> [--timeout MS]
#                           submit one packet, wait, collect, log
#   wait <seq>  [--timeout MS]
#                           keep waiting for an in-flight run (Bash tool caps
#                           a single call; chain these)
#   status                  runlog summary
#   fingerprint             print the tree fingerprint (test seam)
#
# Exit codes: 0 run completed (verdict is in the result file, not here);
# 2 usage; 3 refused (wrong profile / no herdr / hooks live / untrusted);
# 4 judge needs the human (blocked, modal dialog); 5 judge busy;
# 6 run ended without a usable result (no_result, bad_header, base_mismatch,
# tree_changed, timed_out, stalled).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
DEFAULT_TIMEOUT_MS=540000   # under the 600 s cap of one orchestrator tool call
START_TIMEOUT_MS=60000
TAB="$(printf '\t')"

die() { echo "task-pair: $*" >&2; exit "${RC:-2}"; }
refuse() { RC=3 die "$@"; }

# --- JSON helpers (herdr prints compact JSON; no jq in the template) -------
jstr() { # $1 = key -> first string value of that key on stdin
  sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
}
jint() { # $1 = key -> first integer value of that key on stdin
  sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" | head -1
}

hash_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256
  else cksum
  fi
}

# Same recipe as stop-gate.sh fingerprint() — HEAD + status + diff + untracked
# content — minus the task's pair/ dir, which is the judge's own mailbox
# (packets, results, runlog land there by design). A judge that touched
# anything else voids its own verdict.
fingerprint() {
  git -C "$ROOT" rev-parse HEAD >/dev/null 2>&1 || return 1
  local ex=""
  [ -n "${PAIR_DIR:-}" ] && ex=":(exclude)$PAIR_DIR"
  {
    git -C "$ROOT" rev-parse HEAD
    git -C "$ROOT" status --porcelain -- . ${ex:+"$ex"}
    git -C "$ROOT" diff HEAD -- . ${ex:+"$ex"}
    git -C "$ROOT" ls-files -o --exclude-standard -- . ${ex:+"$ex"} | while IFS= read -r uf; do
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

# --- Task + profile resolution -----------------------------------------------
SLUG=""; TASK=""; PAIR_DIR=""; RUNLOG=""; JUDGE_FILE=""; NAME=""
resolve_task() {
  [ -f .ai_context/tasks/CURRENT ] || refuse "no active task (.ai_context/tasks/CURRENT missing)"
  SLUG="$(tr -d '[:space:]' < .ai_context/tasks/CURRENT)"
  TASK=".ai_context/tasks/$SLUG"
  [ -f "$TASK/plan.md" ] || refuse "$TASK/plan.md missing — pair runs start after the plan header exists"
  local prof
  prof="$(sed -n 's/^<!-- profile: \([a-z-]*\).*/\1/p' "$TASK/plan.md" | head -1)"
  case "$prof" in
    pair-*) ;;
    *) refuse "active profile is '${prof:-none}', not pair-* — run /task --profile=pair-codex (task-profile.sh apply pair-codex)" ;;
  esac
  PAIR_DIR="$TASK/pair"; RUNLOG="$PAIR_DIR/runlog"; JUDGE_FILE="$PAIR_DIR/judge"
  mkdir -p "$PAIR_DIR"
  # herdr agent names: [a-z][a-z0-9_-]{0,31}, unique per server.
  NAME="$(printf 'judge-%s' "$SLUG" | tr -c 'a-z0-9_\n-' '-' | cut -c1-32)"
}

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

# --- Screen inspection -----------------------------------------------------
screen() { herdr agent read "$NAME" --source visible --lines "${1:-40}" 2>/dev/null || true; }

# Returns 0 and prints a label when a modal dialog is on screen.
modal_on_screen() {
  local s; s="$(screen 40)"
  if printf '%s' "$s" | grep -q 'Do you trust the contents of this directory'; then echo trust; return 0; fi
  if printf '%s' "$s" | grep -qE 'Switch to gpt-|Approaching rate limits'; then echo rate-limit; return 0; fi
  if printf '%s' "$s" | grep -qE 'Press enter to confirm|Press enter to continue'; then echo unknown-dialog; return 0; fi
  return 1
}

# Dismiss what is safe to dismiss (the rate-limit nudge: esc keeps the
# current model); everything else is the human's.
clear_modals() {
  local m
  m="$(modal_on_screen || true)"
  [ -z "$m" ] && return 0
  if [ "$m" = rate-limit ]; then
    herdr agent send-keys "$NAME" esc >/dev/null 2>&1 || true
    sleep 1
    m="$(modal_on_screen || true)"
    [ -z "$m" ] && return 0
  fi
  echo "task-pair: judge shows a '$m' dialog — answer it in the pane, then retry:" >&2
  screen 12 | sed 's/^/    /' >&2
  RC=4 die "human input required"
}

# Model + effort from the Codex status line ("<model> <effort> · <cwd> · …").
# Observed, never assumed: Codex can switch its own model under rate
# pressure, so every runlog row re-reads it. '?' when the line is not there.
judge_model() {
  local m
  m="$(screen 40 | sed -n 's/^[[:space:]]*\([a-z0-9._-]*\) \([a-z]*\) · .*/\1 \2/p' | tail -1)"
  echo "${m:-?}"
}

judge_status() { herdr agent get "$NAME" 2>/dev/null | jstr agent_status || true; }

# --- runlog: append-only, tab-separated ----------------------------------
# ts  seq  event  role  milestone  base  digest  model  detail
log_row() { # seq event role milestone base digest model detail
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$@" >> "$RUNLOG"
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
  resolve_task; require_herdr; trust_check
  local st pane_id resp
  st="$(judge_status)"
  if [ -n "$st" ]; then
    hooks_tripwire
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
  # CLAUDE.md as the project doc (no AGENTS.md shipped).
  resp="$(herdr agent start "$NAME" --kind codex --pane "$pane_id" --timeout "$START_TIMEOUT_MS" -- \
            -s workspace-write -c features.hooks=false \
            -c 'project_doc_fallback_filenames=["CLAUDE.md"]' 2>&1)" || true
  case "$(printf '%s' "$resp" | jstr type)" in
    agent_started) ;;
    *)
      if printf '%s' "$resp" | grep -q agent_not_ready; then
        echo "task-pair: judge started but is not ready — pane $pane_id:" >&2
        herdr pane read "$pane_id" --source visible --lines 12 2>/dev/null | sed 's/^/    /' >&2 || true
        RC=4 die "human input required"
      fi
      refuse "agent start failed: $resp" ;;
  esac
  {
    echo "name=$NAME"; echo "pane_id=$pane_id"; echo "hooks_off=1"
    echo "started=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$JUDGE_FILE"
  sleep 1
  clear_modals
  echo "task-pair: judge '$NAME' started in $pane_id — $(judge_model)"
}

# --- packet / result ----------------------------------------------------------
pk_field() { sed -n "s/^$1:[[:space:]]*//p" "$2" | head -1; }

# Result contract: first lines carry run/verdict/base. Missing or malformed
# fields are `bad_header`, never a pass.
check_result() { # $1 result path, $2 packet base -> prints reason or nothing
  local run verdict base
  [ -s "$1" ] || { echo no_result; return; }
  run="$(pk_field run "$1")"; verdict="$(pk_field verdict "$1")"; base="$(pk_field base "$1")"
  case "$run" in completed|failed|blocked) ;; *) echo bad_header; return ;; esac
  case "$verdict" in pass|fail|inconclusive) ;; *) echo bad_header; return ;; esac
  [ -n "$base" ] || { echo bad_header; return; }
  [ "$base" = "$2" ] || { echo base_mismatch; return; }
}

# Collect after herdr reports a settled state. Sets STATE and REASON.
STATE=""; REASON=""
collect() { # $1 packet, $2 result, $3 base, $4 fp_before, $5 herdr status
  local r fp_after
  case "$5" in
    blocked) STATE=blocked; REASON=herdr_blocked; return ;;
    idle|done) ;;
    *) STATE=failed; REASON="herdr_$5"; return ;;
  esac
  r="$(check_result "$2" "$3")"
  if [ -n "$r" ]; then STATE=failed; REASON="$r"; return; fi
  fp_after="$(fingerprint || echo nogit)"
  if [ "$fp_after" != "$4" ]; then STATE=failed; REASON=tree_changed; return; fi
  STATE=completed; REASON="verdict=$(pk_field verdict "$2")"
}

finish() { # seq role milestone base digest packet result
  local m
  rm -f "$PAIR_DIR/.fp-$1"
  log_row "$1" "end:$STATE" "$2" "$3" "$4" "$5" "$(judge_model)" "$REASON"
  # Post-run dialog sweep: the rate-limit nudge is dismissed (esc keeps the
  # model); anything else is reported, not answered — the run itself is
  # already settled, so this never changes STATE.
  m="$(modal_on_screen || true)"
  if [ "$m" = rate-limit ]; then
    herdr agent send-keys "$NAME" esc >/dev/null 2>&1 || true; sleep 1; m="$(modal_on_screen || true)"
  fi
  [ -z "$m" ] || echo "task-pair: WARNING judge shows a '$m' dialog — answer it in the pane before the next send" >&2
  echo "task-pair: seq=$1 role=$2 state=$STATE ($REASON) result=$7"
  case "$STATE" in
    completed) return 0 ;;
    blocked) return 4 ;;
    *) return 6 ;;
  esac
}

send() {
  local packet="$1" timeout="$DEFAULT_TIMEOUT_MS"
  shift
  while [ $# -gt 0 ]; do
    case "$1" in --timeout) timeout="$2"; shift 2 ;; *) die "send: unknown option $1" ;; esac
  done
  resolve_task
  packet="${packet#"$ROOT"/}"
  [ -f "$packet" ] || die "packet not found: $packet"
  case "$packet" in "$PAIR_DIR"/*) ;; *) die "packet must live under $PAIR_DIR" ;; esac
  local base_name seq role milestone base result digest fp_before abs_packet abs_result st resp
  base_name="$(basename "$packet" .md)"
  seq="${base_name%%-*}"
  [[ "$seq" =~ ^[0-9]+$ ]] || die "packet name must start with a numeric seq: NNN-<role>[-M<n>].md"
  role="$(pk_field role "$packet")"; milestone="$(pk_field milestone "$packet")"; base="$(pk_field base "$packet")"
  [ -n "$role" ] && [ -n "$base" ] || die "packet needs 'role:' and 'base:' lines"
  result="${packet%.md}.result.md"
  [ ! -e "$result" ] || die "result already exists: $result (one packet, one run — write a new packet)"
  # A commit-shaped base must be the tree the judge will actually see.
  if [[ "$base" =~ ^[0-9a-f]{7,40}$ ]]; then
    git -C "$ROOT" rev-parse HEAD 2>/dev/null | grep -q "^$base" \
      || RC=6 die "packet base $base is not HEAD — stale packet"
  fi
  ensure >/dev/null
  st="$(judge_status)"
  case "$st" in
    idle|done) ;;
    blocked) clear_modals; RC=4 die "judge is blocked — inspect the pane" ;;
    *) RC=5 die "judge is '$st' — a run is in flight; use wait" ;;
  esac
  digest="$(hash_stdin < "$packet" | awk '{print $1}')"
  fp_before="$(fingerprint || echo nogit)"
  abs_packet="$ROOT/$packet"; abs_result="$ROOT/$result"
  log_row "$seq" start "$role" "${milestone:--}" "$base" "$digest" "$(judge_model)" "timeout=${timeout}ms"
  printf '%s\n' "$fp_before" > "$PAIR_DIR/.fp-$seq"
  resp="$(herdr agent prompt "$NAME" \
    "Read and execute the packet at $abs_packet. It is frozen; do not edit it. When finished, write your result to $abs_result in the format the packet specifies, then reply with only that path." \
    --wait --timeout "$timeout" 2>&1)" || true
  settle "$seq" "$role" "${milestone:--}" "$base" "$digest" "$packet" "$result" "$resp"
}

settle() { # seq role milestone base digest packet result herdr_response
  local resp="$8" code st fp_before
  fp_before="$(cat "$PAIR_DIR/.fp-$1" 2>/dev/null || echo nogit)"
  code="$(printf '%s' "$resp" | jstr code)"
  case "$code" in
    timeout)
      log_row "$1" waiting "$2" "$3" "$4" "$5" "$(judge_model)" "herdr timeout — chain: task-pair.sh wait $1"
      echo "task-pair: seq=$1 still running — run: task-pair.sh wait $1"; exit 5 ;;
    agent_prompt_stalled) STATE=failed; REASON=stalled; finish "$1" "$2" "$3" "$4" "$5" "$6" "$7"; exit $? ;;
    agent_blocked) STATE=blocked; REASON=herdr_blocked; finish "$1" "$2" "$3" "$4" "$5" "$6" "$7"; exit $? ;;
    "") ;;
    *) STATE=failed; REASON="herdr_$code"; finish "$1" "$2" "$3" "$4" "$5" "$6" "$7"; exit $? ;;
  esac
  st="$(printf '%s' "$resp" | jstr agent_status)"
  [ -n "$st" ] || st="$(judge_status)"
  collect "$6" "$7" "$4" "$fp_before" "${st:-unknown}"
  finish "$1" "$2" "$3" "$4" "$5" "$6" "$7"; exit $?
}

wait_run() {
  local seq="$1" timeout="$DEFAULT_TIMEOUT_MS"; shift
  while [ $# -gt 0 ]; do
    case "$1" in --timeout) timeout="$2"; shift 2 ;; *) die "wait: unknown option $1" ;; esac
  done
  resolve_task; require_herdr
  local packet f role milestone base digest result resp
  packet=""
  for f in "$PAIR_DIR/$seq"-*.md; do
    case "$f" in *.result.md) ;; *) [ -f "$f" ] && { packet="$f"; break; } ;; esac
  done
  [ -n "$packet" ] || die "no packet with seq $seq under $PAIR_DIR"
  [ -f "$PAIR_DIR/.fp-$seq" ] || die "seq $seq has no run in flight"
  role="$(pk_field role "$packet")"; milestone="$(pk_field milestone "$packet")"; base="$(pk_field base "$packet")"
  digest="$(hash_stdin < "$packet" | awk '{print $1}')"
  result="${packet%.md}.result.md"
  resp="$(herdr agent wait "$NAME" --timeout "$timeout" 2>&1)" || true
  settle "$seq" "$role" "${milestone:--}" "$base" "$digest" "$packet" "$result" "$resp"
}

status() {
  resolve_task
  [ -f "$JUDGE_FILE" ] && sed 's/^/judge: /' "$JUDGE_FILE"
  [ -f "$RUNLOG" ] || { echo "runlog: empty"; return 0; }
  awk -F"$TAB" '
    $3 == "start" { role[$2] = $4; ms[$2] = $5; last[$2] = "running"; n[$2] = 1 }
    $3 ~ /^end:/ { last[$2] = substr($3, 5) " " $9 }
    $3 == "waiting" { last[$2] = "waiting" }
    END { for (s in n) printf "seq %s  %s %s  -> %s\n", s, role[s], ms[s], last[s] }' "$RUNLOG" | sort
}

cmd="${1:-}"
[ $# -gt 0 ] && shift
case "$cmd" in
  ensure) ensure ;;
  send) [ -n "${1:-}" ] || die "usage: task-pair.sh send <packet> [--timeout MS]"; send "$@" ;;
  wait) [ -n "${1:-}" ] || die "usage: task-pair.sh wait <seq> [--timeout MS]"; wait_run "$@" ;;
  status) status ;;
  fingerprint)
    s="$(tr -d '[:space:]' < .ai_context/tasks/CURRENT 2>/dev/null || true)"
    [ -n "$s" ] && PAIR_DIR=".ai_context/tasks/$s/pair"
    fingerprint ;;
  *) echo "Usage: task-pair.sh <ensure|send <packet>|wait <seq>|status|fingerprint>" >&2; exit 2 ;;
esac
