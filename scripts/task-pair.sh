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
#   packet <role> <M<n>|-> [--mode light|full|drift] [--lens L]
#                          [--changed a,b] [--since REF] [--rebuttal FILE]
#                          [--budget TEXT] [--candidate FILE] [--round N]
#                           write the next packet (header + frozen inputs +
#                           result contract) and print its path
#   digest <file>           `plan:<sha256>` of a frozen plan candidate — the
#                           version a critic pass is bound to
#   send <packet> [--timeout MS]
#                           `/new` the judge, submit one packet, wait,
#                           collect, log — every packet runs in a fresh
#                           thread (ADR-030)
#   wait <seq>  [--timeout MS]
#                           keep waiting for an in-flight run (Bash tool caps
#                           a single call; chain these)
#   reset                   `/new` by hand — send does it before every packet
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
  dump_screen "dialog-$(date -u +%Y%m%dT%H%M%SZ).screen.txt"
  RC=4 die "human input required"
}

# Model + effort from the Codex status line ("<model> <effort> · <cwd> ·
# … · <n> in · <n> out · …"). Observed, never assumed: Codex can switch its
# own model under rate pressure, so every runlog row re-reads it. '?' when
# the line is not there.
judge_model() {
  local m
  m="$(screen 40 | sed -n 's/^[[:space:]]*\([a-z0-9._-]*\) \([a-z]*\) · .*/\1 \2/p' | tail -1)"
  echo "${m:-?}"
}
# Cumulative session token counters from the same line ("12.3k/4.1k");
# the difference between two runlog rows is what one run cost.
judge_tokens() {
  local t
  t="$(screen 40 | sed -n 's/.*· \([0-9.]*[kKmM]\{0,1\}\) in · \([0-9.]*[kKmM]\{0,1\}\) out.*/\1\/\2/p' | tail -1)"
  echo "${t:-?}"
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

# --- runlog: append-only, tab-separated ----------------------------------
# ts  seq  event  role  milestone  base  digest  model  tokens  rollout  detail
# model/tokens/rollout are observed at write time — a run's cost is the
# token delta between its start and end rows; rollout is the judge's own
# transcript for that run.
log_row() { # seq event role milestone base digest detail
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$1" "$2" "$3" "$4" "$5" "$6" "$(judge_model)" "$(judge_tokens)" "$(judge_rollout)" "$7" >> "$RUNLOG"
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
  # CLAUDE.md as the project doc (no AGENTS.md shipped). `started` is taken
  # BEFORE the start so the judge's rollout (created at startup) sorts after it.
  local started; started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  resp="$(herdr agent start "$NAME" --kind codex --pane "$pane_id" --timeout "$START_TIMEOUT_MS" -- \
            -s workspace-write -c features.hooks=false \
            -c 'project_doc_fallback_filenames=["CLAUDE.md"]' 2>&1)" || true
  case "$(printf '%s' "$resp" | jstr type)" in
    agent_started) ;;
    *)
      if printf '%s' "$resp" | grep -q agent_not_ready; then
        echo "task-pair: judge started but is not ready — pane $pane_id:" >&2
        herdr pane read "$pane_id" --source visible --lines 12 2>/dev/null | sed 's/^/    /' >&2 || true
        herdr pane read "$pane_id" --source visible --lines 80 > "$PAIR_DIR/start-$(date -u +%Y%m%dT%H%M%SZ).screen.txt" 2>/dev/null || true
        RC=4 die "human input required"
      fi
      refuse "agent start failed: $resp" ;;
  esac
  {
    echo "name=$NAME"; echo "pane_id=$pane_id"; echo "hooks_off=1"
    echo "started=$started"
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
  log_row "$1" "end:$STATE" "$2" "$3" "$4" "$5" "$REASON"
  [ "$STATE" = completed ] || dump_screen "$1-$2.screen.txt"
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
  # Every packet runs in a fresh thread (ADR-030): the judge's memory of
  # earlier stages is anchoring, not evidence — packets carry what it needs.
  fresh_thread "$seq"
  digest="$(hash_stdin < "$packet" | awk '{print $1}')"
  fp_before="$(fingerprint || echo nogit)"
  abs_packet="$ROOT/$packet"; abs_result="$ROOT/$result"
  log_row "$seq" start "$role" "${milestone:--}" "$base" "$digest" "timeout=${timeout}ms"
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
      log_row "$1" waiting "$2" "$3" "$4" "$5" "herdr timeout — chain: task-pair.sh wait $1"
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

# --- packet: the orchestrator's inputs, frozen by a script not by memory ---
# What the judge needs is always the same shape; writing it by hand is the
# silent-degradation class (a forgotten line = a weaker check). The roles
# accepted here are the ones wired so far; each addition documents its
# stage in pair.md.
next_seq() {
  local n=0 f b
  for f in "$PAIR_DIR"/[0-9][0-9][0-9]-*.md; do
    [ -f "$f" ] || continue
    b="$(basename "$f")"; b=$((10#${b%%-*}))
    [ "$b" -gt "$n" ] && n="$b"
  done
  printf '%03d' $((n + 1))
}

milestone_section() { # $1 = M<n> -> the full section from plan.md
  awk -v want="## $1:" '
    index($0, want) == 1 { take = 1; print; next }
    take && /^## / { exit }
    take { print }' "$TASK/plan.md"
}

acceptance_criteria() { grep -E '^- \[[ x]\] AC' "$TASK/spec.md" 2>/dev/null || true; }

PLAN_ROUND_CAP=10   # user ruling (ADR-028): past this the ledger goes to the human
DEFAULT_BUDGET="the milestone budget of the active profile (reference.md, Profiles); if unsure assume <=15 tool calls per fresh executor context"

file_digest() { printf '%s:%s' "$1" "$(hash_stdin < "$2" | awk '{print $1}')"; }

# The plan.md format the Stop gate parses — inlined into planner packets so
# a Codex candidate is gate-parseable on arrival.
plan_format() {
  cat <<'FMT'
    # Plan: <title>
    <!-- profile: pair-codex ; size: S | M | L -->
    <!-- statuses: [pending] [in_progress] [done]; exactly one in_progress -->

    ## M1: <milestone title> [pending]
    - verify: `<command that fails today and passes when this milestone is done>`
    - risk: low | med | high
    - demo: <the verify translated for the human: "run X, you will see Y">
FMT
}

packet() {
  local role="${1:-}" ms="${2:-}" mode="" lens="" changed="" since="" rebuttal="" budget="" candidate="" round=""
  [ -n "$role" ] && [ -n "$ms" ] || die "usage: task-pair.sh packet <role> <M<n>|-> [--mode light|full|drift] [--lens L] [--changed a,b] [--since REF] [--rebuttal FILE] [--budget TEXT] [--candidate FILE] [--round N]"
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --mode) mode="$2"; shift 2 ;;
      --lens) lens="$2"; shift 2 ;;
      --changed) changed="$2"; shift 2 ;;
      --since) since="$2"; shift 2 ;;
      --rebuttal) rebuttal="$2"; shift 2 ;;
      --budget) budget="$2"; shift 2 ;;
      --candidate) candidate="$2"; shift 2 ;;
      --round) round="$2"; shift 2 ;;
      *) die "packet: unknown option $1" ;;
    esac
  done
  resolve_task
  case "$role" in
    verifier|final-verifier|planner|plan-critic)
      [ -f "$ROOT/.claude/agents/$role.md" ] || die "packet: no role contract at .claude/agents/$role.md" ;;
    spec-critic|brief-audit) ;;   # Codex-only seats: the contract is inlined below (this script is its single source)
    *) die "packet: role '$role' is not wired for pair mode yet (verifier, final-verifier, planner, plan-critic, spec-critic, brief-audit)" ;;
  esac
  local base seq file abs
  base="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)" || die "packet: not a git repo with a HEAD"
  case "$role" in
    planner)
      # Plan-stage packets bind to the SPEC version, not a commit: the plan
      # is being written, nothing is committed yet.
      [ "$ms" = "-" ] || die "packet: planner takes '-' as milestone"
      [ -n "$lens" ] || die "packet: planner needs --lens <strategic lens>"
      [ -z "$mode$changed$since$rebuttal$candidate$round" ] || die "packet: planner accepts only --lens and --budget"
      [ -f "$TASK/spec.md" ] || die "packet: $TASK/spec.md missing"
      base="$(file_digest spec "$TASK/spec.md")" ;;
    spec-critic)
      [ "$ms" = "-" ] || die "packet: spec-critic takes '-' as milestone"
      [ -z "$mode$changed$since$rebuttal$candidate$round$lens$budget" ] || die "packet: spec-critic takes no options"
      [ -f "$TASK/spec.md" ] || die "packet: $TASK/spec.md missing"
      base="$(file_digest spec "$TASK/spec.md")" ;;
    brief-audit)
      [ "$ms" = "-" ] || die "packet: brief-audit takes '-' as milestone"
      [ -z "$mode$changed$since$rebuttal$candidate$round$lens$budget" ] || die "packet: brief-audit takes no options"
      [ -f "$TASK/brief.md" ] || die "packet: $TASK/brief.md missing (the scout writes it first)"
      base="$(file_digest brief "$TASK/brief.md")" ;;
    plan-critic)
      [ "$ms" = "-" ] || die "packet: plan-critic takes '-' as milestone"
      [ -n "$candidate" ] || die "packet: plan-critic needs --candidate <frozen plan file>"
      [ -f "$candidate" ] || die "packet: candidate not found: $candidate"
      [ -n "$round" ] || die "packet: plan-critic needs --round N (1..$PLAN_ROUND_CAP)"
      [[ "$round" =~ ^[0-9]+$ ]] && [ "$round" -ge 1 ] || die "packet: --round must be a positive integer"
      [ "$round" -le "$PLAN_ROUND_CAP" ] || RC=6 die "packet: plan round cap $PLAN_ROUND_CAP reached — the loop stops here; hand the open ledger rows to the human (kickoff brief)"
      [ -z "$mode$changed$since$rebuttal$lens" ] || die "packet: plan-critic accepts only --candidate, --round and --budget"
      base="$(file_digest plan "$candidate")" ;;
    verifier)
      [ "$ms" != "-" ] || die "packet: verifier needs a milestone id (M<n>)"
      [ -n "$mode" ] || mode=light
      case "$mode" in light|full|drift) ;; *) die "packet: verifier --mode is light|full|drift" ;; esac
      [ -z "$lens" ] || die "packet: --lens is for final-verifier"
      [ -n "$(milestone_section "$ms")" ] || die "packet: milestone $ms not found in plan.md"
      [ "$mode" != light ] || [ -n "$changed" ] || die "packet: light mode needs --changed <files>"
      [ "$mode" != drift ] || [ -n "$since" ] || die "packet: drift mode needs --since <commit>" ;;
    final-verifier)
      [ "$ms" = "-" ] || die "packet: final-verifier takes '-' as milestone (whole task)"
      [ -z "$mode" ] || die "packet: --mode is for verifier"
      case "$lens" in correctness|regression|test-integrity) ;; *) die "packet: final-verifier --lens is correctness|regression|test-integrity" ;; esac
      [ -n "$since" ] || die "packet: final-verifier needs --since <task base commit> (e.g. git merge-base main task/<slug>)" ;;
  esac
  [ -z "$rebuttal" ] || [ -f "$rebuttal" ] || die "packet: rebuttal file not found: $rebuttal"
  seq="$(next_seq)"
  file="$PAIR_DIR/$seq-$role"
  [ "$ms" = "-" ] || file="$file-$ms"
  [ -z "$lens" ] || file="$file-$lens"
  [ -z "$round" ] || file="$file-r$round"
  [ -z "$rebuttal" ] || file="$file-rebuttal"
  file="$file.md"
  abs="$ROOT/$file"
  {
    printf 'role: %s\nmilestone: %s\nbase: %s\n' "$role" "$ms" "$base"
    [ -z "$mode" ] || printf 'mode: %s\n' "$mode"
    [ -z "$lens" ] || printf 'lens: %s\n' "$lens"
    [ -z "$round" ] || printf 'round: %s\n' "$round"
    printf '\n# Task\n'
    printf 'You are the %s for the active /task in this repo (%s).\n' "$role" "$ROOT"
    case "$role" in
      spec-critic|brief-audit) printf 'Your contract is this packet. Read-only: you run commands to check, never to change.\n' ;;
      *) printf 'Your role contract is .claude/agents/%s.md — read it first and follow its protocol.\n' "$role" ;;
    esac
    printf -- '- spec: %s/spec.md\n- brief: %s/brief.md\n- lessons: %s/lessons.md\n' "$TASK" "$TASK" "$TASK"
    case "$role:$mode" in
      verifier:light)
        printf -- '- changed files (uncommitted, vs base %s): %s\n' "$base" "$changed"
        printf '\nLIGHT MODE (risk: med): protocol steps 1-2 only — re-run the verify,\n'
        printf 'review the diff for weakened tests and scope creep. No re-discovery.\n' ;;
      verifier:full)
        printf '\nFULL PROTOCOL (risk: high): re-run the verify, inspect the diff, and\n'
        printf 'spot-check the acceptance criteria this milestone touches by running them.\n'
        printf '\n## Acceptance criteria (spec.md)\n'; acceptance_criteria ;;
      verifier:drift)
        printf -- '- accumulated diff to judge: `git diff %s` (since the last drift check)\n' "$since"
        printf '\nDRIFT CHECK: is the trajectory still pointed at the acceptance criteria?\n'
        printf 'Judge intent, not letter: Goal, Constraints, Out of scope, and every\n'
        printf '[ASSUMED: ...] in spec.md section Assumptions — name any the human would veto.\n'
        printf 'ON-TRACK maps to verdict pass; DRIFTING maps to verdict fail.\n'
        printf '\n## Acceptance criteria (spec.md)\n'; acceptance_criteria ;;
      spec-critic:)
        printf '\nSPEC CRITIQUE — attack the FROZEN spec below before a single plan exists.\n'
        printf 'Four checks, findings for each:\n'
        printf '1. Executability: every acceptance criterion must be a command or a directly\n'
        printf '   observable behavior. "works well", "clean", "robust" = blocker; propose the\n'
        printf '   command that would make it checkable.\n'
        printf '2. Ambiguity that changes the plan: Goal / Constraints / Out of scope readings\n'
        printf '   that would lead to materially different work = major; state both readings.\n'
        printf '3. The direction question: what would make the human REJECT this even with\n'
        printf '   every AC green? Give concrete candidates (each a proposed Constraint or\n'
        printf '   Out-of-scope line) — severity major if the spec is silent on it.\n'
        printf '4. Assumptions: every [ASSUMED: ...] the human would plausibly veto = major.\n'
        printf 'A finding cites the AC id or the spec line it attacks. verdict pass = no\n'
        printf 'blocker and no major remain.\n'
        printf '\n## Spec (frozen, digest %s)\n\n' "$base"
        sed 's/^/    /' "$TASK/spec.md" ;;
      brief-audit:)
        printf '\nBRIEF AUDIT — every later context navigates by brief.md; a wrong load-\n'
        printf 'bearing claim misleads all of them. Pick the <=5 claims the plan will most\n'
        printf 'depend on (paths, interfaces, commands, gotchas) and check each against the\n'
        printf 'repo with a read-only command. Report each as confirmed / contradicted /\n'
        printf 'unverifiable with the command and its output. A contradicted load-bearing\n'
        printf 'claim = blocker; an unverifiable one = minor. Also name what the brief is\n'
        printf 'missing that the spec needs (major if the spec touches it). verdict pass =\n'
        printf 'no contradiction.\n'
        printf '\n## Brief (frozen, digest %s)\n\n' "$base"
        sed 's/^/    /' "$TASK/brief.md"
        printf '\n## Acceptance criteria (spec.md)\n'; acceptance_criteria ;;
      planner:)
        printf -- '- milestone budget: %s\n' "${budget:-$DEFAULT_BUDGET}"
        printf '\nPLAN CANDIDATE, lens: %s — commit fully to this lens; the orchestrator\n' "$lens"
        printf 'synthesizes across candidates, you do not hedge. Navigate by brief.md, spot-\n'
        printf 'check at most ~5 load-bearing claims, tag what you could not verify as\n'
        printf '[ASSUMPTION: ...]. Below the result header, write the candidate in EXACTLY\n'
        printf 'this plan.md format (the Stop gate parses it; every milestone needs a verify\n'
        printf 'command that fails today and passes when done):\n\n'
        plan_format
        printf '\n## Acceptance criteria (spec.md)\n'; acceptance_criteria ;;
      plan-critic:)
        printf -- '- milestone budget: %s\n' "${budget:-$DEFAULT_BUDGET}"
        printf '\nPLAN CRITIQUE, round %s of %s. Attack the FROZEN candidate below (do not\n' "$round" "$PLAN_ROUND_CAP"
        printf 'read plan.md — it may be changing). Follow your checklist; also spot-check\n'
        printf 'brief.md. Rules that make convergence real:\n'
        printf -- '- every finding carries a checkable claim (a command, a file:line, an AC id);\n'
        printf '  a finding without one is at most minor;\n'
        printf -- '- a finding the ledger shows as rejected may be re-raised ONLY with new\n'
        printf '  evidence — cite it, or drop it;\n'
        printf -- '- verdict pass means: no blocker and no major finding remain. Minor findings\n'
        printf '  do not block.\n'
        printf '\n## Acceptance criteria (spec.md)\n'; acceptance_criteria
        printf '\n## Candidate (frozen, digest %s)\n\n' "$base"
        sed 's/^/    /' "$candidate"
        if [ -f "$PAIR_DIR/ledger.md" ] && grep -q '^| plan |' "$PAIR_DIR/ledger.md"; then
          printf '\n## Ledger so far (stage: plan)\n\n'
          { grep -m1 '^| stage |' "$PAIR_DIR/ledger.md"; grep -m1 '^|---' "$PAIR_DIR/ledger.md"; grep '^| plan |' "$PAIR_DIR/ledger.md"; } | sed 's/^/    /'
        fi ;;
      final-verifier:)
        printf -- '- the whole task diff to judge: `git diff %s..HEAD` / `git log %s..HEAD`\n' "$since" "$since"
        printf '\nPANEL LENS: %s — judge ONLY this lens, over the WHOLE task. The task\n' "$lens"
        printf 'branch is fully committed; HEAD is the version under judgment (base above),\n'
        printf 'the task started at %s.\n' "$since"
        printf '\n## Acceptance criteria (spec.md)\n'; acceptance_criteria ;;
    esac
    if [ "$ms" != "-" ]; then
      printf '\n'; milestone_section "$ms"
    fi
    if [ -n "$rebuttal" ]; then
      printf '\n# Rebuttal round\nThe other side of the panel raised the findings below on the same\n'
      printf 'base. For EACH one: reproduce it (command + output) or refute it (command +\n'
      printf 'output). No opinion without a command. Findings you cannot make checkable\n'
      printf 'stay open — say so.\n\n'
      sed -n '/^findings:/,$p' "$rebuttal" | sed 's/^/> /'
    fi
    printf '\n# Result contract\n'
    printf 'Write %s\nstarting with exactly these lines:\n' "${abs%.md}.result.md"
    printf '  run: completed|failed|blocked\n  verdict: pass|fail|inconclusive\n  base: %s\n' "$base"
    printf '  findings: <n> (blocker/major/minor)\n  assumptions: [...]\n'
    case "$role" in
      planner)
        printf 'then the candidate plan in the format above (verdict: pass means you\n'
        printf 'produced a complete candidate; inconclusive means you could not), then any\n'
        printf 'brief.md discrepancies you found. Do not modify any file outside %s/.\n' "$PAIR_DIR"
        printf 'When done, reply with only the result path.\n' ;;
      plan-critic)
        printf 'then numbered findings: `severity (blocker|major|minor) [structural] — what\n'
        printf 'breaks — checkable claim — concrete fix`, and one closing line on the\n'
        printf 'skeleton. Do not modify any file outside %s/. When done, reply with only\n' "$PAIR_DIR"
        printf 'the result path.\n' ;;
      spec-critic)
        printf 'then numbered findings: `severity — check 1|2|3|4 — AC id or spec line —\n'
        printf 'what is wrong — proposed replacement text`. Do not modify any file outside\n'
        printf '%s/. When done, reply with only the result path.\n' "$PAIR_DIR" ;;
      brief-audit)
        printf 'then one line per checked claim: `confirmed|contradicted|unverifiable —\n'
        printf 'claim — command — output`, then missing items. Do not modify any file\n'
        printf 'outside %s/. When done, reply with only the result path.\n' "$PAIR_DIR" ;;
      *)
        printf 'then your evidence: the commands you ran and their output, and each finding\n'
        printf 'with a reproducible claim (command or file:line) and a severity. Your role\n'
        printf 'contract says PASS/FAIL; write them as verdict pass/fail. Do not modify any\n'
        printf 'file outside %s/. When done, reply with only the result path.\n' "$PAIR_DIR" ;;
    esac
  } > "$file"
  echo "$file"
}

# --- reset: fresh judge context (a slash command, no model turn) -------------
# `/new` to the judge and wait for idle. $1 = seq to attribute the runlog
# row to (`-` for a hand reset). The TUI redraw after /new can read as
# `working` for a moment; poll a few seconds before calling it stuck.
fresh_thread() {
  local seq="$1" st="" _i
  clear_modals
  herdr agent prompt "$NAME" "/new" >/dev/null 2>&1 || refuse "sending /new failed"
  for _i in 1 2 3 4 5; do
    st="$(judge_status)"
    case "$st" in idle|done) break ;; esac
    sleep 2
  done
  case "$st" in idle|done) ;; *) dump_screen "reset-$(date -u +%Y%m%dT%H%M%SZ).screen.txt"; RC=4 die "judge is '$st' after /new — inspect the pane" ;; esac
  log_row "$seq" reset - - - - "/new"
}

reset() {
  resolve_task; require_herdr
  [ -n "$(judge_status)" ] || refuse "no judge '$NAME' is live — run ensure"
  fresh_thread -
  echo "task-pair: judge '$NAME' context reset"
}

status() {
  resolve_task
  [ -f "$JUDGE_FILE" ] && sed 's/^/judge: /' "$JUDGE_FILE"
  [ -f "$RUNLOG" ] || { echo "runlog: empty"; return 0; }
  awk -F"$TAB" '
    $3 == "start" { role[$2] = $4; ms[$2] = $5; last[$2] = "running"; n[$2] = 1
                    if (prev != "reset") stale[$2] = 1 }
    $3 ~ /^end:/ { last[$2] = substr($3, 5) " " $11 }
    $3 == "waiting" { last[$2] = "waiting" }
    { prev = $3 }
    END { for (s in n) printf "seq %s  %s %s  -> %s%s\n", s, role[s], ms[s], last[s], (s in stale) ? "  [no fresh thread before start]" : "" }' "$RUNLOG" | sort
}

cmd="${1:-}"
[ $# -gt 0 ] && shift
case "$cmd" in
  ensure) ensure ;;
  packet) packet "$@" ;;
  digest) [ -f "${1:-}" ] || die "usage: task-pair.sh digest <file>"; file_digest plan "$1"; echo ;;
  reset) reset ;;
  send) [ -n "${1:-}" ] || die "usage: task-pair.sh send <packet> [--timeout MS]"; send "$@" ;;
  wait) [ -n "${1:-}" ] || die "usage: task-pair.sh wait <seq> [--timeout MS]"; wait_run "$@" ;;
  status) status ;;
  fingerprint)
    s="$(tr -d '[:space:]' < .ai_context/tasks/CURRENT 2>/dev/null || true)"
    [ -n "$s" ] && PAIR_DIR=".ai_context/tasks/$s/pair"
    fingerprint ;;
  *) echo "Usage: task-pair.sh <ensure|packet <role> <M<n>|->|digest <file>|send <packet>|wait <seq>|reset|status|fingerprint>" >&2; exit 2 ;;
esac
