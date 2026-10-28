#!/usr/bin/env bash
#
# Stop hook — the setup gate and the v4 evidence gate.
#
# Setup gate (once per session): a newborn project — CLAUDE.md still carrying
# the UNCONFIGURED sentinel (or legacy template placeholders) — blocks the
# first turn-end and instructs the /setup protocol. A session_id marker bounds
# this to ONE block per session; it re-arms next session and falls silent
# forever once the sentinel is gone.
#
# Evidence gate (while tasks/CURRENT names a card that is not idle). The gate
# runs no lane and hashes no tree: `scripts/evidence.sh status --porcelain` is
# its only evidence source. In order:
#   - no CURRENT, a v3 task (plan.md, no card.md) or a card idle 7+ days -> pass
#   - a lane run or Codex send holding a live pid lock, or a background
#     subagent in the Stop payload's background_tasks -> defer with a WAITING
#     row: its end re-wakes the session (D3, ADR-037)
#   - an [x] slice without a ✓ reference (noref), one whose references do not
#     hold (badref), or a Closed: line that is not fresh for the current
#     content (closed) -> block
#   - otherwise one status line, printed only when it changed this session
# Counted blocks: the same (session, card + content) blocks at most twice; the
# third stop yields — exit 0, one STUCK row, a systemMessage to the human. The
# counters live outside the project ($TMPDIR, else /tmp); a counter that cannot
# be written yields at once with a GATE-ERROR row.
# stop_hook_active is honoured by the setup gate only.
#
# Fail-open (D5): the gate's own errors never block. This file runs twice —
# the outer pass supervises the inner one and passes a block on only when the
# inner exits 2 with the marker as its first stdout line; a bash syntax error
# also exits 2, and no trap sees it. Anything else becomes a GATE-ERROR row in
# the task donelog and a pass.
# The marker `claude-starter-gate: BLOCK` is printed on stdout before every
# block: the CLI's missing-hook heuristic (through 2.1.229) dropped exit-2
# Stop hooks whose stdout was empty and whose stderr matched /no such file|
# can't open/i (journal 2026-08-13).

set -uo pipefail

ROOT="${CLAUDE_PROJECT_DIR:-.}"
TASKS="$ROOT/.ai_context/tasks"

# --- 0. Supervisor (outer pass; sources nothing, so nothing below can break it)
if [ "${CLAUDE_STARTER_GATE_INNER:-}" != 1 ]; then
  payload="$(cat 2>/dev/null || true)"
  # Gate state (block counters, markers, this stderr file — and evidence.sh's
  # scratch files) never lives under the project: a file there changes the tree
  # the block count is keyed on, so the count never reaches STUCK (review M2).
  st="${TMPDIR:-/tmp}"
  r="$(cd "$ROOT" 2>/dev/null && pwd -P)"
  if [ -n "$r" ]; then
    case "$(cd "$st" 2>/dev/null && pwd -P)/" in "$r"/*) st=/tmp ;; esac
  fi
  errf="$(mktemp "$st/claude-gate-err.XXXXXX" 2>/dev/null || mktemp /tmp/claude-gate-err.XXXXXX 2>/dev/null)" || errf=""
  tmo=()
  command -v timeout >/dev/null 2>&1 && tmo=(timeout 25)
  if [ -n "$errf" ]; then
    out="$(printf '%s' "$payload" | TMPDIR="$st" CLAUDE_STARTER_GATE_INNER=1 ${tmo[@]+"${tmo[@]}"} bash "${BASH_SOURCE[0]}" 2>"$errf")"
    rc=$?
    err="$(cat "$errf" 2>/dev/null)"
    rm -f "$errf"
  else   # no temp file anywhere: stderr shares stdout; the inner's own stdout lines are known
    out="$(printf '%s' "$payload" | TMPDIR="$st" CLAUDE_STARTER_GATE_INNER=1 ${tmo[@]+"${tmo[@]}"} bash "${BASH_SOURCE[0]}" 2>&1)"
    rc=$?
    err="$(printf '%s\n' "$out" | grep -v -e '^claude-starter-gate: BLOCK$' -e '^{"systemMessage":')"
    out="$(printf '%s\n' "$out" | grep -e '^claude-starter-gate: BLOCK$' -e '^{"systemMessage":')"
  fi
  if [ "$rc" = 0 ]; then
    [ -z "$out" ] || printf '%s\n' "$out"
  elif [ "$rc" = 2 ] && [ "${out%%$'\n'*}" = 'claude-starter-gate: BLOCK' ]; then
    printf '%s\n' "$out"
    printf '%s\n' "${err:-claude-starter gate: blocked - bash scripts/evidence.sh status shows why}" >&2
  else
    # The reason lands in a tracked donelog: no absolute project or home path,
    # and when it is long the end (the actual error) is what is kept (review L3).
    why="$(printf '%s\n' "$err" | grep -v '^[[:space:]]*$' | tail -n 1)"
    case "$ROOT" in /?*) why="${why//"${ROOT%/}/"/}" ;; esac
    case "${HOME:-}" in /?*) why="${why//"${HOME%/}"/"~"}" ;; esac
    why="$(printf '%s' "$why" | tr -cd 'A-Za-z0-9 ._:/=()~-')"
    [ "${#why}" -le 160 ] || why="...${why: -157}"
    [ "$rc" = 124 ] && why="${why:-timed out after 25 s}"
    why="rc=$rc${why:+: $why}"
    s="$(tr -d '[:space:]' 2>/dev/null < "$TASKS/CURRENT")"
    case "$s" in
      ''|*/*|*..*) ;;
      *) [ ! -d "$TASKS/$s" ] || { printf '%s\tGATE-ERROR\t-\tgate\t-\t-\t%s\n' \
           "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$why" >> "$TASKS/$s/donelog"; } 2>/dev/null ;;
    esac
    printf '{"systemMessage":"claude-starter gate: internal error (%s) - not blocking this stop; logged to the task donelog. Check by hand: bash scripts/evidence.sh status"}\n' "$why"
    rc=0
  fi
  exit "$rc"
fi

# --- 1. Setup gate (inner pass from here on) -----------------------------------
# Sentinel + task helpers, one source with session-start.sh and bash-guard.sh
# (ADR-004); the fallback keeps the setup gate armed on a partial sync.
_GP="$(dirname "${BASH_SOURCE[0]}")/guard-patterns.sh"
# shellcheck source=guard-patterns.sh
[ -f "$_GP" ] && . "$_GP"
[ -n "${GUARD_SETUP_SENTINEL:-}" ] || GUARD_SETUP_SENTINEL='claude-starter: UNCONFIGURED|<e\.g\.,|<command>|Replace before first commit'

payload="$(cat 2>/dev/null || true)"
stop_active=0
if printf '%s' "$payload" | grep -q '"stop_hook_active"[[:space:]]*:[[:space:]]*true'; then
  stop_active=1
fi
sid="$(printf '%s' "$payload" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
# Filename-safe session id for this hook's own marker/counter files.
sid_s="$(printf '%s' "${sid:-nosession}" | tr -cd 'A-Za-z0-9._-')"
[ -n "$sid_s" ] || sid_s=nosession

# Fixed stdout marker, printed before EVERY exit-2 block (see the header).
# Regression: L1-21 exercises each block path for it.
mark_block() { printf 'claude-starter-gate: BLOCK\n'; }

if [ "$stop_active" = 0 ] && [ -f "$ROOT/CLAUDE.md" ] && \
   grep -qE "$GUARD_SETUP_SENTINEL" "$ROOT/CLAUDE.md"; then
  marker="${TMPDIR:-/tmp}/claude-setup-nudge-${sid_s}"
  if [ ! -f "$marker" ]; then
    { : > "$marker"; } 2>/dev/null
    mark_block
    {
      printf 'SETUP GATE — this project has not been set up: CLAUDE.md still carries the UNCONFIGURED sentinel / template placeholders.\n'
      printf 'Run the /setup protocol now: interview the human if intent is unclear, scaffold if needed,\n'
      printf 'draft CLAUDE.md (Stack/Commands/Verify/DoD) plus README/state.md, and ask the human to\n'
      printf 'review the diff. If the human explicitly declined setup this session, say so and finish.\n'
    } >&2
    exit 2
  fi
fi

# --- 2. The task: none, v3 or idle -> pass --------------------------------------
if [ "${GUARD_PATTERNS_V4:-}" != 1 ] || [ -z "${GUARD_SLICE_X:-}" ]; then
  echo "guard-patterns.sh missing or predates v4 (no task helpers)" >&2
  exit 3
fi
slug="$(task_slug "$ROOT")" || exit 0
slug_j="$(printf '%s' "$slug" | tr -cd 'A-Za-z0-9._-')"
card="$TASKS/$slug/card.md"
donelog="$TASKS/$slug/donelog"
if [ ! -f "$card" ]; then
  v3m="${TMPDIR:-/tmp}/claude-gate-v3note-${sid_s}"
  if [ -f "$TASKS/$slug/plan.md" ] && [ ! -f "$v3m" ]; then
    { : > "$v3m"; } 2>/dev/null
    printf '{"systemMessage":"claude-starter gate: tasks/CURRENT names %s, a v3 plan.md task without card.md - the v4 gate does not check it. Finish it on the v3-final template or rewrite it as a card."}\n' "$slug_j"
  fi
  exit 0
fi
task_idle "$ROOT" "$slug" && exit 0

# --- 3. Still running -> defer (D3; ADR-037 widened) ----------------------------
# A block now buys nothing: the run's end re-wakes the session. Only live pid
# locks and background subagents (a background_tasks entry of "type":
# "subagent") count — never a background shell command, and never the
# payload's top-level agent_type: that is a session started with --agent
# executor|checker, which no stop would ever check again (review M5).
fl=""
for lk in "$ROOT"/.claude/evidence/locks/*.lock; do
  [ -f "$lk" ] || continue
  lock_alive "$(head -n 1 "$lk" 2>/dev/null | cut -f1)" || continue
  n="${lk##*/}"
  n="${n%.lock}"
  fl="${fl:+$fl,}${n%%-*}:${n#*-}"
done
if printf '%s' "$payload" | grep -Eq '"type"[[:space:]]*:[[:space:]]*"subagent"'; then
  at="$(printf '%s' "$payload" | tr '\n' ' ' | grep -oE '"type"[[:space:]]*:[[:space:]]*"subagent"[^{}]*' |
        grep -oE '"agent_type"[[:space:]]*:[[:space:]]*"[^"]*"' | sed -E 's/.*"([^"]*)"$/\1/' | tr '\n' ',')"
  at="${at%,}"
  fl="${fl:+$fl,}subagent:${at:-?}"
fi
if [ -n "$fl" ]; then
  fl="$(printf '%s' "$fl" | tr -cd 'A-Za-z0-9:,._?-')"
  donelog_row "$donelog" WAITING "$(card_current_slice "$card")" "$fl" - - deferred
  printf '{"systemMessage":"claude-starter gate: %s - %s in flight; evidence check deferred until it reports."}\n' "$slug_j" "$fl"
  exit 0
fi

# --- 4-5. What the card claims: [x] references and Closed: ----------------------
F_SL=""
F_CL=""
F_MSG=""
finding() { # $1 = class, $2 = slice or -, $3 = stderr line
  case ",$F_CL," in *",$1,"*) ;; *) F_CL="${F_CL:+$F_CL,}$1" ;; esac
  [ "$2" = - ] || F_SL="${F_SL:+$F_SL,}$2"
  F_MSG="$F_MSG  $3"$'\n'
}

hash_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256
  else cksum
  fi
}

# An [x] line (GUARD_SLICE_X, the regex evidence.sh reads too) cites records
# after its first ` ✓ `: <name>@<hex id> or codex@waived.
xs=""
while IFS= read -r ln; do
  s="${ln#- \[x\] }"
  s="${s%%[!S0-9]*}"
  xs="$xs $s"
  r=""
  case "$ln" in *' ✓ '*) r="${ln#* ✓ }" ;; esac
  printf '%s\n' "$r" | grep -Eq '(^|[^A-Za-z0-9_-])[A-Za-z0-9_-]+@([0-9a-f]{7,64}|waived)' ||
    finding noref "$s" "$s is marked [x] without an evidence reference."
done < <(grep -E "$GUARD_SLICE_X" "$card")

tree=-
if [ -n "$F_CL" ]; then
  # noref needs no ledger; the content half of the key is HEAD + the changed
  # files (the task's own .ai_context and the ledger left out).
  content="$( { git -C "$ROOT" rev-parse HEAD
                git -C "$ROOT" status --porcelain -- . ':(exclude).ai_context' ':(exclude).claude/evidence'
              } 2>/dev/null | hash_stdin)"
else
  if [ ! -f "$ROOT/scripts/evidence.sh" ]; then
    echo "scripts/evidence.sh missing" >&2
    exit 3
  fi
  tmo=()
  command -v timeout >/dev/null 2>&1 && tmo=(timeout "${CLAUDE_STARTER_GATE_STATUS_TIMEOUT:-20}")
  st="$(${tmo[@]+"${tmo[@]}"} bash "$ROOT/scripts/evidence.sh" status --porcelain </dev/null 2>/dev/null)"
  rc=$?
  if [ "$rc" != 0 ]; then
    echo "evidence.sh status --porcelain failed (rc $rc)" >&2
    exit 3
  fi
  tree="$(printf '%s\n' "$st" | awk -F'\t' '$1 == "TREE" {print $2; exit}')"
  closed="$(printf '%s\n' "$st" | awk -F'\t' '$1 == "CLOSED" {print $2 "\t" $3; exit}')"
  line="$(printf '%s\n' "$st" | awk -F'\t' '$1 == "LINE" {print $2; exit}')"
  if [ -z "$tree" ] || [ -z "$closed" ] || [ -z "$line" ]; then
    echo "evidence.sh status --porcelain: unparseable output" >&2
    exit 3
  fi
  # Only ok / foreign pass; every [x] the gate saw needs its SLICE row (review M1).
  seen=" "
  while IFS=$'\t' read -r k s v d; do
    [ "$k" = SLICE ] || continue
    seen="$seen$s "
    case "$v" in
      ok|foreign) ;;
      noref) finding noref "$s" "$s is marked [x] without an evidence reference." ;;
      *) finding badref "$s" "$s cites evidence that does not hold: ${d:-$v}" ;;
    esac
  done <<< "$st"
  for s in $xs; do
    case "$seen" in *" $s "*) ;; *) finding badref "$s" "$s cites evidence that does not hold: not evaluated by evidence.sh" ;; esac
  done
  case "$closed" in
    stale*) finding closed - "the card says Closed: but the evidence is not fresh for the current content: ${closed#*$'\t'}" ;;
  esac
  content="$tree"
fi

# --- 6. Nothing wrong -> the status line, once per change per session -----------
if [ -z "$F_CL" ]; then
  line="$(printf '%s' "$line" | tr -d '"\\' | tr -d '\000-\037')"
  lm="${TMPDIR:-/tmp}/claude-gate-line-${sid_s}-${slug_j}"
  if [ "$(cat "$lm" 2>/dev/null)" != "$line" ]; then
    { printf '%s' "$line" > "$lm"; } 2>/dev/null
    printf '{"systemMessage":"claude-starter gate: %s"}\n' "$line"
  fi
  exit 0
fi

# --- 7. Block, counted per (session, card + content) ----------------------------
# Session-scoped on purpose: donelog BLOCK rows survive across sessions, so
# counting those would carry yesterday's blocks into today's first stop. The
# key holds the content, so a new card or new content starts a fresh count.
red_file() { # $1 = key -> prints the counter path
  printf '%s/claude-gate-red-%s-%s' "${TMPDIR:-/tmp}" "$sid_s" \
    "$(printf '%s' "$1" | tr -cs 'A-Za-z0-9._-' '_')"
}

stuck_file() { # $1 = key -> prints the once-per-(session, key) STUCK marker path
  printf '%s/claude-gate-stuck-%s-%s' "${TMPDIR:-/tmp}" "$sid_s" \
    "$(printf '%s' "$1" | tr -cs 'A-Za-z0-9._-' '_')"
}

key="${slug_j}_$( { hash_stdin < "$card" | cut -c1-64; printf '%s\n' "$content"; } | hash_stdin | cut -c1-16)"
rcf="$(red_file "$key")"
rn="$(cat "$rcf" 2>/dev/null || true)"
case "$rn" in (''|*[!0-9]*) rn=0 ;; esac
rn=$((rn + 1))
# A count that cannot be kept cannot bound the blocks: yield instead (GATE-ERROR).
if ! { printf '%s' "$rn" > "$rcf"; } 2>/dev/null || [ "$(cat "$rcf" 2>/dev/null)" != "$rn" ]; then
  echo "${TMPDIR:-/tmp}: block counter not writable - yielding instead of blocking uncounted" >&2
  exit 3
fi
# Three stops on the same card and content: the run is the human's now. ONE
# STUCK row per (session, key) — the yield is one handoff however many stops
# follow (F10); the systemMessage repeats so the human signal survives.
if [ "$rn" -ge 3 ]; then
  smk="$(stuck_file "$key")"
  if [ ! -f "$smk" ]; then
    { : > "$smk"; } 2>/dev/null
    donelog_row "$donelog" STUCK "${F_SL:--}" "$F_CL" "${tree:0:12}" - "yielded after $rn blocks on the same card and content"
  fi
  printf '{"systemMessage":"claude-starter gate: task %s is BLOCKED - %s stops in a row on the same card and content (%s), yielding now. A human needs to look: .ai_context/tasks/%s/donelog"}\n' \
    "$slug_j" "$rn" "$F_CL" "$slug_j"
  exit 0
fi
donelog_row "$donelog" BLOCK "${F_SL:--}" "$F_CL" "${tree:0:12}" - "block $rn/2"
mark_block
{
  printf 'GATE BLOCKED (block %s of 2 — a third stop on the same card and content hands off to the human) — task %s:\n' "$rn" "$slug_j"
  printf '%s' "$F_MSG"
  case ",$F_CL," in
    *,noref,*|*,badref,*)
      printf 'Only `bash scripts/evidence.sh done <slice>` marks a slice [x]: set the line back to [~], get its lanes, checker (and Codex, when required) to passing records, then run it — or say plainly that you are pausing with the slice unverified.\n' ;;
  esac
  case ",$F_CL," in
    *,closed,*)
      printf 'Re-run the stale lanes with `bash scripts/evidence.sh run <lane>` (long lanes in the background), get the final review the detail names (checker final, or Codex final when pairing is on), then `bash scripts/evidence.sh close` — or delete the Closed: line and say the task is not closed.\n' ;;
  esac
  printf 'Full picture: bash scripts/evidence.sh status\n'
} >&2
exit 2
