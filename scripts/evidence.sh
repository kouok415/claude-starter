#!/usr/bin/env bash
# evidence.sh — claude-starter v4: the only writer of task evidence. Lanes are declared in
# .claude/done-lanes (format: .claude/skills/task/reference.md §Lanes); records, logs and
# pid locks live per machine in .claude/evidence/ (gitignored); tasks/<slug>/donelog is the tracked side.
#   trust <lane> [--skip-canary] · approve [--waive <S<n>|card|final> --reason <text>]   (the human)
#   run <lane> [--escalated] · start S<n> · done S<n> · close · lint · show <lane|checker|codex-*|@id>
#   status [--line|--porcelain|--tree <S<n>|final>] · check <S<n>|final|card|-> --agent <id|-> --source <src>  (stdin)
#   codex <packet> <result> <completed|failed|blocked> <reason>                           (task-pair.sh)
# Opt-in statusline: "statusLine": {"type": "command", "command": "bash scripts/evidence.sh status --line"}
# Logs are never pruned automatically: find .claude/evidence/logs -mtime +30 -delete
# Exit: 0 ok/pass · 1 fail or refused · 2 usage/format · 3 not allowed now · 4 busy · 5 ESCALATE · 6 internal
# shellcheck disable=SC2046,SC2086  # lane paths and lane lists split on purpose
set -uo pipefail
case "$0" in */*) cd "${0%/*}/.." ;; *) cd .. ;; esac || exit 6
export LC_ALL=C

EV=.claude/evidence
DL=.claude/done-lanes
TR=.claude/done-lanes.trust
PAIR=off
DLOG=""
NOGIT=""
NOLEDGER=""
IX=0
TAB=$'\t'
L_NAME=(); L_PATHS=(); L_MIN=(); L_EXP=(); L_CAN=(); L_CMD=(); L_LINE=(); EXT=(); MEMO=(); TREE=""; SIDX=""; SNEST=""; LCHK=""; HC=(); HL=(); HN=(); TW=()
LSK=(); LSI=(); LSE=(); LSV=(); BYK=(); BYV=(); DF=(); FS=(); DT=(); TROW=(); JV=""; JR=""; TWHY=""; SM_LANES=""; SM_CODEX=""
# A slice line is "<approved text>[ ✓ <tokens>]": lanes and codex are read only from the text before its first
# ' ✓ ', and after it nothing but evidence tokens may follow (review #1). SLICE_RE matches the text before.
SLICE_RE='^- \[[ ~ox]\] S[0-9]+ .+ (—|--) lanes: [a-z][a-z0-9-]*(,[a-z][a-z0-9-]*)* ; codex: (yes|no)( ; notes: §[^✓]+)?$'
TOK='([a-z][a-z0-9-]*@[0-9a-f]{8}|codex@waived)'
TOKS_RE="^( $TOK)+\$"
CLOSED_RE="^Closed: tree:[0-9a-f]{12} head:[0-9a-f]{12} ✓( $TOK)+ — [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\$"

die() { local rc="$1"; shift; printf 'evidence: %s\n' "$*" >&2; exit "$rc"; }
now() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
SHA=(sha256sum); command -v sha256sum >/dev/null 2>&1 || SHA=(shasum -a 256)
sha() { local s; s="$("${SHA[@]}")"; printf '%s\n' "${s:0:64}"; }
h12() { local s; s="$(printf '%s' "$1" | "${SHA[@]}")"; echo "${s:0:12}"; }

# shellcheck source=../.claude/hooks/guard-patterns.sh
. .claude/hooks/guard-patterns.sh 2>/dev/null
for f in static_only donelog_row lock_alive task_slug card_current_slice; do
  declare -F "$f" >/dev/null || die 6 ".claude/hooks/guard-patterns.sh is missing or predates v4 — re-sync the template"
done
[ -n "${GUARD_SLICE_X:-}" ] || die 6 ".claude/hooks/guard-patterns.sh predates the shared done-slice regex — re-sync the template"
if ! GITP="$(git rev-parse --is-inside-work-tree --show-prefix 2>/dev/null)"; then
  NOGIT="not inside a git work tree"
elif case "$GITP" in *$'\n'*) [ -n "${GITP#*$'\n'}" ] ;; *) false ;; esac; then   # review #7: trees would hash the wrong paths
  NOGIT="the project root is not the git top level ($(git rev-parse --show-toplevel 2>/dev/null)) — give the project its own repository"
fi
[ -z "$NOGIT" ] || [ "${1:-}" = status ] || die 6 "$NOGIT"
if [ "${1:-}" != status ]; then
  git check-ignore -q "$EV/x" || die 6 ".claude/evidence/ is not gitignored — add it to .gitignore first (logs must never be committed)"
  (umask 077; mkdir -p "$EV/logs" "$EV/locks")
elif ! git check-ignore -q "$EV/x" 2>/dev/null; then
  EV=/nonexistent/evidence-not-gitignored   # review #24: an unignored ledger is not this machine's own; status reads none
  NOLEDGER=".claude/evidence/ is not gitignored, so its records are not read — add it to .gitignore"
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
    [ "${L_NAME[i]}" = "$1" ] && { IX=$i; return 0; }
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
        [[ "$ln" =~ [[:space:]]+#.*$ ]] && ln="${ln:0:${#ln}-${#BASH_REMATCH[0]}}"   # sed -E 's/[[:space:]]+#.*$//', no fork
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
        [[ "${S[0]}" =~ ^[a-z][a-z0-9-]{0,23}$ ]] && case "${S[0]}" in check|checker|final|card|codex*) false ;; esac ||
          bad $n "bad lane name '${S[0]}'"
        for p in ${S[1]}; do
          case "$p" in /*|*..*) bad $n "bad path '$p'" ;; esac
        done
        lane_ix "${S[0]}" && bad $n "duplicate lane '${S[0]}'"
        [[ "${S[2]}" =~ ^[0-9]+(\.[0-9]{1,3})?$ ]] && ms_of "${S[2]}" && [ "$MS" -ge 100 ] ||
          bad $n "min_secs must be a number >= 0.1 (got '${S[2]}')"
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
    [ -z "${EXT[IX]:-}" ] || bad "$n" "a second @ext for lane '$x'"
    EXT[IX]="$p"
  done <<< "$ext"
  # rc 1 when gitleaks.toml cannot be read (lanes_soft then loads nothing), as the piped cat has always made it;
  # lanes_soft's trial run (LCHK) only asks whether cat could read it
  if [ -n "$LCHK" ]; then [ -r .claude/gitleaks.toml ] && [ ! -d .claude/gitleaks.toml ]; return; fi
  DIR_SHA="$( { printf '%s' "$dirs"; cat .claude/gitleaks.toml 2>/dev/null; } | sha)" || { DIR_SHA="${DIR_SHA:0:12}"; return 1; }
  DIR_SHA="${DIR_SHA:0:12}"
}

lanes_soft() { # load_lanes when .claude/done-lanes parses; rc != 0 (nothing loaded) otherwise
  (LCHK=1; load_lanes) >/dev/null 2>&1 && load_lanes
}

# --- task, card, approval ------------------------------------------------------

task_ctx() { # -> SLUG CARD DLOG DIG D12 A12; $1 = soft: rc 1 instead of exiting without a task or card
  local s
  s="$(task_slug .)" || { [ -n "${1:-}" ] && return 1; die 3 "no active task (.ai_context/tasks/CURRENT)"; }
  [ -f ".ai_context/tasks/$s/card.md" ] || { [ -n "${1:-}" ] && return 1; die 2 "no card at .ai_context/tasks/$s/card.md"; }
  SLUG="$s" CARD=".ai_context/tasks/$s/card.md" DLOG=".ai_context/tasks/$s/donelog"
  DIG="$(card_norm "$CARD" | "${SHA[@]}")"
  DIG="card:${DIG:0:64}"
  D12="${DIG:5:12}"
  A12="$(awk -F'\t' '$2 == "APPROVE" {a = $5} END {print a}' "$DLOG" 2>/dev/null)"
  return 0
}

# The card digest (02 §0.4, review #1/#11) — task-pair.sh card_digest() copies card_norm byte for byte:
#   only on a slice line (^- \[[ ~ox]\] S[0-9]+ ) is the mark set to [ ] and a trailing " ✓" + " <token>"... run
#   dropped (token: <name>@<8 hex> | codex@waived); only the LAST line is dropped, and only when it is a whole
#   Closed: line in close's format (CLOSED_RE). Other text after a ✓, or a Closed: line elsewhere, stays in.
card_norm() { sed -E -e "/^- \[[ ~ox]\] S[0-9]+ /{s/^- \[[ ~ox]\] /- [ ] /;s/ ✓( $TOK)+\$//;}" -e "\${/$CLOSED_RE/d;}" "$1"; }

slice_line() { [[ "$1" =~ ^S[0-9]+$ ]] && grep -m 1 -E "^- \[[ ~ox]\] $1( |\$)" "$CARD"; }
SM_RE='.* lanes: ([a-z0-9,-]+) ; codex: (yes|no)( ; notes: .*)?$'
slice_meta() { # $1 = slice line -> SM_LANES (a,b) and SM_CODEX (yes|no), empty when it does not parse; read before its first ' ✓ ' (review #1)
  SM_LANES="" SM_CODEX=""
  [[ "${1%% ✓ *}" =~ $SM_RE ]] && SM_LANES="${BASH_REMATCH[1]}" SM_CODEX="${BASH_REMATCH[2]}"
  return 0
}
slice_ok() { # $1 = slice line -> rc 0 when the approved part parses and only tokens follow its first ' ✓ '
  [[ "${1%% ✓ *}" =~ $SLICE_RE ]] && { [ "${1#* ✓ }" = "$1" ] || [[ " ${1#* ✓ }" =~ $TOKS_RE ]]; }
}
slice_lanes() { slice_meta "$1"; [ -z "$SM_LANES" ] || printf '%s\n' "${SM_LANES//,/ }"; }
pair_on() { [ "$PAIR" = codex ] || grep -Eq '^<!-- card v4 .*pair: codex' "$CARD"; }
codex_yes() { slice_meta "$1"; [ "$SM_CODEX" = yes ] && pair_on; }
card_base() { sed -nE 's/^<!-- card v4 .* base: ([0-9a-f]+) .*/\1/p' "$CARD" | head -n 1; }

waived() { # $1 = unit -> the reason of its WAIVE row at the current card digest; rc 1 when there is none
  awk -F'\t' -v u="$1" -v d="$D12" '$2 == "WAIVE" && $3 == u && $5 == d {r = $7; f = 1} END {print r; exit !f}' "$DLOG" 2>/dev/null
}

started_row() { # $1 = S<n> -> its open START row (none once a DONE row follows)
  awk -F'\t' -v s="$1" '$3 == s && $2 == "START" {r = $0} $3 == s && $2 == "DONE" {r = ""} END {print r}' "$DLOG" 2>/dev/null
}

card_lanes() { # every lane a slice cites: the declared ones in done-lanes order, then undeclared ones (review #2)
  local all=" " ln i l
  while IFS= read -r ln; do   # " a b " — each lane once, in first-cited order
    slice_meta "$ln"
    for l in ${SM_LANES//,/ }; do case "$all" in *" $l "*) ;; *) all="$all$l " ;; esac; done
  done < <(grep -E '^- \[[ ~ox]\] S[0-9]+ ' "$CARD")
  [ "$all" != " " ] || all="  "
  for ((i = 0; i < ${#L_NAME[@]}; i++)); do
    case "$all" in *" ${L_NAME[i]} "*) echo "${L_NAME[i]}"; all="${all/ ${L_NAME[i]} / }" ;; esac
  done
  printf '%s\n' $all
}

card_reviewed() { # an approving codex-card review of the current card in this task, or a waiver for it
  local r
  r="$(lastrec codex.jsonl "\"lane\":\"codex-card\",\"unit\":\"card\",\"tree\":\"$DIG\",\"task\":\"$SLUG\",")"
  { [ -n "$r" ] && approving "$r"; } || waived card >/dev/null
}

approval_gap() {
  [ "$A12" = "$D12" ] ||
    gap "card changed since approval (approved ${A12:-never}, now card:$D12) — the human runs: bash scripts/evidence.sh approve"
  ! pair_on || card_reviewed || gap "no approving codex-card review of card:$D12 — run: bash scripts/task-pair.sh check card"
}

# --- content trees (02 §0.4) and the ledger -------------------------------------

tree_of() { # $@ = paths ('.' = whole repo) -> one content id; .ai_context/ and .claude/evidence/ never count
  # The worktree goes into a scratch copy of the index (its stat cache skips unchanged files) with update-index
  # --info-only, so nothing is written to .git/objects (review H2); the id hashes the paths' ls-files -s entries.
  # A nested repository or submodule adds its own worktree content, not only its HEAD (#15). Any git failure
  # (an unreadable file, no git top level) gives "error:<unique>", which equals nothing (#3). status shares one
  # scratch index (SIDX, share_index) across its trees; every other command hashes afresh per call.
  # TREE_DUMP=<file>: the hashed listing is written there too, so changed_paths can name what moved.
  local idx="$SIDX" out
  [ -n "$idx" ] || idx="$(mktemp "${TMPDIR:-/tmp}/evidence-idx.XXXXXX")" || { echo "error:${BASHPID:-$$}.$RANDOM"; return 1; }
  if [ -z "$NOGIT" ] && out="$(
    [ $# -gt 0 ] || exit 0
    [ -n "$SIDX" ] || ri="$(git rev-parse --git-path index)" || exit 1   # the real index, before GIT_INDEX_FILE names the copy
    export GIT_INDEX_FILE="$idx"
    X=(':(exclude).ai_context' ':(exclude).claude/evidence')
    if [ -n "$SIDX" ] && [ -z "$SNEST" ]; then   # share_index saw no untracked repository: none to list
      l=""
    elif [ -n "$SIDX" ]; then   # l only names nested repos here: unquoted names as -z gives them, unless one needed quoting
      l="$(git -c core.quotepath=false ls-files -co --exclude-standard -- "$@" "${X[@]}")" || exit 1
      case $'\n'"$l" in *$'\n"'*) l="$(git ls-files -z -co --exclude-standard -- "$@" "${X[@]}" | tr '\0' '\n')" || exit 1 ;; esac
    else
      cp "$ri" "$idx" 2>/dev/null || rm -f "$idx"
      unmark "$idx"
      l="$(git ls-files -z -co --exclude-standard -- "$@" "${X[@]}" | tr '\0' '\n')" || exit 1
      printf '%s\n' "$l" | tr '\n' '\0' | git update-index --add --remove --info-only -z --stdin 2>/dev/null || exit 1
    fi
    s="$(git ls-files -s -- "$@" "${X[@]}")" || exit 1
    printf '%s\n' "$s"
    g=""   # a line ending in / (an untracked repository) or a gitlink: only then the nested pass
    case "$l"$'\n' in */$'\n'*) g=1 ;; esac
    case $'\n'"$s" in *$'\n'"160000 "*) g=1 ;; esac
    [ -z "$g" ] || { grep '/$' <<<"$l"; awk -F'\t' '$1 ~ /^160000 / {print $2}' <<<"$s"; } | while IFS= read -r g; do
      s="$(unset GIT_INDEX_FILE TREE_DUMP; cd "$g" && SIDX="" tree_of .)" && [ "${s#error:}" = "$s" ] && echo "${g%/} $s" || exit 1
    done
  )" && { [ -z "${TREE_DUMP:-}" ] || printf '%s\n' "$out" > "$TREE_DUMP"; } && out="$(printf '%s\n' "$out" | git hash-object --stdin)"; then echo "$out"
  else echo "error:${BASHPID:-$$}.${idx##*.}"; fi
  [ -n "$SIDX" ] || rm -f "$idx"
}
share_index() { # status (H2): one scratch index of the whole worktree; on any failure each tree hashes on its own
  # SNEST: update-index's stderr. It names every untracked repository ("Ignoring path <dir>/"); empty, the
  # worktree has none, so a tree on this index needs no listing of its own to find one.
  [ -z "$NOGIT" ] && SIDX="$(mktemp "${TMPDIR:-/tmp}/evidence-idx.XXXXXX")" || return 0
  trap 'rm -f "$SIDX"' EXIT
  cp "$(git rev-parse --git-path index)" "$SIDX" 2>/dev/null || rm -f "$SIDX"
  unmark "$SIDX"
  SNEST="$(GIT_INDEX_FILE="$SIDX" git ls-files -z -co --exclude-standard -- . ':(exclude).ai_context' ':(exclude).claude/evidence' |
    GIT_INDEX_FILE="$SIDX" git update-index --add --remove --info-only -z --stdin 2>&1 >/dev/null)" || { rm -f "$SIDX"; SIDX=""; }
}

unmark() { # $1 = a scratch index: its assume-unchanged and skip-worktree marks cleared, so every tracked file is
  # hashed from the worktree — status and run alike (the real index's copy carries the marks; git status skips them)
  [ -n "$(GIT_INDEX_FILE="$1" git ls-files -v 2>/dev/null | grep -m 1 '^[a-zS] ')" ] || return 0
  GIT_INDEX_FILE="$1" git ls-files -z | GIT_INDEX_FILE="$1" git update-index --no-assume-unchanged -z --stdin 2>/dev/null
  GIT_INDEX_FILE="$1" git ls-files -z | GIT_INDEX_FILE="$1" git update-index --no-skip-worktree -z --stdin 2>/dev/null
  return 0
}
changed_paths() { # $1 $2 = a lane's TREE_DUMP listings before and after -> " (<up to 5 paths that differ>)", or nothing
  [ -s "${1:-}" ] && [ -s "${2:-}" ] || return 0
  sort "$1" "$2" | uniq -u | awk -F'\t' 'NF > 1 {print $2; next} {sub(/ [^ ]+$/, ""); print}' | sort -u |
    awk 'NR <= 5 {o = o (NR > 1 ? ", " : "") $0} END {if (NR > 5) o = o ", …"; if (NR) printf " (%s)", o}'
}
dump_init() { TDUMP="$(mktemp "${TMPDIR:-/tmp}/evidence-tree.XXXXXX" 2>/dev/null)" || TDUMP=""; }   # for changed_paths
lane_tree() { tree_of ${L_PATHS[$1]}; }
lane_memo() { # $1 = lane index -> MEMO[$1]: its tree, hashed once per call (H2) and shared by lanes with the same paths
  local j
  [ -z "${MEMO[$1]:-}" ] || return 0
  for ((j = 0; j < ${#L_NAME[@]}; j++)); do
    [ -n "${MEMO[j]:-}" ] && [ "${L_PATHS[j]}" = "${L_PATHS[$1]}" ] && { MEMO[$1]="${MEMO[j]}"; return 0; }
  done
  MEMO[$1]="$(lane_tree "$1")"
}
slice_paths() { # $1 = S<n> -> the union of its declared lanes' paths, one per line
  local l p=""
  for l in $(slice_lanes "$(slice_line "$1")"); do lane_ix "$l" && p="$p ${L_PATHS[IX]}"; done
  printf '%s\n' $p | sort -u
}
slice_tree() { tree_of $(slice_paths "$1"); }

REC_DROP=$'[",\\\\\t\r\n]'   # what record() drops from a string: " , \ TAB CR LF (was tr -d '",\\\t\r\n')
record() { # $1 = ledger, then key=str | key:int | key@raw (markers, last); one JSON line whose strings hold no " , \ TAB; sets RID
  local f="$EV/$1" a k v body="" vals=""
  shift
  for a in "$@"; do
    k="${a%%[=:@]*}"
    v="${a:${#k}+1}"
    case "${a:${#k}:1}" in
      =) v="${v//$REC_DROP/}"; body="$body,\"$k\":\"$v\"" ;;
      :) v="${v:-0}"; body="$body,\"$k\":$v" ;;
      *) body="$body,\"$k\":$v" ;;
    esac
    vals="$vals$v"
  done
  RID="$(printf '%s' "$vals" | "${SHA[@]}")"
  RID="${RID:0:8}"
  printf '{"id":"%s"%s}\n' "$RID" "$body" >> "$f"
}

jv() { # $1 = record, $2 = key -> JV: its value (empty when absent); jget without the subshell
  local re=".*[{,]\"$2\":\"?([^\",}]*)"
  JV=""
  [[ "${1%%,\"markers\":*}" =~ $re ]] && JV="${BASH_REMATCH[1]}"
  return 0
}
jvs() { # $1 = record, then keys -> JV: their values joined by one space, as "$(jget r a) $(jget r b)" gives them
  local r="$1" k o=""
  shift
  for k in "$@"; do jv "$r" "$k"; o="$o $JV"; done
  JV="${o# }"
}
jget() { jv "$1" "$2"; [ -z "$JV" ] || printf '%s\n' "$JV"; }
lastrec() { # $1 = ledger(s), $2 [$3] = fixed strings the line must hold -> the last such line
  A="${2:-\"id\"}" B="${3:-\"id\"}" awk 'index($0, ENVIRON["A"]) && index($0, ENVIRON["B"]) {r = $0} END {if (r != "") print r}' "$EV"/$1 2>/dev/null
}
byid() { [[ "$1" =~ ^[0-9a-f]{8}$ ]] && lastrec "*.jsonl" "{\"id\":\"$1\""; }
byids() { # $@ = record ids -> BYK[i] / BYV[i]: each 8-hex id and what byid prints for it, from one awk pass
  local i=0 k
  BYK=() BYV=()
  for k in "$@"; do [[ "$k" =~ ^[0-9a-f]{8}$ ]] && BYK+=("$k"); done
  [ ${#BYK[@]} -gt 0 ] || return 0
  while IFS= read -r k; do BYV[i]="$k"; i=$((i + 1)); done < <(A="${BYK[*]}" awk '
    BEGIN {n = split(ENVIRON["A"], I, " ")}
    {for (i = 1; i <= n; i++) if (index($0, "{\"id\":\"" I[i] "\"")) r[i] = $0}
    END {for (i = 1; i <= n; i++) print r[i]}' "$EV"/*.jsonl 2>/dev/null)
}
byid_of() { # $1 = id -> JR: its record from the last byids (byid's answer), empty when not looked up or not found
  local i
  JR=""
  for ((i = 0; i < ${#BYK[@]}; i++)); do [ "${BYK[i]}" = "$1" ] && { JR="${BYV[i]:-}"; return 0; }; done
  return 0
}
approving() { jvs "$1" run_state verdict critical high prov; [ "$JV" = "completed pass 0 0 ok" ]; }

DEF_NP='[!A-Za-z0-9._/+@-]'   # a field's words are its runs of these bytes (was tr -c 'A-Za-z0-9._/+@-' '\n')
def_files() { # $1 = a cmd or canary field -> DF[]: the repo files its words name, in order (review #8)
  local w
  DF=()
  for w in ${1//$DEF_NP/$'\n'}; do
    case "$w" in /*|*..*) continue ;; esac
    [ -f "$w" ] && DF+=("$w")
  done
  return 0
}
files_sha() { # $@ = files -> FS[i]: what `sha < file` prints for each; one hasher run when all are readable
  local f i=0 ln ok=1
  FS=()
  [ $# -gt 0 ] || return 0
  for f in "$@"; do [ -r "$f" ] || ok=""; done
  if [ -n "$ok" ]; then
    while IFS= read -r ln; do FS[i]="${ln:0:64}"; i=$((i + 1)); done < <("${SHA[@]}" -- "$@" 2>/dev/null)
  fi
  if [ "$i" != $# ]; then   # an unreadable file or a short answer: one file at a time, as before
    i=0
    FS=()
    for f in "$@"; do FS[i]="$(sha < "$f")"; i=$((i + 1)); done
  fi
}
def_texts() { # $@ = cmd or canary fields -> DT[i]: field i plus "LF<path> <sha256>" for each repo file it names
  local a all=() n=() i=0 j k=0
  for a in "$@"; do
    def_files "$a"
    n+=(${#DF[@]})
    all+=(${DF[@]+"${DF[@]}"})
  done
  files_sha ${all[@]+"${all[@]}"}
  DT=()
  for a in "$@"; do
    DT[i]="$a"
    for ((j = 0; j < n[i]; j++)); do DT[i]="${DT[i]}"$'\n'"${all[k]} ${FS[k]}"; k=$((k + 1)); done
    i=$((i + 1))
  done
}
def_sha() { # $1 = a cmd or canary field -> sha256[:12] of it plus "LF<path> <sha256>" for each repo file it names (review #8)
  def_texts "$1"
  h12 "${DT[0]}"
}
head_texts() { # $1 = commit, then cmd or canary fields -> DT[i]: def_texts' text, each word that is a file at that commit read from there
  local h="$1" a w i=0
  shift
  DT=()
  for a in "$@"; do
    DT[i]="$a"
    for w in ${a//$DEF_NP/$'\n'}; do
      case "$w" in /*|*..*) continue ;; esac
      [ "$(git cat-file -t "$h:$w" 2>/dev/null)" = blob ] && DT[i]="${DT[i]}"$'\n'"$w $(git cat-file blob "$h:$w" | sha)"
    done
    i=$((i + 1))
  done
}

lane_defs() { # $1 = lane index -> HC HL HN [$1]: its cmd, line and canary hashes, once per call (H2); HD, TROW
  local a="" b="" c=""
  if [ -z "${HC[$1]:-}" ]; then   # def_sha, h12, def_sha in two hasher runs: the files both fields name, then the three texts
    def_texts "${L_CMD[$1]}" "${L_CAN[$1]}"
    { IFS= read -r a; IFS= read -r b; IFS= read -r c; } < <("${SHA[@]}" <(printf '%s' "${DT[0]}") <(printf '%s' "${L_LINE[$1]}") <(printf '%s' "${DT[1]}"))
    HC[$1]="${a:0:12}" HL[$1]="${b:0:12}" HN[$1]="${c:0:12}"
  fi
  trust_rows
}
lane_defs_all() { # lane_defs for every lane (status asks them all): two hasher runs in all, not two per lane
  local i f=() h=() ln
  for ((i = 0; i < ${#L_NAME[@]}; i++)); do f+=("${L_CMD[i]}" "${L_CAN[i]}"); done
  [ ${#f[@]} -gt 0 ] || return 0
  def_texts "${f[@]}"   # DT[2i] = lane i's cmd text, DT[2i + 1] its canary text; load_lanes allows 3 lanes at most
  while IFS= read -r ln; do h+=("${ln:0:12}"); done < <("${SHA[@]}" \
    <(printf '%s' "${DT[0]}") <(printf '%s' "${L_LINE[0]}") <(printf '%s' "${DT[1]}") \
    <(printf '%s' "${DT[2]:-}") <(printf '%s' "${L_LINE[1]:-}") <(printf '%s' "${DT[3]:-}") \
    <(printf '%s' "${DT[4]:-}") <(printf '%s' "${L_LINE[2]:-}") <(printf '%s' "${DT[5]:-}"))
  for ((i = 0; i < ${#L_NAME[@]}; i++)); do HC[i]="${h[3 * i]:-}" HL[i]="${h[3 * i + 1]:-}" HN[i]="${h[3 * i + 2]:-}"; done
  trust_rows
}
trust_rows() { # -> HD (dir_sha of the trust file's last row) and TROW[i] (lane i's last row), one awk per call
  local i=0 ln
  [ -z "${HD+x}" ] || return 0
  HD=""
  TROW=()
  { IFS= read -r HD; while IFS= read -r ln; do TROW[i]="$ln"; i=$((i + 1)); done; } < <(A="${L_NAME[*]}" awk -F'\t' '
    BEGIN {n = split(ENVIRON["A"], a, " ")}
    !/^#/ {d = $5}
    {for (i = 1; i <= n; i++) if ($2 == a[i]) r[i] = $0}
    END {print d; for (i = 1; i <= n; i++) print r[i]}' "$TR" 2>/dev/null)
}
trust_note() { # $1 = lane index -> TWHY: why its current definition is not trusted; empty when it is (02 §0.2)
  local w c l n
  lane_defs "$1"
  w="${TROW[$1]:-}"
  IFS=$'\t' read -r _ _ c l _ n _ <<<"$w"
  if [ -z "$w" ]; then TWHY="never trusted"
  elif [ "$c" != "${HC[$1]}" ]; then TWHY="command changed since trust (its text or a repo file it names)"
  elif [ "$l" != "${HL[$1]}" ]; then TWHY="lane line changed since trust"
  elif [ "$n" != "${HN[$1]}" ]; then TWHY="canary changed since trust (a repo file it names)"
  elif [ "$HD" != "$DIR_SHA" ]; then TWHY="@ directives or scan rules changed since trust"
  else TWHY=""
  fi
}
retrust_hint() { # $1 = lane, $2 = why it is untrusted -> "if S<n> changed …; otherwise " when run may re-trust it (a hint, never dies)
  local s
  case "$2" in command*|canary*) [ -f "${CARD:-}" ] || return 0 ;; *) return 0 ;; esac   # an active task's card only
  s="$(card_current_slice "$CARD")"
  case " $(slice_lanes "$(slice_line "$s")") " in
    *" $1 "*) printf 'if %s changed a file only its cmd names, bash scripts/evidence.sh run %s re-trusts it while the canary still fails; otherwise ' "$s" "$1" ;;
  esac
}

lane_state() { # $1 = lane -> LS fresh|stale|fail|missing|untrusted|undeclared, LID, LSD, LSW (words for gaps, footers)
  # A declared lane's answer is kept for the rest of the call (H2), like its trees: no command here writes a lane record
  # between two asks (status asks twice, done and close ask again in their footer).
  local r
  if lane_ix "$1" && [ -n "${LSK[IX]:-}" ]; then
    LS="${LSK[IX]}" LID="${LSI[IX]}" LSD="${LSE[IX]}" LSW="${LSV[IX]}"
    return 0
  fi
  r="$(lastrec "$1.jsonl")"
  jv "$r" id
  LID="$JV" LS=fresh LSD=fresh LSW=""
  if ! lane_ix "$1"; then
    LS=undeclared LSD="not declared in .claude/done-lanes — declare it (the human trusts it) or fix the card"
    return 0
  elif lane_defs "$IX" && { [ -n "${TW[IX]+x}" ] || { trust_note "$IX"; TW[IX]="$TWHY"; }; } && [ -n "${TW[IX]}" ]; then
    LS=untrusted LSD="not trusted: ${TW[IX]} — $(retrust_hint "$1" "${TW[IX]}")the human runs: bash scripts/evidence.sh trust $1"
  elif [ -z "$r" ]; then
    LS=missing LSD=missing
  elif jv "$r" verdict; [ "$JV" != pass ]; then
    jv "$r" why
    LS=fail LSD="failed ($JV)"
  elif jvs "$r" cmd_sha lane_sha; [ "$JV" != "${HC[IX]} ${HL[IX]}" ]; then
    LS=stale LSD="stale (record $LID ran under another lane definition)" LSW="pass $LID ran under another definition of the lane"
  else   # review #9 above: a record counts only under the definition trusted now; H2 here: one hash per lane and call
    lane_memo "$IX"
    jv "$r" tree
    [ "$JV" = "${MEMO[IX]}" ] || LS=stale LSD="stale (record $LID was for other content)" LSW="content changed since pass $LID"
  fi
  LSK[IX]="$LS" LSI[IX]="$LID" LSE[IX]="$LSD" LSV[IX]="$LSW"
}

rev_tail() { # $1 type, $2 unit, $3 lane, $4 tree, $5 result -> the donelog row of review record RID
  local t="${4#card:}"
  donelog_row "$DLOG" "$1" "$2" "$3" "${t:0:12}" "$RID" "$5"
}

DROW=""
defect() { # a row harness-report.sh --defect refused is never silent: the check/codex output line says defect-row:failed
  bash scripts/harness-report.sh --defect "$SLUG" "$1" "$2" "$3" "$4" "$5" --n "$6" >/dev/null 2>&1 && return 0
  DROW=" defect-row:failed"
  echo "evidence: warning: defect not recorded (harness-report.sh --defect failed): $4" >&2
}

# --- judging a lane or canary log ------------------------------------------------

clock_ms() { # -> CLK: epoch ms from EPOCHREALTIME (bash 5; . or , by locale), date +%s%3N (GNU: 13 digits; uutils ignores
  # the 3: 19, ns), perl Time::HiRes (macOS: bash 3.2, BSD date), else SECONDS x 1000 (whole seconds, as before)
  local t="${EPOCHREALTIME:-}"
  if [[ "$t" =~ ^([0-9]+)[.,]([0-9]{3}) ]]; then CLK="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
  elif t="$(date +%s%3N 2>/dev/null)" && [[ "$t" =~ ^([0-9]{13})([0-9]{6})?$ ]]; then CLK="${BASH_REMATCH[1]}"
  elif t="$(perl -MTime::HiRes=time -e 'printf "%d", time * 1000' 2>/dev/null)" && [[ "$t" =~ ^[0-9]{13}$ ]]; then CLK="$t"
  else CLK=$((SECONDS * 1000))
  fi
}
ms_of() { # $1 = a min_secs as load_lanes accepts it (^[0-9]+(\.[0-9]{1,3})?$) -> MS: its int part x 1000 + the fraction padded to 3
  local fr="${1#*.}000"
  [ "${1#*.}" != "$1" ] || fr=000
  MS=$((10#${1%%.*} * 1000 + 10#${fr:0:3}))
}

judge() { # $1 log, $2 expect, $3 exit, $4 elapsed ms, $5 min_secs (0 = canary) -> J_WHY J_EXEC J_SKIP J_MK J_MKS J_SCAN J_EL
  local i=0 k=0 re ln o e="$4"
  [ "$e" -ge 0 ] || e=0   # clock reads that disagree count as no time: never a pass, and (min 0) never a red canary
  printf -v J_EL '%d.%03d' $((e / 1000)) $((e % 1000))   # the elapsed seconds, to the ms
  J_WHY=- J_EXEC="" J_MKS=""
  [ "$3" != 0 ] && J_WHY="exit=$3"
  split ' ; ' "$2"
  for re in "${S[@]}"; do
    i=$((i + 1))
    if ln="$(grep -E -m 1 -- "$re" "$1" 2>/dev/null)"; then
      k=$((k + 1))
      # review #21: a JSON integer (no leading zeros, at most 18 digits); a cut that splits a UTF-8 character drops it
      [ $i = 1 ] && J_EXEC="$(printf '%s' "$ln" | grep -Eo '[0-9]+' | head -n 1 | sed -E 's/^0+([0-9])/\1/' | cut -c1-18)"
      o="${ln:0:200}"
      [ ${#ln} -le 200 ] || o="$(printf '%s' "$o" | sed -E $'s/[\xc0-\xff][\x80-\xbf]*$//')"
      J_MKS="$J_MKS,\"$(printf '%s' "$o" | tr -d '\000-\037"\\')\""
    elif [ "$J_WHY" = - ]; then
      J_WHY="expect=$i"
    fi
  done
  J_EXEC="${J_EXEC:-0}"
  J_MK="$k/$i"
  J_MKS="[${J_MKS#,}]"
  [ "$J_WHY" = - ] && [ "$J_EXEC" -le 0 ] && J_WHY=executed=0
  ms_of "$5"
  [ "$J_WHY" = - ] && [ "$e" -lt "$MS" ] && J_WHY="too-fast:$J_EL<$5"   # in whole ms: 0.412 < 1
  J_SKIP="$(grep -Eo '[0-9]{1,9} (skipped|xfailed|deselected)' "$1" | awk '{s += $1} END {print s + 0}')"
  o="$(bash scripts/precommit-gitleaks.sh --scan-file "$1" 2>/dev/null)"
  case "$?:$o" in
    0:*) J_SCAN=clean ;;
    3:*) J_SCAN=clean-ip-only ;;
    *:|*:scan-error) J_SCAN=scan-error ;;
    *) J_SCAN="hit:$(printf '%s' "$o" | tr '\n' '+')" ;;
  esac
}

canary_red() { # $1 = lane index, $2 = refusal prefix, $3 = its tail -> CRES red:<why>; else dies "$2: <why>$3" (trust, run's auto
  # re-trust): a non-trivial canary that leaves the lane's content as it found it, logs nothing the scan flags, and fails
  local i="$1" c="${L_CAN[$1]}" first t0 log rc s0
  first="$(trivial "$c")"   # review #20: spacing, parentheses and a path do not hide a trivial canary
  { [ "$first" = "$(trivial "${L_CMD[i]}")" ] || static_only "$c" || [[ "$first" =~ ^(false|true|:|exit( [0-9]+)?|return( [0-9]+)?|!( .*)?)$ ]]; } &&
    die 3 "$2: canary is trivial ('$c'): it must run the same check against a known-broken state$3"
  t0="$(TREE_DUMP="$TDUMP" lane_tree "$i")"
  case "$t0" in error:*) die 6 "$2: git could not hash the lane's paths (an unmerged index or an unreadable file?)$3" ;; esac
  log="$EV/logs/${L_NAME[i]}-canary-$(date -u +%Y%m%dT%H%M%SZ).log"
  clock_ms; s0=$CLK
  ( umask 077; exec bash -c "$c" </dev/null >"$log" 2>&1 )
  rc=$?
  clock_ms
  chmod 600 "$log"
  judge "$log" "${L_EXP[i]}" "$rc" $((CLK - s0)) 0
  [ "${J_SCAN#clean}" != "$J_SCAN" ] ||
    die 3 "$2: the canary log hit a secret or internal-IP rule (${J_SCAN#hit:}): mask the output before trusting (log kept at $log, mode 600)$3"
  [ "$t0" = "$(TREE_DUMP="${TDUMP:+$TDUMP.after}" lane_tree "$i")" ] ||
    die 3 "$2: the canary left the lane's content changed$(changed_paths "$TDUMP" "$TDUMP.after"): a canary must restore whatever it breaks, and a cache it writes must be gitignored$3"
  [ "$J_WHY" = - ] &&
    die 3 "$2: the canary passed (exit 0, every marker, executed=$J_EXEC): this lane cannot tell broken from working; fix the canary or tighten expect$3"
  CRES="red:$J_WHY"
}

trust_row() { # $1 = lane index, $2 = canary result [, $3 = auto:<slug>:<S>, the 8th field only run's auto re-trust writes]
  [ -f "$TR" ] ||
    printf "# ts\tlane\tcmd_sha\tlane_sha\tdir_sha\tcanary_sha\tcanary_result — written only by scripts/evidence.sh (trust; run's auto re-trust adds an 8th field); append-only\n" > "$TR"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s%s\n' "$(now)" "${L_NAME[$1]}" "$(def_sha "${L_CMD[$1]}")" "$(h12 "${L_LINE[$1]}")" "$DIR_SHA" \
    "$(def_sha "${L_CAN[$1]}")" "$2" "${3:+$TAB$3}" >> "$TR"
}

cmd_trust() { # trust <lane> [--skip-canary]: the human approves one lane definition (02 §0.2)
  local l="${1:-}" c cmd res
  load_lanes
  lane_ix "$l" || die 2 "no lane '$l' in .claude/done-lanes"
  c="${L_CAN[IX]}"
  cmd="${L_CMD[IX]}"
  static_only "$cmd" &&
    die 3 "TRUST REFUSED — $l: static-only command ('$(printf '%s' "$cmd" | sed -E 's/[[:space:]]*(&&|;|\|).*//')'): a lane must run the product, not lint, parse or list it"
  [ "${2:-}" = --skip-canary ] && [ "${c#skip:}" = "$c" ] && die 2 "--skip-canary needs canary = skip:<reason> in .claude/done-lanes"
  [ -z "$c" ] && die 3 "TRUST REFUSED — $l: canary is empty"
  [ -n "$(git ls-files -co --exclude-standard -- ${L_PATHS[IX]} 2>/dev/null | head -n 1)" ] ||   # review #3
    die 3 "TRUST REFUSED — $l: no tracked or unignored file under its paths (${L_PATHS[IX]}): its content could never change, so its records would prove nothing"
  if [ "${c#skip:}" != "$c" ]; then
    res="skip:$(printf '%s' "${c#skip:}" | tr '\t,' '  ' | cut -c1-120)"
    [ "${2:-}" = --skip-canary ] ||
      die 3 "TRUST REFUSED — $l: canary is $c; nothing would show this lane can fail. If the human accepts that: bash scripts/evidence.sh trust $l --skip-canary"
  else
    dump_init; trap 'rm -f ${TDUMP:+"$TDUMP" "$TDUMP.after"}' EXIT
    canary_red "$IX" "TRUST REFUSED — $l" ""
    res="$CRES"
  fi
  trust_row "$IX" "$res"
  task_ctx soft && donelog_row "$DLOG" TRUST - "$l" - - "canary $res cmd $(def_sha "$cmd")"
  echo "evidence: trusted lane $l — canary $res · cmd $(def_sha "$cmd") · lane $(h12 "${L_LINE[IX]}") · directives $DIR_SHA"
  echo "evidence: re-trust whenever this lane's line, a repo file its cmd or canary names, or any @ directive changes; run refuses an untrusted definition (a slice's own edit of a file only its cmd names: run re-trusts it while the canary still fails)"
}

trivial() { # $1 = a command -> it with ( ) { } ; dropped, spaces squeezed, the first word's directory stripped
  printf '%s' "$1" | tr -d '(){};' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//; s#^[^ ]*/##'
}

# Auto re-trust (user ruling): a slice may change a file its lane's cmd names (the verify script). run re-trusts the lane
# itself, under its lock, only when the canary still fails; the checker reviews that diff and close lists it for the human.
AS="" AF=""
retrust_ok() { # $1 = lane index -> rc 0 when run may re-trust it: AS the [~] slice, AF the files changed since its START head
  # (a) only named-file content moved since trust: line, @ lines and scan rules as trusted; never a skip: canary (g)
  # (b) an approved card, AS started at a commit h; (c) AS cites the lane; (d) every file either field names that differs
  # from h is named by the cmd, else a canary-only file dies; (e) the trust row is h's definition, or AS's own auto row
  local i="$1" c l n a8 h c1 n1 c0 n0 f
  IFS=$'\t' read -r _ _ c l _ n _ a8 <<<"${TROW[i]:-}"
  [ -n "${TROW[i]:-}" ] && [ "$l $HD" = "${HL[i]} $DIR_SHA" ] && [ "$c $n" != "${HC[i]} ${HN[i]}" ] &&
    [ "${L_CAN[i]#skip:}" = "${L_CAN[i]}" ] && task_ctx soft && [ "$A12" = "$D12" ] || return 1
  AS="$(card_current_slice "$CARD")"
  h="$(started_row "$AS" | cut -f5)"
  [ "$AS" != - ] && [[ "$h" =~ ^[0-9a-f]{7,40}$ ]] && h="$(git rev-parse -q --verify "$h^{commit}")" || return 1
  case " $(slice_lanes "$(slice_line "$AS")") " in *" ${L_NAME[i]} "*) ;; *) return 1 ;; esac
  def_texts "${L_CMD[i]}" "${L_CAN[i]}"
  c1="$(sed 1d <<<"${DT[0]}")" n1="$(sed 1d <<<"${DT[1]}")"   # "<path> <sha256>" per file each field names, now and at h
  head_texts "$h" "${L_CMD[i]}" "${L_CAN[i]}"
  c0="$(sed 1d <<<"${DT[0]}")" n0="$(sed 1d <<<"${DT[1]}")"
  AF="$( { printf '%s\n' "$c1" "$n1" | sort -u; printf '%s\n' "$c0" "$n0" | sort -u; } | grep . | sort | uniq -u | sed 's/ [^ ]*$//' | sort -u)"
  [ -n "$AF" ] || return 1
  c1=$'\n'"$(printf '%s\n' "$c1" "$c0" | sed 's/ [^ ]*$//')"$'\n'   # the files the cmd names, now or at h
  while IFS= read -r f; do
    case "$c1" in *$'\n'"$f"$'\n'*) ;; *) die 3 "RUN REFUSED — lane ${L_NAME[i]}: the canary's own file $f changed — only the human re-trusts a changed canary — the human runs: bash scripts/evidence.sh trust ${L_NAME[i]}" ;; esac
  done <<<"$AF"
  [ "$c $n" = "$(h12 "${DT[0]}") $(h12 "${DT[1]}")" ] || [ "$a8" = "auto:$SLUG:$AS" ]
}
auto_retrust() { # $1 = lane index, under its run lock (f): canary_red as trust runs it (g), then the trust and donelog rows (h)
  local i="$1" l="${L_NAME[$1]}" f="${AF//$'\n'/, }" p
  p="RUN REFUSED — lane $l: auto re-trust after $AS changed $f failed"
  canary_red "$i" "$p" " — the human runs: bash scripts/evidence.sh trust $l"
  def_texts "${L_CMD[i]}" "${L_CAN[i]}"   # the definition (a)-(e) checked, not one an edit during the canary made
  [ "$(h12 "${DT[0]}") $(h12 "${DT[1]}")" = "${HC[i]} ${HN[i]}" ] ||
    die 3 "$p: the lane's files changed while its canary ran — the human runs: bash scripts/evidence.sh trust $l"
  trust_row "$i" "$CRES" "auto:$SLUG:$AS"
  donelog_row "$DLOG" TRUST "$AS" "$l" - - "auto canary $CRES cmd ${HC[i]} files ${AF//$'\n'/,}"
  echo "evidence: auto re-trusted lane $l for $AS — $f changed in this slice and the canary still fails ($CRES). The checker reviews that diff; close lists it for the human."
}

cmd_run() { # run <lane> [--escalated]: the only way a lane result enters the ledger
  local l="${1:-}" esc=0 slice=- n p t0 head ext=- ts log rc s0 secs v why="" w auto=""
  [ "${2:-}" = --escalated ] && esc=1
  load_lanes
  lane_ix "$l" || die 2 "no lane '$l' in .claude/done-lanes"
  trust_note "$IX"
  [ -z "$TWHY" ] || { retrust_ok "$IX" && auto=1; } ||
    die 3 "RUN REFUSED — lane $l: $TWHY — the human runs: bash scripts/evidence.sh trust $l"
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
    # ESCALATE (D17): consecutive fails of this lane on this slice since its START in this task (review #16);
    # a pass resets, a human override counts as 1
    n="$(grep -F "\"slice\":\"$slice\"," "$EV/$l.jsonl" 2>/dev/null |
      sed -nE 's/.*"started":"([^"]*)".*"verdict":"([a-z]+)","why":"[^"]*","ack":([01]),"markers".*/\1 \2 \3/p' |
      awk -v s="$(started_row "$slice" | cut -f1)" '$1 < s {next} $2 == "pass" {n = 0} $2 == "fail" {n = ($3 == 1) ? 1 : n + 1} END {print n + 0}')"
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
  dump_init; trap 'rm -f "$LOCK" ${TDUMP:+"$TDUMP" "$TDUMP.after"}' EXIT
  trap 'exit 130' INT TERM HUP
  [ -z "$auto" ] || auto_retrust "$IX"
  t0="$(TREE_DUMP="$TDUMP" lane_tree "$IX")"
  case "$t0" in error:*) die 6 "RUN REFUSED — lane $l: git could not hash the lane's paths (${L_PATHS[IX]}): resolve the merge, make every file readable, then re-run" ;; esac
  head="$(git rev-parse -q --verify HEAD || echo -)"
  if [ -n "${EXT[IX]:-}" ]; then
    ext="$(bash -c "${EXT[IX]}" </dev/null 2>/dev/null | tr -d '[:space:]')"
    [[ "$ext" =~ ^[0-9a-f]{7,40}$ ]] || ext=invalid
  fi
  ts="$(now)"
  log="$EV/logs/$l-$(date -u +%Y%m%dT%H%M%SZ).log"
  clock_ms; s0=$CLK
  ( umask 077; exec bash -c "${L_CMD[IX]}" </dev/null >"$log" 2>&1 )   # review #22: the log is 600 from its first byte
  rc=$?
  clock_ms
  chmod 600 "$log"
  judge "$log" "${L_EXP[IX]}" "$rc" $((CLK - s0)) "${L_MIN[IX]}"
  secs="${J_EL%.*}"   # the record keeps whole seconds (its readers want an integer); why and the messages carry the ms
  why="$J_WHY"
  [ "$why" = - ] && [ "$ext" = invalid ] && why=ext
  case "$J_SCAN" in
    clean*) ;;
    scan-error) J_MKS='["withheld: scan hit"]' why=scan-error ;;
    *) J_MKS='["withheld: scan hit"]' why="leak:${J_SCAN#hit:}" ;;
  esac
  [ "$t0" = "$(TREE_DUMP="${TDUMP:+$TDUMP.after}" lane_tree "$IX")" ] || why=changed-during-run
  v=pass
  [ "$why" = - ] || v=fail
  [ "$why" = changed-during-run ] && v=void
  record "$l.jsonl" lane="$l" slice="$slice" tree="$t0" head="$head" ext="$ext" \
    cmd_sha="$(def_sha "${L_CMD[IX]}")" lane_sha="$(h12 "${L_LINE[IX]}")" exit:$rc started="$ts" secs:$secs \
    executed:$J_EXEC skipped:$J_SKIP scan="$J_SCAN" log="$log" log_sha="$(sha < "$log")" \
    verdict=$v why="$why" ack:$esc markers@"$J_MKS"
  [ -n "$DLOG" ] && donelog_row "$DLOG" RUN "$slice" "$l" "${t0:0:12}" "$RID" "$v"
  echo "evidence: $l $(printf '%s' "$v" | tr a-z A-Z) id=$RID exit=$rc secs=$J_EL executed=$J_EXEC markers=$J_MK scan=$J_SCAN"
  [ $v = pass ] && exit 0
  case "$why" in
    changed-during-run) w="lane files changed during the run$(changed_paths "$TDUMP" "$TDUMP.after") — record voided. A file the run writes itself (a cache, build output) must be gitignored; otherwise re-run once edits stop" ;;
    exit=*) w="exit ${why#exit=}" ;;
    leak:*|scan-error) w="the log hit a secret or internal-IP rule (${why#leak:}) — the run failed; never paste this log" ;;
    expect=*) split ' ; ' "${L_EXP[IX]}"; w="expect not matched — pattern ${why#expect=} ('${S[${why#expect=} - 1]}') found no line" ;;
    executed=0) w="executed=0 — nothing ran (zero tests, rows or requests): unproven, not passed" ;;
    too-fast:*) w="too fast — ${J_EL}s is under min_secs ${L_MIN[IX]}; the work was skipped" ;;
    *) w="@ext printed no commit id" ;;
  esac
  printf 'evidence: why: %s\nevidence: log: %s\n' "$w" "$log"
  case "$J_SCAN" in   # review #24: clean-ip-only means no secret rule ran, so no tail is printed
    clean) tail -n 20 "$log" | sed 's/^/    /' ;;
    clean-ip-only) echo "evidence: log tail not printed: gitleaks is not installed, so only the internal-IP rule ran" ;;
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
  # review #13/#14: raw names (-z), a rename is a deletion plus an addition; a failed diff is reported, not silent
  { git diff --name-only --no-renames -z "$b" -- 2>/dev/null || printf '(git diff against %s failed)\0' "$b"
    git ls-files -z --others --exclude-standard; } | tr '\0' '\n' | sort -u |
    grep -Ev '^(\.ai_context/|\.claude/done-lanes$|\.claude/done-lanes\.trust$)' |
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

slice_gaps() { # $1 = S<n>, $2 = its card line -> GAPS, EVTOK (the ✓ tokens)
  local s="$1" ln="$2" st sts sh l r f p="" stree
  GAPS=""
  EVTOK=""
  f="$(lint_card | grep -m 1 '^CARD LINT')"
  [ -z "$f" ] || gap "$f (run: bash scripts/evidence.sh lint)"
  approval_gap
  st="$(started_row "$s")"
  sts="$(cut -f1 <<<"$st")"
  sh="$(cut -f5 <<<"$st")"
  [ -n "$st" ] || gap "no START for $s — run: bash scripts/evidence.sh start $s before working on it"
  for l in $(slice_lanes "$ln"); do
    lane_state "$l"   # declared, trusted, run under the current definition (review #2/#9)
    r="$(lastrec "$l.jsonl")"
    f=""
    case "$LS" in
      undeclared|untrusted) gap "lane $l: $LSD"; continue ;;
      missing) f="never run" ;;
      *)
        if [[ "$(jget "$r" started)" < "$sts" ]]; then f="no run since $s started"
        elif [ "$LS" = fail ]; then f="latest run $LID FAILED ($(jget "$r" why))"
        elif [ "$LS" = stale ]; then f="$LSW"
        else EVTOK="$EVTOK $l@$LID"
        fi
        ;;
    esac
    p="$p ${L_PATHS[IX]}"
    [ -z "$f" ] || gap "lane $l: $f — re-run: bash scripts/evidence.sh run $l"
  done
  stree="$(slice_tree "$s")"
  r="$(lastrec checker.jsonl "\"unit\":\"$s\",\"tree\":\"$stree\",\"task\":\"$SLUG\",")"   # review #4: this task's only
  if [ -z "$r" ]; then gap "no checker record for $s at its current content — spawn the checker for $s"
  elif [ "$(jget "$r" verdict)" = void ]; then gap "checker $(jget "$r" id) for $s is void: $s's content changed while it was being checked — re-check"
  elif [ "$(jget "$r" verdict)" != pass ]; then
    gap "checker $(jget "$r" id) for $s: $(jget "$r" verdict) ($(jget "$r" not_verified) NOT VERIFIED) — fix, then re-check"
  else EVTOK="$EVTOK check@$(jget "$r" id)"
  fi
  if codex_yes "$ln"; then
    r="$(lastrec codex.jsonl "\"lane\":\"codex-slice\",\"unit\":\"$s\",\"tree\":\"$stree\",\"task\":\"$SLUG\",")"
    if [ -n "$r" ] && approving "$r"; then EVTOK="$EVTOK codex@$(jget "$r" id)"
    elif waived "$s" >/dev/null; then EVTOK="$EVTOK codex@waived"
    else gap "no approving codex-slice review of $s at its current content — run: bash scripts/task-pair.sh check slice $s --since ${sh:-<start head>}"
    fi
  fi
  if [ -n "$sh" ] && f="$(outside "$sh" $p | flist)" && [ -n "$f" ]; then
    gap "$s changed files outside its lanes' paths ($(echo $p)): $f — declare a lane that covers them (needs trust) or move the change to its own slice"
  fi
  EVTOK="${EVTOK# }"
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
    [ "$3" = 1 ] && [ -n "$x" ] && [ "$x" != - ] && echo "  - $l ran against external commit $x; the external repo's current head is not compared here"
  done
  if [ -n "$DLOG" ]; then
    b="$(card_base)"
    x="${L_PATHS[*]:-}"
    x="$(outside "${b:-HEAD}" $x | flist)"
    [ -z "$x" ] || echo "  - changed since base ${b:0:7} outside every lane's paths: $x"
    for u in $2; do
      r="$(lastrec checker.jsonl "\"unit\":\"$u\"," "\"task\":\"$SLUG\",")"
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
  sed -E "/^- \[[ ~o]\] $s /{s/^- \[[ ~o]\]/- [x]/;s/ ✓ .*\$//;s/\$/ ✓ $EVTOK/;}" "$CARD" > "$CARD.tmp" && mv "$CARD.tmp" "$CARD"
  donelog_row "$DLOG" DONE "$s" - "$(slice_tree "$s" | cut -c1-12)" "$(tr ' ' , <<<"$EVTOK")" ok
  echo "evidence: $s ✓ $EVTOK"
  not_proven "$(slice_lanes "$ln")" "$s" 1
}

row_in() { # $1 TYPE, $2 slice|-, $3 tree12|'' (any), $4 tokens a,b; $5 = donelog (- = stdin) -> rc 0 when it holds that row
  awk -F'\t' -v t="$1" -v s="$2" -v w="$3" -v r="$4" '$2 == t && $3 == s && (w == "" || $5 == w) && $6 == r {f = 1} END {exit !f}' "$5" 2>/dev/null
}

sortu() { # $@ = words -> SU: them sorted and deduplicated, one per line (as printf '%s\n' $words | sort -u under LC_ALL=C)
  local w a=() i j t
  for w in "$@"; do
    for ((i = 0; i < ${#a[@]}; i++)); do [ "${a[i]}" = "$w" ] && continue 2; done
    a+=("$w")
  done
  for ((i = 1; i < ${#a[@]}; i++)); do   # insertion sort: a handful of lane names
    t="${a[i]}"
    for ((j = i - 1; j >= 0; j--)); do [[ "${a[j]}" > "$t" ]] || break; a[j + 1]="${a[j]}"; done
    a[j + 1]="$t"
  done
  SU=""
  for ((i = 0; i < ${#a[@]}; i++)); do SU="$SU${SU:+$'\n'}${a[i]}"; done
}

slice_rows() { # gate view (I-2, P-4): "S<n> TAB ok|foreign|noref|bad TAB detail" per [x] line (GUARD_SLICE_X, the gate's regex, M1)
  # $1 = a prefix for every row (status --porcelain: SLICE<TAB>). The cited records are read in one ledger pass (byids).
  local p="${1:-}" ln s t n r nf oth cited tk a ids=() L=()
  while IFS= read -r ln; do
    L+=("$ln")
    case "$ln" in *' ✓ '*) slice_ok "$ln" && for t in ${ln#* ✓ }; do ids+=("${t#*@}"); done ;; esac
  done < <(grep -E "$GUARD_SLICE_X" "$CARD")
  byids ${ids[@]+"${ids[@]}"}
  for ln in ${L[@]+"${L[@]}"}; do
    [[ "$ln" =~ ^-\ \[x\]\ (S[0-9]+) ]]   # sed -E 's/^- \[x\] (S[0-9]+).*/\1/'; GUARD_SLICE_X holds it
    s="${BASH_REMATCH[1]}"
    nf=""
    oth=""
    cited=""
    case "$ln" in
      *' ✓ '*) tk="${ln#* ✓ }" ;;
      *) printf '%s%s\tnoref\tno evidence reference\n' "$p" "$s"; continue ;;
    esac
    if ! slice_ok "$ln"; then   # review #1: the approved part parses, and after the first ' ✓ ' only tokens
      printf '%s%s\tbad\tthe line does not parse, or text after its first check mark is not only <name>@<8 hex> tokens\n' "$p" "$s"
      continue
    fi
    for t in $tk; do
      n="${t%%@*}"
      byid_of "${t#*@}"
      r="$JR"
      case "$n" in check|codex) ;; *) cited="$cited $n" ;; esac
      if [ "$t" = codex@waived ]; then
        waived "$s" >/dev/null || oth="$oth; codex@waived has no waiver at card:$D12"
      elif [ -z "$r" ]; then
        nf="$nf; $t not found"
      else
        case "$n" in   # review #4: a review record counts only for this task
          check)
            jvs "$r" lane unit task verdict
            [ "$JV" = "checker $s $SLUG pass" ] ||
              oth="$oth; $t is not a passing checker record of $s in this task"
            ;;
          codex)
            jvs "$r" lane unit task
            { [ "$JV" = "codex-slice $s $SLUG" ] && approving "$r"; } ||
              oth="$oth; $t is not an approving codex-slice review of $s in this task"
            ;;
          *)
            jvs "$r" lane verdict
            [ "$JV" = "$n pass" ] || oth="$oth; $t is not a passing $n record"
            ;;
        esac
      fi
    done
    slice_meta "$ln"
    a="${SM_LANES//,/ }"
    sortu $cited
    t="$SU"
    sortu $a
    [ "$t" = "$SU" ] ||
      oth="$oth; cites lanes ($(echo $cited)) but the slice declares ($a)"
    case " $tk" in *" codex@"*) ;; *) codex_yes "$ln" && oth="$oth; codex@ missing (codex: yes, pair on)" ;; esac
    t="${tk// /,}"
    row_in DONE "$s" '' "$t" "$DLOG" || oth="$oth; no DONE row with these ids"
    if [ -z "$nf$oth" ]; then
      printf '%s%s\tok\t%s\n' "$p" "$s" "$tk"
    elif [ -z "$oth" ] && git show "HEAD:$DLOG" 2>/dev/null | row_in DONE "$s" '' "$t" -; then   # H3b: committed rows only
      printf '%s%s\tforeign\t%s\n' "$p" "$s" "${nf#; }"
    else
      r="$nf${oth:-; the DONE row with these ids is not committed}"
      printf '%s%s\tbad\t%s\n' "$p" "$s" "$(printf '%s' "${r#; }" | tr -cd '\040-\176' | cut -c1-300)"
    fi
  done
}

final_ok() { # $1 = whole tree -> rc 0 when this task's final review holds there; FIN, FREC (its latest record), FTOK
  if pair_on; then
    FIN=codex-final
    FREC="$(lastrec codex.jsonl '"lane":"codex-final","unit":"final",' "\"task\":\"$SLUG\",")"
    if [ -n "$FREC" ] && approving "$FREC" && jv "$FREC" tree && [ "$JV" = "$1" ]; then
      FTOK="codex@$(jget "$FREC" id)"
    elif waived final >/dev/null; then
      FTOK=codex@waived
    else
      return 1
    fi
  else
    FIN=checker-final
    FREC="$(lastrec checker.jsonl '"lane":"checker","unit":"final",' "\"task\":\"$SLUG\",")"
    [ -n "$FREC" ] && jv "$FREC" verdict && [ "$JV" = pass ] && jv "$FREC" tree && [ "$JV" = "$1" ] && jv "$FREC" id &&
      FTOK="check@$JV"
  fi
}

closed_row() { # "none|ok|foreign|stale TAB detail" for the Closed: line (R11; review #2, #12, #26, H3b, H4)
  local l w c ct tk det="" hard=0
  grep -q '^Closed:' "$CARD" || { printf 'none\t-\n'; return; }
  c="$(tail -n 1 "$CARD")"
  [[ "$c" =~ $CLOSED_RE ]] || { printf 'stale\tthe Closed: line is not the last line in the form close writes\n'; return; }
  ct="${c#Closed: tree:}"
  ct="${ct%% *}"
  tk="${c#* ✓ }"
  tk="${tk% — *}"
  tk="${tk// /,}"
  w="${TREE:-$(tree_of .)}"
  ! grep -qE '^- \[[ ~o]\] S[0-9]+' "$CARD" || { det="$det; not every slice is [x]"; hard=1; }
  [ ${#L_NAME[@]} -gt 0 ] || { det="$det; .claude/done-lanes is missing or does not parse"; hard=1; }
  for l in $(card_lanes); do   # every cited lane: declared, trusted, fresh
    lane_state "$l"
    [ "$LS" = fresh ] && continue
    det="$det; $l: $LS"
    case "$LS" in
      undeclared|untrusted) hard=1 ;;
      fail) [ "$(jget "$(lastrec "$l.jsonl")" tree)" = "${MEMO[IX]:-$(lane_tree "$IX")}" ] && hard=1 ;;   # failed here
    esac
  done
  if ! final_ok "$w"; then
    det="$det; $FIN: $([ -n "$FREC" ] && echo stale || echo missing)"
    jv "$FREC" tree
    [ "$JV" = "$w" ] && hard=1   # the latest final review at this content does not approve
  fi
  [ "$ct" = "${w:0:12}" ] || { det="$det; tree: changed since close"; hard=1; }
  [ "$(awk -F'\t' '$2 == "CLOSE" {r = $5 " " $6} END {print r}' "$DLOG" 2>/dev/null)" = "$ct $tk" ] ||
    { det="$det; the last CLOSE row does not match the Closed: line"; hard=1; }
  if [ -z "$det" ]; then
    printf 'ok\t-\n'
  elif [ $hard = 0 ] && git show "HEAD:$DLOG" 2>/dev/null | row_in CLOSE - "$ct" "$tk" -; then
    printf 'foreign\t%s\n' "${det#; }"   # closed at this very content (a committed CLOSE row); only local records lag (#12)
  else
    printf 'stale\t%s\n' "${det#; }"
  fi
}

cmd_close() { # close: every slice [x], every cited lane declared, trusted and fresh, the final review here (R11)
  local l x r w b p="" tok=""
  task_ctx
  load_lanes
  GAPS=""
  x="$(lint_card | grep -m 1 '^CARD LINT')"   # review #2
  [ -z "$x" ] || gap "$x (run: bash scripts/evidence.sh lint)"
  x="$(sed -nE 's/^- (\[[ ~o]\]) (S[0-9]+) .*/\2 \1/p' "$CARD" | flist)"
  [ -z "$x" ] || gap "not done: $x"
  approval_gap
  while IFS=$'\t' read -r l x r; do
    case "$x" in
      ok|foreign) ;;
      noref) gap "$l is [x] without an evidence reference" ;;
      *) gap "$l cites evidence that does not hold: $r" ;;
    esac
  done < <(slice_rows)
  for l in $(card_lanes); do
    lane_state "$l"
    case "$LS" in
      fresh) tok="$tok $l@$LID" ;;
      undeclared|untrusted) gap "lane $l: $LSD"; continue ;;   # review #6: never run an untrusted @ext
      *) gap "lane $l: $LSD — re-run: bash scripts/evidence.sh run $l" ;;
    esac
    p="$p ${L_PATHS[IX]}"
    [ -n "${EXT[IX]:-}" ] || continue
    r="$(jget "$(lastrec "$l.jsonl")" ext)"
    x="$(bash -c "${EXT[IX]}" </dev/null 2>/dev/null | tr -d '[:space:]')"
    [ "$x" = "$r" ] || gap "lane $l: external repo moved ${r:--} -> ${x:--} since record ${LID:--} — re-run the lane"
  done
  b="$(card_base)"   # review #26: what a commit between slices or a stash kept out of every done
  if [ -n "$b" ] && x="$(outside "$b" $p | flist)" && [ -n "$x" ]; then
    gap "changed since base ${b:0:7} outside the cited lanes' paths: $x — no slice proved these; cover them with a lane (needs trust) or revert them"
  fi
  w="$(tree_of .)"
  if final_ok "$w"; then
    tok="$tok $FTOK"
  elif pair_on; then
    gap "no approving codex-final review of the current content (tree:${w:0:12}) — run: bash scripts/task-pair.sh check final --since ${b:0:7}"
  else
    gap "no passing checker final record at the current content (tree:${w:0:12}) — spawn the checker on \"Check final\""
  fi
  if [ -n "$GAPS" ]; then
    printf 'evidence: NOT CLOSED — %s gap(s):\n%s' "$(printf '%s' "$GAPS" | grep -c .)" "$GAPS"
    not_proven "$(card_lanes)" "final card" 0
    exit 1
  fi
  x="Closed: tree:${w:0:12} head:$(git rev-parse -q --verify HEAD | cut -c1-12) ✓ ${tok# } — $(now)"
  { sed '${/^Closed:/d;}' "$CARD"; echo "$x"; } > "$CARD.tmp" && mv "$CARD.tmp" "$CARD"
  donelog_row "$DLOG" CLOSE - - "${w:0:12}" "$(tr ' ' , <<<"${tok# }")" ok
  echo "evidence: $x"
  not_proven "$(card_lanes)" "final card" 0
  # (i) run's auto re-trusts in this task, by lane: "<lane> (<S>: <files its last auto row names>; …)"
  x="$(awk -F'\t' '$2 == "TRUST" && $7 ~ /^auto / {f = $7; sub(/.* files /, "", f); gsub(/,/, ", ", f)
      if (!($4 in s)) l[++n] = $4; if (!(($4, $3) in v)) s[$4] = s[$4] " " $3; v[$4, $3] = f}
    END {for (i = 1; i <= n; i++) {k = split(substr(s[l[i]], 2), a, " "); o = ""
      for (j = 1; j <= k; j++) o = o (j > 1 ? "; " : "") a[j] ": " v[l[i], a[j]]
      printf "%s%s (%s)", (i > 1 ? ", " : ""), l[i], o}}' "$DLOG")"
  [ -z "$x" ] || echo "evidence: lanes re-trusted automatically during this task — review before merging: $x"
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
  norm=$(($(card_norm "$CARD" | wc -c)))
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
  while IFS= read -r x; do   # review #1: lanes are read before the first ' ✓ '; only tokens may follow it
    s="${x#- \[?\] }"
    s="${s%% *}"
    if ! [[ "${x%% ✓ *}" =~ $SLICE_RE ]]; then
      pb "slice line does not parse: '${x:0:80}'"
    elif ! slice_ok "$x"; then
      x="${x#* ✓ }"
      pb "$s carries text after ' ✓ ' that is not evidence tokens ('${x:0:60}') — only done writes there"
    else
      for x in $(slice_lanes "$x"); do
        lane_ix "$x" || pb "$s names lane '$x' that .claude/done-lanes does not declare"
      done
    fi
  done < <(printf '%s\n' "$sl" | grep .)
  while IFS= read -r x; do
    pb "duplicate slice id $x"
  done < <(printf '%s\n' "$sl" | sed -nE 's/^- \[.\] (S[0-9]+) .*/\1/p' | awk 'c[$0]++ == 1')
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

cmd_status() { # status [--line|--porcelain|--tree <S<n>|final>] (02 §0.9): --porcelain always exits 0
  local m="${1:-}" k p x l s r line cr tl lok
  if [ "$m" = --tree ]; then   # spawn-log's SPAWN row (review #17): the tree a checker of this unit reads now
    task_ctx soft && lanes_soft || exit 1
    case "${2:-}" in S[0-9]*) slice_tree "$2" ;; final) tree_of . ;; *) die 2 "usage: evidence.sh status --tree <S<n>|final>" ;; esac
    exit 0
  fi
  for k in "$EV"/locks/*.lock; do
    [ -f "$k" ] && ! lock_alive "$(cut -f1 "$k")" && rm -f "$k"
  done
  share_index
  if [ "$m" != --line ]; then   # review H2: --line needs the whole tree only for a Closed: line (closed_row)
    TREE=-
    [ -n "$NOGIT" ] || TREE="$(tree_of .)"
  fi
  if ! task_ctx soft; then
    [ "$m" = --porcelain ] && printf 'TREE\t%s\nCLOSED\tnone\t-\nLINE\tno active task\n' "$TREE"
    [ -z "$m" ] && echo "evidence status — no active task"
    exit 0
  fi
  lanes_soft
  lok=$?
  cr=""
  if [ -n "$NOGIT$NOLEDGER" ]; then
    line="evidence[$SLUG]: ${NOGIT:-$NOLEDGER}"
  elif [ ! -f "$DL" ]; then
    line="evidence[$SLUG]: no .claude/done-lanes — declare lanes before any slice can be done"
  elif [ $lok != 0 ]; then
    line="evidence[$SLUG]: .claude/done-lanes does not parse — run: bash scripts/evidence.sh lint"
  else
    x=approved
    [ -n "$A12" ] || x=unapproved
    [ -z "$A12" ] || [ "$A12" = "$D12" ] || x=changed
    line="evidence[$SLUG]: slice $(card_current_slice "$CARD")"
    line="$line ($(grep -c '^- \[x\] S[0-9]' "$CARD")/$(grep -cE '^- \[[ ~ox]\] S[0-9]+ ' "$CARD") done) · card $x"
    lane_defs_all
    for ((k = 0; k < ${#L_NAME[@]}; k++)); do
      l="${L_NAME[k]}"
      lane_state "$l"
      [ -f "$EV/locks/run-$l.lock" ] && lock_alive "$(cut -f1 "$EV/locks/run-$l.lock" 2>/dev/null)" && LS=running
      line="$line · $l $LS"
    done
    cr=1
  fi
  x="$cr"
  cr="$(closed_row)"   # after the lane loop: its subshell reuses the lane trees memoized there
  case "$x:$cr" in
    1:none*|:*) ;;
    1:ok*|1:foreign*) line="$line · closed fresh" ;;
    *) line="$line · closed stale" ;;
  esac
  if [ "$m" = --porcelain ]; then
    printf 'TREE\t%s\n' "$TREE"
    slice_rows "SLICE$TAB"
    x="${line//[\"\\]/}"   # tr -d '"\\'
    printf 'CLOSED\t%s\nLINE\t%s\n' "$cr" "${x%"${x##*[!$'\n']}"}"
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
    elif [ "$LS" = untrusted ]; then   # what to do about it: lane_state's words, as done and close print them
      x="$LSD"
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
    r="$(slice_rows | awk -F'\t' -v s="$s" '$1 == s {print "refs " $2 ": " $3}')"
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
  local x="${1:-}" r f log o=1
  task_ctx soft
  lanes_soft
  case "$x" in   # review #10: known names only; a log is printed only from logs/, and only after a fresh scan
    @*) r="$(byid "${x#@}")" ;;
    checker) r="$(lastrec checker.jsonl)" ;;
    codex-card|codex-slice|codex-final) r="$(lastrec codex.jsonl "\"lane\":\"$x\",")" ;;
    *)
      lane_ix "$x" || die 2 "usage: evidence.sh show <lane|checker|codex-card|codex-slice|codex-final|@id> — '$x' is none of them"
      r="$(lastrec "$x.jsonl")"
      ;;
  esac
  [ -n "$r" ] || { echo "evidence: no record for $x" >&2; exit 1; }
  echo "record: $r"
  f="$(jget "$r" lane)"
  log="$(jget "$r" log)"
  [ "$f" != checker ] || { log="$EV/logs/checker-$(jget "$r" id).txt"; echo "report: $log"; }
  if [ -z "$log" ]; then
    :
  elif ! [[ "$log" =~ ^\.claude/evidence/logs/[A-Za-z0-9._-]+$ ]] || [ -L "$log" ]; then
    echo "log not shown: $log is not a file in .claude/evidence/logs/"
  elif [ ! -f "$log" ]; then
    echo "log missing (pruned, or recorded on another machine)"
  else
    [ "$f" = checker ] || echo "log: $log ($(($(wc -c < "$log"))) B, sha $(sha < "$log" | cut -c1-12))"
    case "$(jget "$r" scan)" in clean*|'') bash scripts/precommit-gitleaks.sh --scan-file "$log" >/dev/null 2>&1; o=$? ;; esac
    if [ $o = 0 ] && [ "$f" = checker ]; then
      cat "$log"
    elif [ $o = 0 ]; then
      echo "--- log tail (60 lines) ---"
      tail -n 60 "$log"
    elif [ $o = 3 ]; then
      echo "log withheld: gitleaks is not installed, so only the internal-IP rule ran — read $log yourself; never paste it"
    else
      echo "log withheld: a secret or internal-IP rule hit, or the scan failed (recorded scan: $(jget "$r" scan)) — never paste $log"
    fi
  fi
  not_proven "$([ "$f" = checker ] || [ -z "$log" ] || echo "$f")" "$(jget "$r" unit)" 1
}

# --- reviews: checker and Codex records -----------------------------------------------

cmd_check() { # check <S<n>|final|card|-> --agent <id|-> --source <src>: a checker report on stdin -> record (I-3)
  local u="${1:-}" ag="${3:-}" src="${5:-}" rep vi nv ni vl vu v tree sp why=-
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
  if [ -z "$rep" ]; then v=uncaptured
  elif [ -z "$vl" ]; then v=unparsed
  elif [ "$vu" != "$u" ]; then v=fail
  elif [ "$(cut -d' ' -f3 <<<"$vl" | tr -d '[:space:]')" = pass ] && [ "$nv" = 0 ] && [ "$vi" -ge 1 ]; then v=pass
  else v=fail
  fi
  # R10 (checker.md): a slice or the task passes only when its first claim was seen running (L4/L5); card mode needs no L4
  if [ $v = pass ] && [ "$u" != card ] &&
     ! grep -E -m 1 '^(- )?(VERIFIED|NOT VERIFIED|INCONCLUSIVE) \(L[1-5]\) ' <<<"$rep" | grep -qE '^(- )?VERIFIED \(L[45]\) '; then
    v=fail why="R10: the first claim must be VERIFIED at L4 or L5"
    echo "evidence: checker $u pass recorded as fail — $why" >&2
  fi
  case "$u" in
    S*) tree="$(slice_tree "$u")" ;;
    final) tree="$(tree_of .)" ;;
    card) tree="$DIG" ;;
    *) tree=- ;;
  esac
  # review #17: the unit's tree spawn-log recorded at SubagentStart (SPAWN row) must still hold, or the check is void
  sp="$(awk -F'\t' -v a="$ag" '$2 == "SPAWN" && $4 == "checker" && $6 == a {r = $3 " " $5} END {print r}' "$DLOG" 2>/dev/null)"
  [ "$ag" != - ] && [[ "$sp" =~ ^(S[0-9]+|-)\ ([0-9a-f]{12})$ ]] && [ "${BASH_REMATCH[2]}" != "${tree:0:12}" ] &&
    { [ "${BASH_REMATCH[1]}" = "$u" ] || [ "${BASH_REMATCH[1]} $u" = "- final" ]; } && v=void
  record checker.jsonl lane=checker unit="$u" tree="$tree" task="$SLUG" card="$D12" head="$(git rev-parse -q --verify HEAD || echo -)" \
    agent_id="$ag" source="$src" verified:$vi not_verified:$nv inconclusive:$ni verdict=$v reason="$why" \
    report_sha="$(printf '%s\n' "$rep" | sha)" ts="$(now)"
  (umask 077; printf '%s\n' "$rep" > "$EV/logs/checker-$RID.txt")
  rev_tail CHECK "$u" checker "$tree" "$v"
  if [ $v = fail ] && [ "$nv" -gt 0 ] && [ "$u" != card ]; then
    defect "$u" checker unrated "checker $u: $nv NOT VERIFIED claim(s)" "check@$RID" "$nv"
  fi
  echo "check $u $v $RID$DROW"
}

# Provenance (pair review C1, M6): a Codex result counts as the judge's only when this run's transcript
# (PAIR_ROLLOUT, read from PAIR_SINCE on) holds the judge's own apply_patch write of the result path
# (PAIR_RESULT_PATH, default the result) — an exec/apply_patch custom_tool_call patch "*** Add|Update File:
# <path>", or an item_completed FileChange keyed by it (Codex 0.165.0 writes both) — its turn then ended
# with task_complete, and the file now says what the judge wrote: each header key's last written value and
# every finding line. Prints "ok", or "unbound <why>" / "mismatch <why>".
codex_prov() { # $1 = result file to read
  [ -n "${PAIR_ROLLOUT:-}" ] && [ -f "$PAIR_ROLLOUT" ] || { echo "unbound no Codex transcript of this run was found"; return; }
  [ -n "${PAIR_SINCE:-}" ] || { echo "unbound no run start time (PAIR_SINCE) to read the transcript from"; return; }
  command -v python3 >/dev/null 2>&1 || { echo "unbound python3 is not installed, so the transcript cannot be read"; return; }
  python3 -I - "$PAIR_ROLLOUT" "$PAIR_SINCE" "$1" "${PAIR_RESULT_PATH:-$1}" "$PWD" "$(pwd -P)" 2>/dev/null <<'PY' || echo "unbound the transcript could not be read"
import json, re, sys
ro, since, res, rp, root, rootp = sys.argv[1:7]
def norm(p):
    p = p.strip()
    for r in (root, rootp):
        if p.startswith(r + '/'):
            p = p[len(r) + 1:]
            break
    while p.startswith('./'):
        p = p[2:]
    return p
want = norm(rp)
ESC = {'n': '\n', 'r': '\r', 't': '\t', 'b': '\b', 'f': '\f', 'v': '\v', '0': '\0'}
def js_patch(src):  # the patch string literal an exec call hands to tools.apply_patch
    b = src.find('*** Begin Patch')
    if b < 1 or src[b - 1] not in '"\'`':
        return src[b:] if b >= 0 else ''
    q, i, out = src[b - 1], b, []
    while i < len(src) and src[i] != q:
        c = src[i]
        if c == '\\' and i + 1 < len(src):
            n, i = src[i + 1], i + 2
            if n in ESC:
                out.append(ESC[n])
            elif n == 'x':
                out.append(chr(int(src[i:i + 2], 16))); i += 2
            elif n == 'u' and src[i:i + 1] == '{':
                j = src.index('}', i); out.append(chr(int(src[i + 1:j], 16))); i = j + 1
            elif n == 'u':
                out.append(chr(int(src[i:i + 4], 16))); i += 4
            elif n != '\n':
                out.append(n)
            continue
        out.append(c); i += 1
    return ''.join(out).encode('utf-16', 'surrogatepass').decode('utf-16')
def patch_writes(p):  # the lines a patch adds to the result path
    got, cur = [], None
    for ln in p.split('\n'):
        m = re.match(r'\*\*\* (Add|Update) File: (.*)$', ln)
        if m:
            cur = [norm(m.group(2)), []]; got.append(cur)
        elif ln.startswith('*** Move to: ') and cur:
            cur[0] = norm(ln[13:])
        elif ln.startswith('*** '):
            cur = None
        elif cur is not None and ln.startswith('+'):
            cur[1].append(ln[1:])
    return [w for path, w in got if path == want]
ev = []
for raw in open(ro, encoding='utf-8', errors='replace'):
    try:
        o = json.loads(raw)
    except ValueError:
        continue
    if not isinstance(o, dict) or not isinstance(o.get('timestamp'), str) or o['timestamp'] < since:
        continue
    pl = o.get('payload')
    t = pl.get('type') if isinstance(pl, dict) else None
    if t == 'custom_tool_call' and pl.get('name') in ('exec', 'apply_patch') and isinstance(pl.get('input'), str):
        try:
            ev += [('w', w) for w in patch_writes(pl['input'] if pl['name'] == 'apply_patch' else js_patch(pl['input']))]
        except (ValueError, IndexError):
            pass
    elif t == 'item_completed' and isinstance(pl.get('item'), dict) and pl['item'].get('type') == 'FileChange' \
            and pl['item'].get('status', 'completed') == 'completed' and isinstance(pl['item'].get('changes'), dict):
        for path, c in pl['item']['changes'].items():
            for k in ('add', 'update'):   # older Codex nests the change under its kind
                if isinstance(c, dict) and isinstance(c.get(k), dict):
                    c = c[k]
            if norm(path) != want or not isinstance(c, dict):
                continue
            if isinstance(c.get('content'), str):
                ev.append(('w', c['content'].split('\n')))
            elif isinstance(c.get('unified_diff'), str):
                ev.append(('w', [l[1:] for l in c['unified_diff'].split('\n') if l.startswith('+') and not l.startswith('+++')]))
    elif t in ('task_complete', 'turn_aborted'):
        ev.append((t, None))
ws = [[l.replace('\r', '') for l in w] for k, w in ev if k == 'w']
if not ws:
    print('unbound the transcript holds no apply_patch write of %s by the judge since the run began' % want); sys.exit()
last = max(i for i, e in enumerate(ev) if e[0] == 'w')
end = [k for k, w in ev[last + 1:] if k != 'w']
if not end or end[0] != 'task_complete':
    print('unbound the judge\'s turn did not end normally after it wrote the result (%s)' % (end[0] if end else 'no task_complete')); sys.exit()
try:
    disk = open(res, encoding='utf-8', errors='replace').read().replace('\r', '').split('\n')
except OSError:
    print('unbound the result file cannot be read'); sys.exit()
for line in disk[:6]:
    k, val = line.split(':', 1)[0] + ': ', None
    for w in ws:
        for l in w:
            if l.startswith(k):
                val = l
    if val != line:
        print('mismatch the result says "%s", the judge wrote "%s"' % (line, val)); sys.exit()
seen = set(l for w in ws for l in w)
for line in disk[6:]:
    if re.match(r'[0-9]+\. (blocker|major|minor) ', line) and line not in seen:
        print('mismatch the result holds a finding the judge never wrote: %s' % line[:80]); sys.exit()
print('ok')
PY
}

cmd_codex() { # codex <packet> <result> <state> <reason>: one settled Codex run -> record (task-pair.sh finish)
  # env from task-pair.sh: PAIR_MODEL, PAIR_ROLLOUT, PAIR_SINCE, PAIR_SECS, PAIR_RESULT_PATH (codex_prov)
  local pk="${1:-}" res="${2:-}" st="${3:-}" hd stage u base since p v=none b=0 ma=0 mi=0 tree ro prov pw prev x why=""
  [ $# = 4 ] && [[ "$st" =~ ^(completed|failed|blocked)$ ]] ||
    die 2 "usage: evidence.sh codex <packet> <result> <completed|failed|blocked> <reason>"
  hd="$(head -n 20 "$pk" 2>/dev/null)"
  stage="$(sed -n 's/^stage: *//p' <<<"$hd" | head -n 1)"
  u="$(sed -n 's/^unit: *//p' <<<"$hd" | head -n 1)"
  base="$(sed -n 's/^base: *//p' <<<"$hd" | head -n 1)"
  since="$(sed -n 's/^since: *//p' <<<"$hd" | head -n 1)"
  [[ "$stage" =~ ^(card|slice|final)$ ]] && [ -n "$u" ] && [ -n "$base" ] || die 2 "packet needs stage:, unit: and base: lines"
  task_ctx
  lanes_soft

  # the result counts only with all six header lines, each key once, and run:/base: matching this run (review #18)
  p="$(head -n 6 "$res" 2>/dev/null | tr -d '\r')"
  if [ "$(grep -cE '^(run: (completed|failed|blocked)|verdict: (pass|fail|inconclusive)|base: .+|(blocker|major|minor): [0-9]+)$' <<<"$p")" = 6 ] &&
     [ "$(cut -d: -f1 <<<"$p" | sort -u | grep -c .)" = 6 ]; then
    v="$(sed -n 's/^verdict: //p' <<<"$p")"
    b="$(sed -n 's/^blocker: //p' <<<"$p")"
    ma="$(sed -n 's/^major: //p' <<<"$p")"
    mi="$(sed -n 's/^minor: //p' <<<"$p")"
    [ "$(sed -n 's/^run: //p' <<<"$p")|$(sed -n 's/^base: //p' <<<"$p")" = "$st|$base" ] || why="the result's run:/base: lines disagree with the run"
  fi
  # review #5: a verdict binds only what Codex was shown — the packet's base/since must be the content recorded here
  x="$(git rev-parse -q --verify "${since:-none}^{commit}")"
  case "$stage" in
    card)
      tree="$DIG"
      [ "$base" = "$DIG" ] || why="packet base $base is not the current card digest"
      ;;
    slice)
      tree="$(slice_tree "$u")"
      [ -n "$x" ] && [ "${x:0:12}" = "$(started_row "$u" | cut -f5)" ] || why="since: ${since:--} is not the HEAD $u's START recorded"
      ;;
    *)
      tree="$(tree_of .)"
      [ -n "$x" ] && [ "$x" = "$(git rev-parse -q --verify "$(card_base)^{commit}")" ] || why="since: ${since:--} is not the card's base:"
      ;;
  esac
  if [ -z "$why" ] && [ "$stage" != card ]; then   # slice and final: Codex read since..base, so base is HEAD and nothing else moved
    if [ "$base" != "$(git rev-parse -q --verify HEAD)" ]; then why="base: $base is not HEAD"
    elif [ -n "$(git status --porcelain -- $([ "$stage" = slice ] && slice_paths "$u" || echo .) ':(exclude).ai_context' 2>&1)" ]; then
      why="uncommitted changes in the reviewed paths were not in the reviewed diff"
    fi
  fi
  if [ -n "$why" ]; then
    v=none b=0 ma=0 mi=0
    echo "evidence: codex result not bound to what was reviewed ($why) — recorded with verdict none" >&2
  fi
  ro="${PAIR_ROLLOUT:-?}"
  ro="${ro/#"$HOME"/\~}"
  [[ "${PAIR_SECS:-}" =~ ^[0-9]+$ ]] || PAIR_SECS=0
  x="$(codex_prov "$res")"
  prov="${x%% *}" pw="${x#* }"
  case "$prov" in ok) pw="" ;; mismatch) ;; *) prov=unbound ;; esac
  [ -z "$pw" ] || [ "$v" = none ] || echo "evidence: codex result provenance $prov ($pw) — recorded, but this record cannot approve" >&2
  prev="$(lastrec codex.jsonl "\"lane\":\"codex-$stage\",\"unit\":\"$u\"," "\"task\":\"$SLUG\",")"
  record codex.jsonl lane="codex-$stage" unit="$u" tree="$tree" task="$SLUG" card="$D12" head="$(git rev-parse -q --verify HEAD || echo -)" \
    base="$base" since="${since:--}" run_state="$st" reason="$4${why:+ / unbound: $why}" verdict="$v" critical:$b high:$ma minor:$mi \
    model="${PAIR_MODEL:-?}" rollout="$ro" prov=$prov \
    packet_sha="$(sha < "$pk")" result_sha="$( [ -f "$res" ] && sha < "$res" || echo -)" secs:$PAIR_SECS ts="$(now)"

  x=reject
  [ "$st $v $b $ma" = "completed pass 0 0" ] && x=approve
  [ $x = approve ] && [ "$prov" != ok ] && x=unbound
  [ "$v" = none ] && x=none
  rev_tail CODEX "$u" "codex-$stage" "$tree" "$x"
  if [ "$v" != none ] && [ "$stage" != card ]; then
    [ "$b" -gt 0 ] && defect "$u" codex blocker "codex-$stage $u: $b blocker finding(s)" "codex@$RID" "$b"
    [ "$ma" -gt 0 ] && defect "$u" codex major "codex-$stage $u: $ma major finding(s)" "codex@$RID" "$ma"
  fi
  if [ "$v" = none ] && [ "$(jget "$prev" verdict)" = none ] && [ "$(jget "$prev" tree)" = "$tree" ]; then
    echo "evidence: codex no verdict twice — $u at this content; the human must look (tasks/$SLUG/pair/). done/close stay refused until an approving run or a waiver (approve --waive)" >&2
  fi
  echo "$RID$DROW"
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
