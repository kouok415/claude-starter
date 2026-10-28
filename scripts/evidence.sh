#!/usr/bin/env bash
# evidence.sh — claude-starter v4: the only writer of task evidence. Lanes are declared in
# .claude/done-lanes (format: .claude/skills/task/reference.md §Lanes); records, logs and
# pid locks live per machine in .claude/evidence/ (gitignored); tasks/<slug>/donelog is the tracked side.
#   trust <lane> [--skip-canary] · approve [--waive <S<n>|card|final> --reason <text>]   (the human)
#   run <lane> [--escalated] · start S<n> · done S<n> · close · lint · show <lane|checker|codex-*|@id>
#   status [--line|--porcelain] · check <S<n>|final|card|-> --agent <id|-> --source <src>  (report on stdin)
#   codex <packet> <result> <completed|failed|blocked> <reason>                           (task-pair.sh)
# Opt-in statusline: "statusLine": {"type": "command", "command": "bash scripts/evidence.sh status --line"}
# Logs are never pruned automatically: find .claude/evidence/logs -mtime +30 -delete
# Exit: 0 ok/pass · 1 fail or refused · 2 usage/format · 3 not allowed now · 4 busy · 5 ESCALATE · 6 internal
# shellcheck disable=SC2046,SC2086  # lane paths and lane lists split on purpose
set -uo pipefail
cd "$(dirname "$0")/.." || exit 6
export LC_ALL=C

EV=.claude/evidence
DL=.claude/done-lanes
TR=.claude/done-lanes.trust
PAIR=off
DLOG=""
NOGIT=""
IX=0
TAB=$'\t'
L_NAME=(); L_PATHS=(); L_MIN=(); L_EXP=(); L_CAN=(); L_CMD=(); L_LINE=(); EXT=()
SLICE_RE='^- \[[ ~ox]\] S[0-9]+ .+ (—|--) lanes: [a-z][a-z0-9-]*(,[a-z][a-z0-9-]*)* ; codex: (yes|no)( ; notes: §[^✓]+)?( ✓ .*)?$'

die() { local rc="$1"; shift; printf 'evidence: %s\n' "$*" >&2; exit "$rc"; }
now() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi | cut -c1-64; }
h12() { printf '%s' "$1" | sha | cut -c1-12; }

# shellcheck source=../.claude/hooks/guard-patterns.sh
. .claude/hooks/guard-patterns.sh 2>/dev/null
for f in static_only donelog_row lock_alive task_slug card_current_slice; do
  declare -F "$f" >/dev/null || die 6 ".claude/hooks/guard-patterns.sh is missing or predates v4 — re-sync the template"
done
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  [ "${1:-}" = status ] || die 6 "not inside a git work tree"
  NOGIT=1
fi
if [ "${1:-}" != status ]; then
  git check-ignore -q "$EV/x" || die 6 ".claude/evidence/ is not gitignored — add it to .gitignore first (logs must never be committed)"
  (umask 077; mkdir -p "$EV/logs" "$EV/locks")
fi

# --- .claude/done-lanes (02 §0.1) ---------------------------------------------

split() { # $1 = separator, $2 = string -> S[] (empty fields kept)
  local r="$2"
  S=()
  while case "$r" in *"$1"*) true ;; *) false ;; esac; do
    S+=("${r%%"$1"*}")
    r="${r#*"$1"}"
  done
  S+=("$r")
}

bad() { die 2 ".claude/done-lanes line $1: $2"; }

lane_ix() { # $1 = lane name -> IX; rc 1 when not declared
  local i
  for ((i = 0; i < ${#L_NAME[@]}; i++)); do
    if [ "${L_NAME[i]}" = "$1" ]; then
      IX=$i
      return 0
    fi
  done
  return 1
}

load_lanes() { # -> L_NAME L_PATHS L_MIN L_EXP L_CAN L_CMD L_LINE, EXT[i], PAIR, DIR_SHA; a format error exits 2
  local n=0 dirs="" ext="" ln p x
  L_NAME=(); L_PATHS=(); L_MIN=(); L_EXP=(); L_CAN=(); L_CMD=(); L_LINE=(); EXT=()
  PAIR=off
  [ -f "$DL" ] || die 2 ".claude/done-lanes not found — declare 1-3 lanes first (.claude/skills/task/reference.md §Lanes)"
  while IFS= read -r ln || [ -n "$ln" ]; do
    n=$((n + 1))
    ln="${ln%"${ln##*[![:space:]]}"}"
    case "$ln" in
      ''|'#'*) ;;
      '@ext '*)
        dirs="$dirs$ln"$'\n'
        ext="$ext$n ${ln#@ext }"$'\n'
        ;;
      '@pair '*|'@verify-paths '*)
        ln="$(printf '%s' "$ln" | sed -E 's/[[:space:]]+#.*$//')"
        dirs="$dirs$ln"$'\n'
        case "$ln" in
          '@pair codex') PAIR=codex ;;
          '@pair off'|'@verify-paths '*) ;;
          *) bad $n "unknown directive '$ln'" ;;
        esac
        ;;
      '@'*) bad $n "unknown directive '${ln%% *}'" ;;
      *)
        split ' | ' "$ln"
        [ ${#S[@]} = 6 ] && case "${S[4]}${S[5]}" in *'|'*) false ;; esac ||
          bad $n "want 6 fields separated by ' | ', and no '|' inside cmd (put pipelines in a wrapper script)"
        [[ "${S[0]}" =~ ^[a-z][a-z0-9-]{0,23}$ ]] && case "${S[0]}" in checker|final|card|codex*) false ;; esac ||
          bad $n "bad lane name '${S[0]}'"
        for p in ${S[1]}; do
          case "$p" in /*|*..*) bad $n "bad path '$p'" ;; esac
        done
        lane_ix "${S[0]}" && bad $n "duplicate lane '${S[0]}'"
        [[ "${S[2]}" =~ ^[1-9][0-9]*$ ]] || bad $n "min_secs must be an integer >= 1 (got '${S[2]}')"
        [ -n "${S[3]// /}" ] || bad $n "expect is empty: a lane needs at least one marker the product prints"
        L_NAME+=("${S[0]}"); L_PATHS+=("${S[1]}"); L_MIN+=("${S[2]}")
        L_EXP+=("${S[3]}"); L_CAN+=("${S[4]}"); L_CMD+=("${S[5]}"); L_LINE+=("$ln")
        ;;
    esac
  done < "$DL"
  [ ${#L_NAME[@]} -ge 1 ] && [ ${#L_NAME[@]} -le 3 ] || die 2 ".claude/done-lanes declares ${#L_NAME[@]} lanes (max 3)"
  while read -r n x p; do
    [ -n "$n" ] || continue
    lane_ix "$x" || bad "$n" "@ext names unknown lane '$x'"
    EXT[IX]="$p"
  done <<< "$ext"
  DIR_SHA="$(printf '%s' "$dirs" | cat - .claude/gitleaks.toml 2>/dev/null | sha | cut -c1-12)"
}

lanes_soft() { # load_lanes when .claude/done-lanes parses; rc != 0 (nothing loaded) otherwise
  (load_lanes) >/dev/null 2>&1 && load_lanes
}

# --- task, card, approval ------------------------------------------------------

task_ctx() { # -> SLUG CARD DLOG DIG D12 A12; $1 = soft: rc 1 instead of exiting without a task or card
  local s
  if ! s="$(task_slug .)"; then
    [ -n "${1:-}" ] && return 1
    die 3 "no active task (.ai_context/tasks/CURRENT)"
  fi
  if [ ! -f ".ai_context/tasks/$s/card.md" ]; then
    [ -n "${1:-}" ] && return 1
    die 2 "no card at .ai_context/tasks/$s/card.md"
  fi
  SLUG="$s"
  CARD=".ai_context/tasks/$s/card.md"
  DLOG=".ai_context/tasks/$s/donelog"
  DIG="card:$(sed -e 's/^- \[[ ~ox]\] /- [ ] /' -e 's/ ✓ .*$//' -e '/^Closed:/d' "$CARD" | sha)"
  D12="${DIG:5:12}"
  A12="$(awk -F'\t' '$2 == "APPROVE" {a = $5} END {print a}' "$DLOG" 2>/dev/null)"
  return 0
}

slice_line() { [[ "$1" =~ ^S[0-9]+$ ]] && grep -E "^- \[[ ~ox]\] $1( |\$)" "$CARD" | head -n 1; }
slice_lanes() { printf '%s' "$1" | sed -nE 's/.* lanes: ([a-z0-9,-]+) ; codex: .*/\1/p' | tr , ' '; }
pair_on() { [ "$PAIR" = codex ] || grep -Eq '^<!-- card v4 .*pair: codex' "$CARD"; }
codex_yes() { [ "${1#*; codex: yes}" != "$1" ] && pair_on; }

waived() { # $1 = unit -> the reason of its WAIVE row at the current card digest; rc 1 when there is none
  awk -F'\t' -v u="$1" -v d="$D12" '$2 == "WAIVE" && $3 == u && $5 == d {r = $7; f = 1} END {print r; exit !f}' "$DLOG" 2>/dev/null
}

started_row() { # $1 = S<n> -> its open START row (none once a DONE row follows)
  awk -F'\t' -v s="$1" '$3 == s && $2 == "START" {r = $0} $3 == s && $2 == "DONE" {r = ""} END {print r}' "$DLOG" 2>/dev/null
}

card_lanes() { # the lanes any slice cites, in done-lanes order
  local all i
  all=" $(sed -nE 's/^- \[[ ~ox]\] S[0-9]+ .* lanes: ([a-z0-9,-]+) ; codex: .*/\1/p' "$CARD" | tr ',\n' '  ') "
  for ((i = 0; i < ${#L_NAME[@]}; i++)); do
    case "$all" in *" ${L_NAME[i]} "*) echo "${L_NAME[i]}" ;; esac
  done
}

card_reviewed() { # an approving codex-card review of the current card, or a waiver for it
  local r
  r="$(lastrec codex.jsonl "\"lane\":\"codex-card\",\"unit\":\"card\",\"tree\":\"$DIG\"")"
  { [ -n "$r" ] && approving "$r"; } || waived card >/dev/null
}

approval_gap() {
  [ "$A12" = "$D12" ] ||
    gap "card changed since approval (approved ${A12:-never}, now card:$D12) — the human runs: bash scripts/evidence.sh approve"
  ! pair_on || card_reviewed || gap "no approving codex-card review of card:$D12 — run: bash scripts/task-pair.sh check card"
}

# --- content trees (02 §0.4) and the ledger -------------------------------------

tree_of() { # $@ = paths ('.' = whole repo) -> one object id; .ai_context/ and .claude/evidence/ never count
  local idx t p
  idx="$(mktemp "${TMPDIR:-/tmp}/evidence-idx.XXXXXX")" || return 1
  cp "$(git rev-parse --git-path index)" "$idx" 2>/dev/null || rm -f "$idx"   # reuse the stat cache; no index -> empty
  t="$(
    export GIT_INDEX_FILE="$idx"
    for p in "$@"; do
      if [ -e "$p" ]; then
        git add -A -- "$p"
      else
        git rm -r -q --cached --ignore-unmatch -- "$p"
      fi
    done >/dev/null 2>&1
    git rm -r -q --cached --ignore-unmatch -- .ai_context .claude/evidence >/dev/null 2>&1
    git write-tree
  )"
  rm -f "$idx"
  for p in "$@"; do
    p="${p%/}"
    if [ "$p" = . ]; then
      echo ". $t"
    else
      echo "$p $(git rev-parse -q --verify "$t:$p" || echo -)"
    fi
  done | git hash-object --stdin
}

lane_tree() { tree_of ${L_PATHS[$1]}; }

slice_tree() { # $1 = S<n> -> the tree over the union of its lanes' paths
  local l p=""
  for l in $(slice_lanes "$(slice_line "$1")"); do
    lane_ix "$l" && p="$p ${L_PATHS[IX]}"
  done
  tree_of $(printf '%s\n' $p | sort -u)
}

record() { # $1 = ledger, then key=str | key:int | key@raw (markers, last); one JSON line whose strings hold no " , \ TAB; sets RID
  local f="$EV/$1" a k v body="" vals=""
  shift
  for a in "$@"; do
    k="${a%%[=:@]*}"
    v="${a:${#k}+1}"
    case "${a:${#k}:1}" in
      =)
        v="$(printf '%s' "$v" | tr -d '",\\\t\r\n')"
        body="$body,\"$k\":\"$v\""
        ;;
      :)
        v="${v:-0}"
        body="$body,\"$k\":$v"
        ;;
      *) body="$body,\"$k\":$v" ;;
    esac
    vals="$vals$v"
  done
  RID="$(printf '%s' "$vals" | sha | cut -c1-8)"
  printf '{"id":"%s"%s}\n' "$RID" "$body" >> "$f"
}

jget() { printf '%s' "${1%%,\"markers\":*}" | sed -nE "s/.*[{,]\"$2\":\"?([^\",}]*)\"?.*/\1/p"; }
lastrec() { grep -F -- "${2:-\"id\"}" "$EV/$1" 2>/dev/null | tail -n 1; }
byid() { [[ "$1" =~ ^[0-9a-f]{8}$ ]] && cat "$EV"/*.jsonl 2>/dev/null | grep -F "{\"id\":\"$1\"" | tail -n 1; }
approving() { [ "$(jget "$1" run_state) $(jget "$1" verdict) $(jget "$1" critical) $(jget "$1" high)" = "completed pass 0 0" ]; }

lane_state() { # $1 = lane -> LS fresh|stale|fail|missing, LID, LSD (the words for gaps and footers)
  local r
  r="$(lastrec "$1.jsonl")"
  LID="$(jget "$r" id)"
  LS=fresh
  LSD=fresh
  if [ -z "$r" ]; then
    LS=missing
    LSD=missing
  elif [ "$(jget "$r" verdict)" != pass ]; then
    LS=fail
    LSD="failed ($(jget "$r" why))"
  elif ! lane_ix "$1" || [ "$(jget "$r" tree)" != "$(lane_tree "$IX")" ]; then
    LS=stale
    LSD="stale (record $LID was for other content)"
  fi
}

rev_tail() { # $1 type, $2 unit, $3 lane, $4 tree, $5 result -> the donelog row of review record RID
  local t="${4#card:}"
  donelog_row "$DLOG" "$1" "$2" "$3" "${t:0:12}" "$RID" "$5"
}

defect() { # lands in C6 (harness-report.sh --defect); until then only a warning
  bash scripts/harness-report.sh --defect "$SLUG" "$1" "$2" "$3" "$4" "$5" --n "$6" >/dev/null 2>&1 ||
    echo "evidence: warning: defect not recorded (harness-report.sh --defect failed): $4" >&2
}

# --- judging a lane or canary log ------------------------------------------------

judge() { # $1 log, $2 expect, $3 exit, $4 secs, $5 min_secs (0 = canary) -> J_WHY J_EXEC J_SKIP J_MK J_MKS J_SCAN
  local i=0 k=0 re ln o
  J_WHY=-
  J_EXEC=""
  J_MKS=""
  [ "$3" != 0 ] && J_WHY="exit=$3"
  split ' ; ' "$2"
  for re in "${S[@]}"; do
    i=$((i + 1))
    if ln="$(grep -E -m 1 -- "$re" "$1" 2>/dev/null)"; then
      k=$((k + 1))
      [ $i = 1 ] && J_EXEC="$(printf '%s' "$ln" | grep -Eo '[0-9]+' | head -n 1)"
      J_MKS="$J_MKS,\"$(printf '%s' "${ln:0:200}" | tr -d '\000-\037"\\')\""
    elif [ "$J_WHY" = - ]; then
      J_WHY="expect=$i"
    fi
  done
  J_EXEC="${J_EXEC:-0}"
  J_MK="$k/$i"
  J_MKS="[${J_MKS#,}]"
  [ "$J_WHY" = - ] && [ "$J_EXEC" -le 0 ] && J_WHY=executed=0
  [ "$J_WHY" = - ] && [ "$4" -lt "$5" ] && J_WHY="too-fast:$4<$5"
  J_SKIP="$(grep -Eo '[0-9]+ (skipped|xfailed|deselected)' "$1" | awk '{s += $1} END {print s + 0}')"
  o="$(bash scripts/precommit-gitleaks.sh --scan-file "$1" 2>/dev/null)"
  case $? in
    0) J_SCAN=clean ;;
    3) J_SCAN=clean-ip-only ;;
    *)
      case "$o" in
        ''|scan-error) J_SCAN=scan-error ;;
        *) J_SCAN="hit:$(printf '%s' "$o" | tr '\n' '+')" ;;
      esac
      ;;
  esac
}

cmd_trust() { # trust <lane> [--skip-canary]: the human approves one lane definition (02 §0.2)
  local l="${1:-}" c cmd t0 log rc s0 res first
  load_lanes
  lane_ix "$l" || die 2 "no lane '$l' in .claude/done-lanes"
  c="${L_CAN[IX]}"
  cmd="${L_CMD[IX]}"
  if static_only "$cmd"; then
    first="$(printf '%s' "$cmd" | sed -E 's/[[:space:]]*(&&|;|\|).*//')"
    die 3 "TRUST REFUSED — $l: static-only command ('$first'): a lane must run the product, not lint, parse or list it"
  fi
  [ "${2:-}" = --skip-canary ] && [ "${c#skip:}" = "$c" ] && die 2 "--skip-canary needs canary = skip:<reason> in .claude/done-lanes"
  [ -z "$c" ] && die 3 "TRUST REFUSED — $l: canary is empty"
  if [ "${c#skip:}" != "$c" ]; then
    res="skip:$(printf '%s' "${c#skip:}" | tr '\t,' '  ' | cut -c1-120)"
    [ "${2:-}" = --skip-canary ] ||
      die 3 "TRUST REFUSED — $l: canary is $c; nothing would show this lane can fail. If the human accepts that: bash scripts/evidence.sh trust $l --skip-canary"
  else
    if [ "$c" = "$cmd" ] || static_only "$c" || [[ "$c" =~ ^(false|true|exit\ [0-9]+|!\ .*)$ ]]; then
      die 3 "TRUST REFUSED — $l: canary is trivial ('$c'): it must run the same check against a known-broken state"
    fi
    t0="$(lane_tree "$IX")"
    log="$EV/logs/$l-canary-$(date -u +%Y%m%dT%H%M%SZ).log"
    s0=$SECONDS
    ( umask 077; exec bash -c "$c" ) </dev/null >"$log" 2>&1
    rc=$?
    chmod 600 "$log"
    judge "$log" "${L_EXP[IX]}" "$rc" $((SECONDS - s0)) 0
    case "$J_SCAN" in
      clean*) ;;
      *) die 3 "TRUST REFUSED — $l: the canary log hit a secret or internal-IP rule (${J_SCAN#hit:}): mask the output before trusting (log kept at $log, mode 600)" ;;
    esac
    [ "$t0" = "$(lane_tree "$IX")" ] ||
      die 3 "TRUST REFUSED — $l: the canary left the lane's content changed: a canary must restore whatever it breaks"
    [ "$J_WHY" = - ] &&
      die 3 "TRUST REFUSED — $l: the canary passed (exit 0, every marker, executed=$J_EXEC): this lane cannot tell broken from working; fix the canary or tighten expect"
    res="red:$J_WHY"
  fi
  [ -f "$TR" ] ||
    printf '# ts\tlane\tcmd_sha\tlane_sha\tdir_sha\tcanary_sha\tcanary_result — written only by scripts/evidence.sh trust; append-only\n' > "$TR"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(now)" "$l" "$(h12 "$cmd")" "$(h12 "${L_LINE[IX]}")" "$DIR_SHA" "$(h12 "$c")" "$res" >> "$TR"
  task_ctx soft && donelog_row "$DLOG" TRUST - "$l" - - "canary $res cmd $(h12 "$cmd")"
  echo "evidence: trusted lane $l — canary $res · cmd $(h12 "$cmd") · lane $(h12 "${L_LINE[IX]}") · directives $DIR_SHA"
  echo "evidence: re-trust whenever this lane's line or any @ directive changes; run refuses an untrusted definition"
}

cmd_run() { # run <lane> [--escalated]: the only way a lane result enters the ledger
  local l="${1:-}" esc=0 slice=- n p t0 head ext=- ts log rc s0 secs v why="" w
  [ "${2:-}" = --escalated ] && esc=1
  load_lanes
  lane_ix "$l" || die 2 "no lane '$l' in .claude/done-lanes"
  w="$(awk -F'\t' -v l="$l" '$2 == l {r = $0} END {print r}' "$TR" 2>/dev/null)"
  if [ -z "$w" ]; then
    why="never trusted"
  elif [ "$(cut -f3 <<<"$w")" != "$(h12 "${L_CMD[IX]}")" ]; then
    why="command changed since trust"
  elif [ "$(cut -f4 <<<"$w")" != "$(h12 "${L_LINE[IX]}")" ]; then
    why="lane line changed since trust"
  elif [ "$(tail -n 1 "$TR" | cut -f5)" != "$DIR_SHA" ]; then
    why="@ directives or scan rules changed since trust"
  fi
  [ -z "$why" ] || die 3 "RUN REFUSED — lane $l: $why — the human runs: bash scripts/evidence.sh trust $l"

  LOCK="$EV/locks/run-$l.lock"
  if [ -f "$LOCK" ]; then
    p="$(cut -f1 "$LOCK")"
    lock_alive "$p" &&
      die 4 "RUN REFUSED — lane $l is already running (pid $p, since $(cut -f5 "$LOCK")) — wait for its notification; do not start a second run"
    rm -f "$LOCK"
    echo "evidence: removed stale lock run-$l.lock (pid $p is gone)" >&2
  fi

  task_ctx soft && slice="$(card_current_slice "$CARD")"
  if [ "$slice" != - ]; then
    # ESCALATE (D17): consecutive fails of this lane on this slice; a pass resets, a human override counts as 1
    n="$(grep -F "\"slice\":\"$slice\"," "$EV/$l.jsonl" 2>/dev/null |
      sed -nE 's/.*"verdict":"([a-z]+)","why":"[^"]*","ack":([01]),"markers".*/\1 \2/p' |
      awk '$1 == "pass" {n = 0} $1 == "fail" {n = ($2 == 1) ? 1 : n + 1} END {print n + 0}')"
    if [ $esc = 1 ]; then
      donelog_row "$DLOG" ESCALATE "$slice" "$l" "$(lane_tree "$IX" | cut -c1-12)" - "escalated: human override"
    elif [ "$n" -ge 3 ]; then
      donelog_row "$DLOG" ESCALATE "$slice" "$l" "$(lane_tree "$IX" | cut -c1-12)" - "3 consecutive fails"
      echo "evidence: ESCALATE — lane $l failed 3 times in a row on $slice. Stop fixing. Report to the human what was tried, why each attempt failed, and what you would try next."
      echo "evidence: another attempt needs the human: bash scripts/evidence.sh run $l --escalated"
      exit 5
    fi
  fi

  ( set -C; printf '%s\trun\t%s\t%s\t%s\n' $$ "$l" "$slice" "$(now)" > "$LOCK" ) 2>/dev/null ||
    die 4 "RUN REFUSED — lane $l is already running — wait for its notification; do not start a second run"
  trap 'rm -f "$LOCK"' EXIT
  trap 'exit 130' INT TERM HUP
  t0="$(lane_tree "$IX")"
  head="$(git rev-parse -q --verify HEAD || echo -)"
  if [ -n "${EXT[IX]:-}" ]; then
    ext="$(bash -c "${EXT[IX]}" </dev/null 2>/dev/null | tr -d '[:space:]')"
    [[ "$ext" =~ ^[0-9a-f]{7,40}$ ]] || ext=invalid
  fi
  ts="$(now)"
  log="$EV/logs/$l-$(date -u +%Y%m%dT%H%M%SZ).log"
  s0=$SECONDS
  ( umask 077; exec bash -c "${L_CMD[IX]}" ) </dev/null >"$log" 2>&1
  rc=$?
  secs=$((SECONDS - s0))
  chmod 600 "$log"

  judge "$log" "${L_EXP[IX]}" "$rc" "$secs" "${L_MIN[IX]}"
  why="$J_WHY"
  [ "$why" = - ] && [ "$ext" = invalid ] && why=ext
  case "$J_SCAN" in
    clean*) ;;
    *)
      J_MKS='["withheld: scan hit"]'
      why="leak:${J_SCAN#hit:}"
      [ "$J_SCAN" = scan-error ] && why=scan-error
      ;;
  esac
  [ "$t0" = "$(lane_tree "$IX")" ] || why=changed-during-run
  v=pass
  [ "$why" = - ] || v=fail
  [ "$why" = changed-during-run ] && v=void
  record "$l.jsonl" lane="$l" slice="$slice" tree="$t0" head="$head" ext="$ext" \
    cmd_sha="$(h12 "${L_CMD[IX]}")" lane_sha="$(h12 "${L_LINE[IX]}")" exit:$rc started="$ts" secs:$secs \
    executed:$J_EXEC skipped:$J_SKIP scan="$J_SCAN" log="$log" log_sha="$(sha < "$log")" \
    verdict=$v why="$why" ack:$esc markers@"$J_MKS"
  [ -n "$DLOG" ] && donelog_row "$DLOG" RUN "$slice" "$l" "${t0:0:12}" "$RID" "$v"
  echo "evidence: $l $(printf '%s' "$v" | tr a-z A-Z) id=$RID exit=$rc secs=$secs executed=$J_EXEC markers=$J_MK scan=$J_SCAN"
  [ $v = pass ] && exit 0

  case "$why" in
    changed-during-run) w="lane files changed during the run — record voided; re-run once edits stop" ;;
    exit=*) w="exit ${why#exit=}" ;;
    leak:*|scan-error) w="the log hit a secret or internal-IP rule (${why#leak:}) — the run failed; never paste this log" ;;
    expect=*)
      split ' ; ' "${L_EXP[IX]}"
      w="expect not matched — pattern ${why#expect=} ('${S[${why#expect=} - 1]}') found no line"
      ;;
    executed=0) w="executed=0 — nothing ran (zero tests, rows or requests): unproven, not passed" ;;
    too-fast:*) w="too fast — ${secs}s is under min_secs ${L_MIN[IX]}; the work was skipped" ;;
    *) w="@ext printed no commit id" ;;
  esac
  printf 'evidence: why: %s\nevidence: log: %s\n' "$w" "$log"
  case "$J_SCAN" in
    clean*) tail -n 20 "$log" | sed 's/^/    /' ;;
  esac
  exit 1
}

cmd_start() { # start S<n>: mark it [~] and record the baseline HEAD (D15)
  local s="${1:-}" ln cur st head
  task_ctx
  ln="$(slice_line "$s")" && [ -n "$ln" ] || die 2 "no slice $s on the card"
  [ "${ln#- \[x\]}" = "$ln" ] || die 1 "$s is already [x] — reopen it (set the line back to [~]) only if the human asked"
  cur="$(card_current_slice "$CARD")"
  [ "$cur" = - ] || [ "$cur" = "$s" ] ||
    die 1 "$cur is still [~] — finish it (bash scripts/evidence.sh done $cur) or set it back to [ ] first"
  st="$(started_row "$s")"
  [ -z "$st" ] ||
    die 1 "$s already started at $(cut -f1 <<<"$st") from $(cut -f5 <<<"$st") — the first start is the baseline for done's coverage check"
  [ "$A12" = "$D12" ] ||
    die 1 "card changed since approval (approved ${A12:-never}, now card:$D12) — the human runs: bash scripts/evidence.sh approve"
  head="$(git rev-parse -q --verify HEAD | cut -c1-12)"
  sed -E "s/^- \[[ o~]\] ($s( |\$))/- [~] \1/" "$CARD" > "$CARD.tmp" && mv "$CARD.tmp" "$CARD"
  donelog_row "$DLOG" START "$s" - "${head:--}" - started
  echo "evidence: $s started at $(tail -n 1 "$DLOG" | cut -f1) from ${head:--} — done $s accepts only lane runs from now on"
}

# --- done, close and what they do not prove --------------------------------------

gap() { GAPS="$GAPS  - $1"$'\n'; }

flist() { # lines on stdin -> "a, b, c (+n more)"
  awk 'NR <= 10 {printf "%s%s", (NR > 1 ? ", " : ""), $0} END {if (NR > 10) printf " (+%d more)", NR - 10}'
}

outside() { # $1 = base ref, then covering paths -> files changed since it (or untracked) outside them
  local b="$1" f p hit
  shift
  { git diff --name-only "$b" 2>/dev/null; git ls-files --others --exclude-standard; } | sort -u |
    grep -Ev '^(\.ai_context/|\.claude/done-lanes)' |
    while IFS= read -r f; do
      hit=0
      for p in "$@"; do
        p="${p%/}"
        case "$f" in "$p"|"$p"/*) hit=1 ;; esac
        [ "$p" = . ] && hit=1
      done
      [ $hit = 1 ] || echo "$f"
    done
}

slice_gaps() { # $1 = S<n>, $2 = its card line -> GAPS, TOK (the ✓ tokens)
  local s="$1" ln="$2" st sts sh l r f p="" stree
  GAPS=""
  TOK=""
  f="$(lint_card | grep -m 1 '^CARD LINT')"
  [ -z "$f" ] || gap "$f (run: bash scripts/evidence.sh lint)"
  approval_gap
  st="$(started_row "$s")"
  sts="$(cut -f1 <<<"$st")"
  sh="$(cut -f5 <<<"$st")"
  [ -n "$st" ] || gap "no START for $s — run: bash scripts/evidence.sh start $s before working on it"

  for l in $(slice_lanes "$ln"); do
    lane_ix "$l" || continue
    p="$p ${L_PATHS[IX]}"
    r="$(lastrec "$l.jsonl")"
    f=""
    if [ -z "$r" ]; then
      f="never run"
    elif [[ "$(jget "$r" started)" < "$sts" ]]; then
      f="no run since $s started"
    elif [ "$(jget "$r" verdict)" != pass ]; then
      f="latest run $(jget "$r" id) FAILED ($(jget "$r" why))"
    elif [ "$(jget "$r" tree)" != "$(lane_tree "$IX")" ]; then
      f="content changed since pass $(jget "$r" id)"
    else
      TOK="$TOK $l@$(jget "$r" id)"
    fi
    [ -z "$f" ] || gap "lane $l: $f — re-run: bash scripts/evidence.sh run $l"
  done

  stree="$(slice_tree "$s")"
  r="$(lastrec checker.jsonl "\"unit\":\"$s\",\"tree\":\"$stree\"")"
  if [ -z "$r" ]; then
    gap "no checker record for $s at its current content — spawn the checker for $s"
  elif [ "$(jget "$r" verdict)" != pass ]; then
    gap "checker $(jget "$r" id) for $s: $(jget "$r" verdict) ($(jget "$r" not_verified) NOT VERIFIED) — fix, then re-check"
  else
    TOK="$TOK check@$(jget "$r" id)"
  fi

  if codex_yes "$ln"; then
    r="$(lastrec codex.jsonl "\"lane\":\"codex-slice\",\"unit\":\"$s\",\"tree\":\"$stree\"")"
    if [ -n "$r" ] && approving "$r"; then
      TOK="$TOK codex@$(jget "$r" id)"
    elif waived "$s" >/dev/null; then
      TOK="$TOK codex@waived"
    else
      gap "no approving codex-slice review of $s at its current content — run: bash scripts/task-pair.sh check slice $s --since ${sh:-<start head>}"
    fi
  fi

  if [ -n "$sh" ] && f="$(outside "$sh" $p | flist)" && [ -n "$f" ]; then
    gap "$s changed files outside its lanes' paths ($(echo $p)): $f — declare a lane that covers them (needs trust) or move the change to its own slice"
  fi
  TOK="${TOK# }"
}

not_proven() { # $1 = lanes, $2 = units (checker INCONCLUSIVE, waivers), $3 = 1 to name external commits (02 §0.8)
  local l r u x b
  echo "Not proven this time (what these records do not show):"
  for l in $1; do
    lane_state "$l"
    r="$(lastrec "$l.jsonl")"
    [ "$LS" = fresh ] || echo "  - lane $l: $LSD — nothing in its paths is proven at this content"
    x="$(jget "$r" skipped)"
    [ "${x:-0}" -gt 0 ] && echo "  - $l log reports $x skipped (record $LID)"
    x="$(jget "$r" ext)"
    if [ "$3" = 1 ] && [ -n "$x" ] && [ "$x" != - ]; then
      echo "  - $l ran against external commit $x; the external repo's current head is not compared here"
    fi
  done
  if [ -n "$DLOG" ]; then
    b="$(sed -nE 's/^<!-- card v4 .* base: ([0-9a-f]+) .*/\1/p' "$CARD")"
    x="${L_PATHS[*]:-}"
    x="$(outside "${b:-HEAD}" $x | flist)"
    [ -z "$x" ] || echo "  - changed since base ${b:0:7} outside every lane's paths: $x"
    for u in $2; do
      r="$(lastrec checker.jsonl "\"unit\":\"$u\",")"
      x="$(jget "$r" inconclusive)"
      [ "${x:-0}" -gt 0 ] && echo "  - checker left $x claim(s) INCONCLUSIVE on $u (record $(jget "$r" id))"
      x="$(waived "$u")" && echo "  - Codex review of $u was waived by the human: $x"
    done
  fi
  echo "  - anything the lanes' commands do not exercise (a lane proves what it runs, nothing more)"
}

cmd_done() { # done S<n>: [~] -> [x] with the evidence ids, only when no gap is left
  local s="${1:-}" ln
  task_ctx
  load_lanes
  ln="$(slice_line "$s")" && [ -n "$ln" ] || die 2 "no slice $s on the card"
  slice_gaps "$s" "$ln"
  if [ -n "$GAPS" ]; then
    printf 'evidence: NOT DONE — %s: %s gap(s):\n%s' "$s" "$(printf '%s' "$GAPS" | grep -c .)" "$GAPS"
    not_proven "$(slice_lanes "$ln")" "$s" 1
    exit 1
  fi
  sed -E "/^- \[[ ~o]\] $s /{s/^- \[[ ~o]\]/- [x]/;s/ ✓ .*\$//;s/\$/ ✓ $TOK/;}" "$CARD" > "$CARD.tmp" && mv "$CARD.tmp" "$CARD"
  donelog_row "$DLOG" DONE "$s" - "$(slice_tree "$s" | cut -c1-12)" "$(tr ' ' , <<<"$TOK")" ok
  echo "evidence: $s ✓ $TOK"
  not_proven "$(slice_lanes "$ln")" "$s" 1
}

slice_rows() { # gate view (I-2, P-4): "S<n> TAB ok|foreign|noref|bad TAB detail" per [x] line
  local ln s t n r nf oth cited
  grep -E '^- \[x\] S[0-9]+ ' "$CARD" | while IFS= read -r ln; do
    s="$(cut -d' ' -f3 <<<"$ln")"
    nf=""
    oth=""
    cited=""
    case "$ln" in
      *' ✓ '*) ;;
      *) printf '%s\tnoref\tno evidence reference\n' "$s"; continue ;;
    esac
    for t in ${ln##* ✓ }; do
      n="${t%%@*}"
      r="$(byid "${t#*@}")"
      case "$n" in check|codex) ;; *) cited="$cited $n" ;; esac
      if [ "$t" = codex@waived ]; then
        waived "$s" >/dev/null || oth="$oth; codex@waived has no waiver at card:$D12"
      elif [ -z "$r" ]; then
        nf="$nf; $t not found"
      else
        case "$n" in
          check)
            [ "$(jget "$r" lane) $(jget "$r" unit) $(jget "$r" verdict)" = "checker $s pass" ] ||
              oth="$oth; $t is not a passing checker record of $s"
            ;;
          codex)
            { [ "$(jget "$r" lane) $(jget "$r" unit)" = "codex-slice $s" ] && approving "$r"; } ||
              oth="$oth; $t is not an approving codex-slice review of $s"
            ;;
          *)
            [ "$(jget "$r" lane) $(jget "$r" verdict)" = "$n pass" ] || oth="$oth; $t is not a passing $n record"
            ;;
        esac
      fi
    done
    [ "$(printf '%s\n' $cited | sort -u)" = "$(printf '%s\n' $(slice_lanes "$ln") | sort -u)" ] ||
      oth="$oth; cites lanes ($(echo $cited)) but the slice declares ($(slice_lanes "$ln"))"
    codex_yes "$ln" && [ "${ln#* codex@}" = "$ln" ] && oth="$oth; codex@ missing (codex: yes, pair on)"
    awk -F'\t' -v s="$s" -v r="$(echo ${ln##* ✓ } | tr ' ' ,)" '$2 == "DONE" && $3 == s && $6 == r {f = 1} END {exit !f}' "$DLOG" 2>/dev/null ||
      oth="$oth; no DONE row with these ids"
    if [ -z "$nf$oth" ]; then
      printf '%s\tok\t%s\n' "$s" "${ln##* ✓ }"
    elif [ -z "$oth" ]; then
      printf '%s\tforeign\t%s\n' "$s" "${nf#; }"
    else
      r="$nf$oth"
      printf '%s\tbad\t%s\n' "$s" "$(printf '%s' "${r#; }" | tr -cd '\040-\176' | cut -c1-300)"
    fi
  done
}

final_ok() { # $1 = whole tree -> rc 0 when the final review holds there; FIN, FREC (latest record), FTOK
  if pair_on; then
    FIN=codex-final
    FREC="$(lastrec codex.jsonl '"lane":"codex-final",')"
    if [ -n "$FREC" ] && approving "$FREC" && [ "$(jget "$FREC" tree)" = "$1" ]; then
      FTOK="codex@$(jget "$FREC" id)"
    elif waived final >/dev/null; then
      FTOK=codex@waived
    else
      return 1
    fi
  else
    FIN=checker-final
    FREC="$(lastrec checker.jsonl '"unit":"final",')"
    [ -n "$FREC" ] && [ "$(jget "$FREC" verdict)" = pass ] && [ "$(jget "$FREC" tree)" = "$1" ] &&
      FTOK="check@$(jget "$FREC" id)"
  fi
}

closed_row() { # "none|ok|foreign|stale TAB detail" for the Closed: line (R11)
  local l w c det="" miss=1 last
  c="$(grep -m 1 '^Closed:' "$CARD")" || { printf 'none\t-\n'; return; }
  w="$(tree_of .)"
  for l in $(card_lanes); do
    lane_state "$l"
    [ "$LS" = fresh ] || det="$det; $l: $LS"
    [ "$LS" = fresh ] || [ "$LS" = missing ] || miss=0
  done
  if ! final_ok "$w"; then
    det="$det; $FIN: $([ -n "$FREC" ] && echo stale || echo missing)"
    [ -z "$FREC" ] || miss=0
  fi
  if [ "${c#Closed: tree:"${w:0:12}" }" = "$c" ]; then
    det="$det; tree: changed since close"
    miss=0
  fi
  last="$(awk -F'\t' '$2 == "CLOSE" {t = $5} END {print t}' "$DLOG" 2>/dev/null)"
  if [ -z "$det" ]; then
    printf 'ok\t-\n'
  elif [ $miss = 1 ] && [ "$last" = "${w:0:12}" ]; then
    printf 'foreign\t%s\n' "${det#; }"
  else
    printf 'stale\t%s\n' "${det#; }"
  fi
}

cmd_close() { # close: every slice [x], every cited lane fresh, the final review at this content (R11)
  local l x r w b tok=""
  task_ctx
  load_lanes
  GAPS=""
  x="$(sed -nE 's/^- (\[[ ~o]\]) (S[0-9]+) .*/\2 \1/p' "$CARD" | flist)"
  [ -z "$x" ] || gap "not done: $x"
  approval_gap
  while IFS=$'\t' read -r l x r; do
    case "$x" in ok|foreign) ;; *) gap "$l: $x — $r" ;; esac
  done < <(slice_rows)
  for l in $(card_lanes); do
    lane_state "$l"
    lane_ix "$l"
    if [ "$LS" = fresh ]; then
      tok="$tok $l@$LID"
    else
      gap "lane $l: $LSD — re-run: bash scripts/evidence.sh run $l"
    fi
    [ -n "${EXT[IX]:-}" ] || continue
    r="$(jget "$(lastrec "$l.jsonl")" ext)"
    x="$(bash -c "${EXT[IX]}" </dev/null 2>/dev/null | tr -d '[:space:]')"
    [ "$x" = "$r" ] || gap "lane $l: external repo moved ${r:--} -> ${x:--} since record ${LID:--} — re-run the lane"
  done
  w="$(tree_of .)"
  if final_ok "$w"; then
    tok="$tok $FTOK"
  elif pair_on; then
    b="$(sed -nE 's/^<!-- card v4 .* base: ([0-9a-f]{7}).*/\1/p' "$CARD")"
    gap "no approving codex-final review of the current content (tree:${w:0:12}) — run: bash scripts/task-pair.sh check final --since $b"
  else
    gap "no passing checker final record at the current content (tree:${w:0:12}) — spawn the checker on \"Check final\""
  fi
  if [ -n "$GAPS" ]; then
    printf 'evidence: NOT CLOSED — %s gap(s):\n%s' "$(printf '%s' "$GAPS" | grep -c .)" "$GAPS"
    not_proven "$(card_lanes)" "final card" 0
    exit 1
  fi
  x="Closed: tree:${w:0:12} head:$(git rev-parse -q --verify HEAD | cut -c1-12) ✓ ${tok# } — $(now)"
  { grep -v '^Closed:' "$CARD"; echo "$x"; } > "$CARD.tmp" && mv "$CARD.tmp" "$CARD"
  donelog_row "$DLOG" CLOSE - - "${w:0:12}" "$(tr ' ' , <<<"${tok# }")" ok
  echo "evidence: $x"
  not_proven "$(card_lanes)" "final card" 0
  echo "evidence: next: /wrap — scoreboard row: bash scripts/harness-report.sh --row $SLUG"
}

# --- the human's approval and the card lint ---------------------------------------

cmd_approve() { # approve | approve --waive <S<n>|card|final> --reason <text> (D16, R12)
  local u="${2:-}" r="" p m
  task_ctx
  lanes_soft
  if [ "${1:-}" = --waive ]; then
    [ "${3:-}" = --reason ] && r="${4:-}"
    { [ -n "$r" ] && { [ "$u" = card ] || [ "$u" = final ] || [ -n "$(slice_line "$u")" ]; }; } ||
      die 2 '--waive needs <S<n>|card|final> and --reason "<text>"'
    pair_on || die 1 "pairing is off — there is no Codex review to waive"
    donelog_row "$DLOG" WAIVE "$u" human "$D12" - "$r"
    echo "evidence: Codex review of $u waived by the human at card:$D12 — done/close accept codex@waived for it until the card changes"
    exit 0
  fi
  [ -z "${1:-}" ] || die 2 'usage: evidence.sh approve [--waive <S<n>|card|final> --reason "<text>"]'
  if ! p="$(lint_card)"; then
    printf 'evidence: approve refused — fix the card first:\n%s\n' "$(grep '^CARD LINT' <<<"$p")"
    exit 1
  fi
  m=$(grep -cE '^- \[[ ~ox]\] S[0-9]+ .* ; codex: yes' "$CARD")
  m=$((2 * (m + 1) + 1))
  donelog_row "$DLOG" APPROVE - human "$D12" - "$(pair_on && echo "codex_est=$m")"
  echo "evidence: card approved at card:$D12. Any change other than status marks, ✓ suffixes and the Closed: line needs a new approval."
  pair_on &&
    echo "evidence: Codex runs covered by this approval: $m ($(( (m - 3) / 2 )) slice reviews + final, one retry each, one rebuttal); more runs need a new ask"
}

lint_card() { # every card problem as one "CARD LINT — …" line (rc 1 when any), then warnings (D16, R8)
  local P="" e b norm n sl h base s x notes="${CARD%card.md}notes.md"
  pb() { P="$P$1"$'\n'; }
  if e="$( (load_lanes) 2>&1)"; then
    load_lanes
  else
    pb "${e#evidence: }"
  fi
  b=$(($(wc -c < "$CARD")))
  norm=$(($(sed -e 's/^- \[[ ~ox]\] /- [ ] /' -e 's/ ✓ .*$//' -e '/^Closed:/d' "$CARD" | wc -c)))
  sl="$(awk '/^## Slices/ {f = 1; next} /^## / {f = 0} f && /^- /' "$CARD")"
  n=$(printf '%s' "$sl" | grep -c .)
  [ $b -gt 4096 ] && pb "card is $b B (cap 4096)"
  [ $((norm + 80 * n + 160)) -gt 4096 ] &&
    pb "card leaves no room for evidence suffixes: $norm B + 80 B x $n slices + 160 B > 4096"

  h="$(grep -E '^<!-- card v4 ; pair: (codex|off) ; base: [0-9a-f]{7,40} ; estimate: [0-9]+(\.[0-9]+)?h [0-9]+L -->$' "$CARD" | head -n 1)"
  if [ -z "$h" ]; then
    pb "header missing or malformed; want: <!-- card v4 ; pair: codex|off ; base: <sha> ; estimate: <hours>h <lines>L -->"
  else
    base="$(sed -E 's/.* base: ([0-9a-f]+) .*/\1/' <<<"$h")"
    git rev-parse -q --verify "$base^{commit}" >/dev/null || pb "base $base is not a commit here"
    [ "$PAIR" = codex ] && [ "${h#*pair: off}" != "$h" ] &&
      pb "pair: off but .claude/done-lanes says @pair codex; a card may raise pairing, never lower it"
  fi
  grep -Eq '^Goal: *[^ ]' "$CARD" || pb "Goal: is empty"
  grep -Eq '^Done when: *[^ ;].* ; outside check: *[^ ]' "$CARD" || pb "Done when: is empty or lacks '; outside check: <who/what>'"
  while IFS= read -r x; do
    pb "decision without a [human]/[inferred]/[own]/[ASSUMED] tag: '$x'"
  done < <(awk '
      /^Decisions:/ {d = 1; sub(/^Decisions: */, ""); k = split($0, a, / ; /); for (i = 1; i <= k; i++) print a[i]; next}
      /^## Slices/ {d = 0}
      d && /^- / {sub(/^- /, ""); print}' "$CARD" | grep -Ev '^(\[(human|inferred|own|ASSUMED)\] |none$|$)')

  if ! grep -q '^## Slices' "$CARD"; then
    pb "no '## Slices' section"
  elif [ "$n" = 0 ]; then
    pb "no slices"
  fi
  while IFS= read -r x; do
    pb "slice line does not parse: '${x:0:80}'"
  done < <(printf '%s\n' "$sl" | grep -Ev "$SLICE_RE" | grep .)
  while IFS= read -r x; do
    pb "duplicate slice id $x"
  done < <(printf '%s\n' "$sl" | sed -nE 's/^- \[.\] (S[0-9]+) .*/\1/p' | awk 'c[$0]++ == 1')
  while read -r s x; do
    lane_ix "$x" || pb "$s names lane '$x' that .claude/done-lanes does not declare"
  done < <(printf '%s\n' "$sl" | grep -E "$SLICE_RE" |
             sed -E 's/^- \[.\] (S[0-9]+) .* lanes: ([a-z0-9,-]+) ; codex: .*/\1 \2/' |
             awk '{k = split($2, a, ","); for (i = 1; i <= k; i++) print $1, a[i]}')
  x=$(printf '%s\n' "$sl" | grep -c '^- \[~\]')
  [ "$x" -gt 1 ] && pb "$x slices are [~] (at most one)"
  while read -r s x; do
    grep -E '^#' "$notes" 2>/dev/null | grep -qF -- "$x" || pb "$s points at notes §$x but notes.md has no heading containing it"
  done < <(printf '%s\n' "$sl" | sed -nE 's/^- \[.\] (S[0-9]+) .* ; notes: §([^✓]*[^ ✓]).*/\1 \2/p')

  printf '%s' "$P" | sed 's/^/CARD LINT — /'
  x=$(($(wc -c 2>/dev/null < "$notes" || echo 0)))
  [ "$x" -gt 16384 ] &&
    echo "card lint warn — notes.md is $x B (> 16384); keep only constraints, interfaces, edge cases, rulings, measured facts"
  [ -z "$P" ]
}

cmd_lint() {
  local o rc
  task_ctx
  lanes_soft
  o="$(lint_card)"
  rc=$?
  [ -z "$o" ] || echo "$o"
  [ $rc = 0 ] || exit 1
  echo "card lint ok — card $(($(wc -c < "$CARD"))) B, $(grep -cE '^- \[[ ~ox]\] S[0-9]+ ' "$CARD") slices, ${#L_NAME[@]} lanes, pair $(pair_on && echo on || echo off)"
}

# --- views: status, show ------------------------------------------------------------

cmd_status() { # status [--line|--porcelain] (02 §0.9): --porcelain always exits 0
  local m="${1:-}" k p x l s r line cr tl lok
  for k in "$EV"/locks/*.lock; do
    [ -f "$k" ] && ! lock_alive "$(cut -f1 "$k")" && rm -f "$k"
  done
  TREE=-
  [ -n "$NOGIT" ] || TREE="$(tree_of .)"
  TREE="${TREE:--}"
  if ! task_ctx soft; then
    [ "$m" = --porcelain ] && printf 'TREE\t%s\nCLOSED\tnone\t-\nLINE\tno active task\n' "$TREE"
    [ -z "$m" ] && echo "evidence status — no active task"
    exit 0
  fi
  lanes_soft
  lok=$?
  cr="$(closed_row)"
  if [ ! -f "$DL" ]; then
    line="evidence[$SLUG]: no .claude/done-lanes — declare lanes before any slice can be done"
  elif [ $lok != 0 ]; then
    line="evidence[$SLUG]: .claude/done-lanes does not parse — run: bash scripts/evidence.sh lint"
  else
    x=approved
    [ -n "$A12" ] || x=unapproved
    [ -z "$A12" ] || [ "$A12" = "$D12" ] || x=changed
    line="evidence[$SLUG]: slice $(card_current_slice "$CARD")"
    line="$line ($(grep -c '^- \[x\] S[0-9]' "$CARD")/$(grep -cE '^- \[[ ~ox]\] S[0-9]+ ' "$CARD") done) · card $x"
    for ((k = 0; k < ${#L_NAME[@]}; k++)); do
      l="${L_NAME[k]}"
      lane_state "$l"
      lock_alive "$(cut -f1 "$EV/locks/run-$l.lock" 2>/dev/null)" && LS=running
      line="$line · $l $LS"
    done
    case "$cr" in
      none*) ;;
      ok*|foreign*) line="$line · closed fresh" ;;
      *) line="$line · closed stale" ;;
    esac
  fi
  if [ "$m" = --porcelain ]; then
    printf 'TREE\t%s\n' "$TREE"
    slice_rows | sed "s/^/SLICE$TAB/"
    printf 'CLOSED\t%s\nLINE\t%s\n' "$cr" "$(tr -d '"\\' <<<"$line")"
    exit 0
  fi
  tl="$(bash scripts/harness-report.sh --tripwire "$SLUG" 2>/dev/null)" || tl=""   # --tripwire lands in C6; until then no tripwire part
  if [ "$m" = --line ]; then
    case "$tl" in *TRIPPED:*) line="$line · tripwire: ${tl##*TRIPPED: }" ;; esac
    echo "$line"
    exit 0
  fi

  x=approved
  [ "$A12" = "$D12" ] || x="NOT APPROVED (last approval ${A12:-none})"
  echo "evidence status — task $SLUG · card card:$D12 $x · pair $(pair_on && echo on || echo off)"
  for ((k = 0; k < ${#L_NAME[@]}; k++)); do
    l="${L_NAME[k]}"
    lane_state "$l"
    r="$(lastrec "$l.jsonl")"
    p="$(cut -f1,5 "$EV/locks/run-$l.lock" 2>/dev/null)"
    if lock_alive "${p%%"$TAB"*}"; then
      x="running — running pid ${p%%"$TAB"*} since ${p#*"$TAB"}"
    elif [ -z "$r" ]; then
      x="$LS — no records"
    elif [ "$LS" = fail ]; then
      x="fail — fail $LID $(jget "$r" why)"
    else
      x="$LS — pass $LID $(jget "$r" started) $(jget "$r" secs)s executed=$(jget "$r" executed)"
    fi
    echo "lane $l: $x"
  done
  while IFS='|' read -r s x; do
    r="$(slice_rows | awk -F'\t' -v s="$s" '$1 == s {print ($2 == "ok" ? "refs ok: " $3 : $2 ": " $3)}')"
    if [ -z "$r" ]; then
      p="$(started_row "$s")"
      if [ -n "$p" ]; then
        r="started $(cut -f1 <<<"$p") from $(cut -f5 <<<"$p")"
      else
        r="not started"
      fi
    fi
    echo "$s [$x] — $r"
  done < <(sed -nE 's/^- \[(.)\] (S[0-9]+) .*/\2|\1/p' "$CARD")
  case "$cr" in
    none*) ;;
    ok*|foreign*) echo "Closed: fresh" ;;
    *) echo "Closed: stale (${cr#*"$TAB"})" ;;
  esac
  if pair_on; then
    awk -F'\t' -v ys="$(sed -nE 's/^- \[.\] (S[0-9]+) .*; codex: yes.*/\1/p' "$CARD" | tr '\n' ' ')" '
      $2 == "CODEX" {r[$3] = $7}
      $2 == "WAIVE" {r[$3] = "waived"}
      END {
        k = split(ys, a, " ")
        for (i = 1; i <= k; i++) s = s " " a[i] ":" (a[i] in r ? r[a[i]] : "-")
        print "codex: card " ("card" in r ? r["card"] : "-") " · final " ("final" in r ? r["final"] : "-") " · slices" s
      }' "$DLOG" 2>/dev/null
  fi
  [ -z "$tl" ] || echo "$tl"
}

cmd_show() { # show <lane|checker|codex-card|codex-slice|codex-final|@id>: a record, its log or report, the footer
  local x="${1:-}" r f log
  [ -n "$x" ] || die 2 "usage: evidence.sh show <lane|checker|codex-card|codex-slice|codex-final|@id>"
  task_ctx soft
  lanes_soft
  case "$x" in
    @*) r="$(byid "${x#@}")" ;;
    checker) r="$(lastrec checker.jsonl)" ;;
    codex-*) r="$(lastrec codex.jsonl "\"lane\":\"$x\",")" ;;
    *) r="$(lastrec "$x.jsonl")" ;;
  esac
  [ -n "$r" ] || { echo "evidence: no record for $x" >&2; exit 1; }
  echo "record: $r"
  f="$(jget "$r" lane)"
  log="$(jget "$r" log)"
  if [ "$f" = checker ]; then
    echo "report: $EV/logs/checker-$(jget "$r" id).txt"
    cat "$EV/logs/checker-$(jget "$r" id).txt" 2>/dev/null
  elif [ -n "$log" ] && [ ! -f "$log" ]; then
    echo "log missing (pruned, or recorded on another machine)"
  elif [ -n "$log" ]; then
    echo "log: $log ($(($(wc -c < "$log"))) B, sha $(sha < "$log" | cut -c1-12))"
    case "$(jget "$r" scan)" in
      clean*)
        echo "--- log tail (60 lines) ---"
        tail -n 60 "$log"
        ;;
      *) echo "log withheld: scan $(jget "$r" scan | sed 's/:/ /')" ;;
    esac
  fi
  not_proven "$([ -z "$log" ] || echo "$f")" "$(jget "$r" unit)" 1
}

# --- reviews: checker and Codex records -----------------------------------------------

cmd_check() { # check <S<n>|final|card|-> --agent <id|-> --source <src>: a checker report on stdin -> record (I-3)
  local u="${1:-}" ag="${3:-}" src="${5:-}" rep vi nv ni vl vu v tree
  [[ "$u" =~ ^(S[0-9]+|final|card|-)$ ]] && [ "${2:-}" = --agent ] && [ -n "$ag" ] && [ "${4:-}" = --source ] &&
    [[ "$src" =~ ^(handback|last_message|transcript|human|none)$ ]] ||
    die 2 "usage: evidence.sh check <S<n>|final|card|-> --agent <id|-> --source <handback|last_message|transcript|human|none>"
  task_ctx
  lanes_soft
  rep="$(cat)"
  vi=$(grep -cE '^(- )?VERIFIED \(L[1-5]\) ' <<<"$rep")
  nv=$(grep -cE '^(- )?NOT VERIFIED \(L[1-5]\) ' <<<"$rep")
  ni=$(grep -cE '^(- )?INCONCLUSIVE \(L[1-5]\) ' <<<"$rep")
  vl="$(grep -E '^checker-verdict: (S[0-9]+|final|card) (pass|fail)[[:space:]]*$' <<<"$rep" | tail -n 1)"
  vu="$(cut -d' ' -f2 <<<"$vl")"
  [ "$u" = - ] && u="${vu:-$(card_current_slice "$CARD")}"
  if [ -z "$rep" ]; then
    v=uncaptured
  elif [ -z "$vl" ]; then
    v=unparsed
  elif [ "$vu" != "$u" ]; then
    v=fail
  elif [ "$(cut -d' ' -f3 <<<"$vl" | tr -d '[:space:]')" = pass ] && [ "$nv" = 0 ] && [ "$vi" -ge 1 ]; then
    v=pass
  else
    v=fail
  fi
  case "$u" in
    S*) tree="$(slice_tree "$u")" ;;
    final) tree="$(tree_of .)" ;;
    card) tree="$DIG" ;;
    *) tree=- ;;
  esac
  record checker.jsonl lane=checker unit="$u" tree="$tree" head="$(git rev-parse -q --verify HEAD || echo -)" \
    agent_id="$ag" source="$src" verified:$vi not_verified:$nv inconclusive:$ni verdict=$v \
    report_sha="$(printf '%s\n' "$rep" | sha)" ts="$(now)"
  (umask 077; printf '%s\n' "$rep" > "$EV/logs/checker-$RID.txt")
  rev_tail CHECK "$u" checker "$tree" "$v"
  if [ $v = fail ] && [ "$nv" -gt 0 ] && [ "$u" != card ]; then
    defect "$u" checker unrated "checker $u: $nv NOT VERIFIED claim(s)" "check@$RID" "$nv"
  fi
  echo "check $u $v $RID"
}

cmd_codex() { # codex <packet> <result> <state> <reason>: one settled Codex run -> record (task-pair.sh finish)
  local pk="${1:-}" res="${2:-}" st="${3:-}" hd stage u base p v=none b=0 ma=0 mi=0 tree ro prov=missing prev x
  [ $# = 4 ] && [[ "$st" =~ ^(completed|failed|blocked)$ ]] ||
    die 2 "usage: evidence.sh codex <packet> <result> <completed|failed|blocked> <reason>"
  hd="$(head -n 20 "$pk" 2>/dev/null)"
  stage="$(sed -n 's/^stage: *//p' <<<"$hd" | head -n 1)"
  u="$(sed -n 's/^unit: *//p' <<<"$hd" | head -n 1)"
  base="$(sed -n 's/^base: *//p' <<<"$hd" | head -n 1)"
  [[ "$stage" =~ ^(card|slice|final)$ ]] && [ -n "$u" ] && [ -n "$base" ] || die 2 "packet needs stage:, unit: and base: lines"
  task_ctx
  lanes_soft

  # the result counts only with all six header lines, each key once
  p="$(head -n 6 "$res" 2>/dev/null | tr -d '\r')"
  if [ "$(grep -cE '^(run: (completed|failed|blocked)|verdict: (pass|fail|inconclusive)|base: .+|(blocker|major|minor): [0-9]+)$' <<<"$p")" = 6 ] &&
     [ "$(cut -d: -f1 <<<"$p" | sort -u | grep -c .)" = 6 ]; then
    v="$(sed -n 's/^verdict: //p' <<<"$p")"
    b="$(sed -n 's/^blocker: //p' <<<"$p")"
    ma="$(sed -n 's/^major: //p' <<<"$p")"
    mi="$(sed -n 's/^minor: //p' <<<"$p")"
  fi
  case "$stage" in
    card) tree="$DIG" ;;
    slice) tree="$(slice_tree "$u")" ;;
    *) tree="$(tree_of .)" ;;
  esac
  ro="${PAIR_ROLLOUT:-?}"
  ro="${ro/#"$HOME"/\~}"
  [[ "${PAIR_SECS:-}" =~ ^[0-9]+$ ]] || PAIR_SECS=0
  if [ -f "${PAIR_ROLLOUT:-}" ]; then
    prov=mismatch
    grep -qF -- "$pk" "$PAIR_ROLLOUT" && prov=ok
  fi
  prev="$(lastrec codex.jsonl "\"lane\":\"codex-$stage\",\"unit\":\"$u\",")"
  record codex.jsonl lane="codex-$stage" unit="$u" tree="$tree" head="$(git rev-parse -q --verify HEAD || echo -)" base="$base" \
    run_state="$st" reason="$4" verdict="$v" critical:$b high:$ma minor:$mi model="${PAIR_MODEL:-?}" rollout="$ro" prov=$prov \
    packet_sha="$(sha < "$pk")" result_sha="$( [ -f "$res" ] && sha < "$res" || echo -)" secs:$PAIR_SECS ts="$(now)"

  x=reject
  [ "$st $v $b $ma" = "completed pass 0 0" ] && x=approve
  [ "$v" = none ] && x=none
  rev_tail CODEX "$u" "codex-$stage" "$tree" "$x"
  if [ "$v" != none ] && [ "$stage" != card ]; then
    [ "$b" -gt 0 ] && defect "$u" codex blocker "codex-$stage $u: $b blocker finding(s)" "codex@$RID" "$b"
    [ "$ma" -gt 0 ] && defect "$u" codex major "codex-$stage $u: $ma major finding(s)" "codex@$RID" "$ma"
  fi
  if [ "$v" = none ] && [ "$(jget "$prev" verdict)" = none ] && [ "$(jget "$prev" tree)" = "$tree" ]; then
    echo "evidence: codex no verdict twice — $u at this content; the human must look (tasks/$SLUG/pair/). done/close stay refused until an approving run or a waiver (approve --waive)" >&2
  fi
  echo "$RID"
}

case "${1:-}" in
  trust) shift; cmd_trust "$@" ;;
  run) shift; cmd_run "$@" ;;
  start) shift; cmd_start "$@" ;;
  done) shift; cmd_done "$@" ;;
  close) shift; cmd_close "$@" ;;
  approve) shift; cmd_approve "$@" ;;
  lint) shift; cmd_lint "$@" ;;
  status) shift; cmd_status "$@" ;;
  show) shift; cmd_show "$@" ;;
  check) shift; cmd_check "$@" ;;
  codex) shift; cmd_codex "$@" ;;
  *) echo "usage: evidence.sh trust|run|start|done|close|approve|lint|status|show|check|codex … (see the header)" >&2; exit 2 ;;
esac
exit 0
