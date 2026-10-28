#!/usr/bin/env bash
#
# harness-report.sh — deterministic scoring over the harness's own usage
# data. Reads (each optional): .ai_context/scoreboard.csv (v3 rows, history),
# .ai_context/scoreboard-v4.csv, tasks/*/donelog, tasks/*/card.md,
# tasks/*/pair/runlog, .ai_context/defects.csv, .ai_context/friction.csv,
# git log (post-close fix commits).
#
# The scored object is the HARNESS VERSION (relative, version-over-version)
# — never the model, the project, or the human. Hard rules, on purpose:
#   - percentages print only where a cell has N >= 5 (below: counts only —
#     small N is noise, not signal);
#   - no composite score, ever (single numbers invite Goodhart);
#   - everything is computed from files, nothing from memory.
#
# Usage:
#   harness-report.sh [ROOT]                     human report
#   harness-report.sh --csv [ROOT]               v2 rows, one per harness version
#   harness-report.sh --row <slug> [--outcome success|failed|abandoned] [ROOT]
#                     one scoreboard-v4.csv row; prints the header first when that
#                     file is missing or empty — /wrap appends stdout verbatim
#   harness-report.sh --defect <slug|-> <S<n>|final|-> <finder> <severity> <summary> <ref|-> [--n N] [--fixed-in SHA]
#   harness-report.sh --defect-dismiss <sha>     a fix-commit candidate is not a defect
#   harness-report.sh --tripwire <slug> [ROOT]   one line for evidence.sh status
# --defect and --defect-dismiss write .ai_context/defects.csv under the
# current directory (the project root); ROOT defaults to it too.
# Exit: 0 ok (even "no data") · 1 usage/validation · 2 malformed or foreign header ·
#       3 --row/--tripwire cannot score this task (no card, outcome needed)
#
# Contracts: the --csv header (workshop fleet-report reads v2 by column name
# and tells v1 from v2 by the first column, project vs csv_version) and the
# `!! donelog STUCK rows:` line, which fleet-report parses too.

set -euo pipefail

SB_V4='date,slug,slices,blocks,stuck,codex_runs,interventions,duration_min,outcome,harness'
DF_HDR='date,slug,slice,finder,phase,severity,n,summary,fixed_in,ref'
CSV_V2='csv_version,project,harness,n_tasks,n_success,n_failed,n_abandoned,slices_sum,codex_runs_sum,interventions_sum,duration_med,block_rows,stuck_rows,escalate_rows,gate_error_rows,defects_pre_done,defects_post_done,defects_post_close,friction_total,friction_blockers'

die() { echo "harness-report: $2" >&2; exit "$1"; }
paths() { # $1 = project root
  ROOT="$1"; AI="$ROOT/.ai_context"; T="$AI/tasks"
  SB="$AI/scoreboard.csv"; SB4="$AI/scoreboard-v4.csv"; DF="$AI/defects.csv"; FR="$AI/friction.csv"
}
# The harness version every row is scored under: the ref after
# claude-starter@ on the last line of .claude/.starter-version.
stamp() {
  local s
  s="$(tail -n 1 "$ROOT/.claude/.starter-version" 2>/dev/null | sed -n 's/.*claude-starter@\([^ ]*\).*/\1/p')" || true
  echo "${s:-unknown}"
}
# UTC YYYY-MM-DDTHH:MM:SSZ (donelog, R1) -> epoch seconds, in shell
# arithmetic: GNU and BSD date(1) parse dates differently.
epoch() {
  [[ "${1:-}" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})Z$ ]] || return 1
  local y=$((10#${BASH_REMATCH[1]})) m=$((10#${BASH_REMATCH[2]})) d=$((10#${BASH_REMATCH[3]})) era yoe doy
  [ "$m" -le 2 ] && y=$((y - 1))
  era=$((y / 400)) yoe=$((y % 400)) doy=$(( (153 * ((m + 9) % 12) + 2) / 5 + d - 1 ))
  echo $(( (era * 146097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719468) * 86400 \
           + 10#${BASH_REMATCH[4]} * 3600 + 10#${BASH_REMATCH[5]} * 60 + 10#${BASH_REMATCH[6]} ))
}
slug_ok() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] && case "$1" in *..*) false ;; esac; }

# Both scoreboards are validated before any output. An empty file counts as
# absent (a failed `--row … >>` can leave one behind).
check_sb() {
  local h need
  if [ -s "$SB" ]; then
    h="$(head -n 1 "$SB" | tr -d '\r')"
    case "$h" in date,*) ;; *) die 2 "malformed scoreboard header in $SB" ;; esac
    for need in slug outcome; do
      case ",$h," in *",$need,"*) ;; *) die 2 "scoreboard header lacks the $need column ($SB)" ;; esac
    done
  fi
  check_sb4
}
check_sb4() {
  [ ! -s "$SB4" ] || [ "$(head -n 1 "$SB4" | tr -d '\r')" = "$SB_V4" ] ||
    die 2 "$SB4 does not start with the v4 header $SB_V4"
}

# --- defects.csv: /defect, /wrap's candidate lines, evidence.sh check/codex --------

df_open() { # before a write: missing or empty -> the header first; a foreign header -> exit 2
  [ -d "$AI" ] || die 1 "no .ai_context/ here — run --defect from the project root"
  if [ ! -s "$DF" ]; then printf '%s\n' "$DF_HDR" > "$DF"
  elif [ "$(head -n 1 "$DF" | tr -d '\r')" != "$DF_HDR" ]; then
    die 2 ".ai_context/defects.csv has a non-v4 header — migrate its rows before appending"
  fi
}
one_of() { # field value regex enum-text
  [[ "$2" =~ ^($3)$ ]] || die 1 "--defect $1='$2' is not one of $4"
}
clean_field() { printf '%s' "$1" | tr ',' ';' | tr -d '\t\r\n'; }

do_defect() {
  [ $# -ge 6 ] || die 1 "--defect needs <slug> <slice> <finder> <severity> <summary> <ref> [--n N] [--fixed-in SHA]"
  local slug="$1" sl="$2" fnd="$3" sev="$4" sum ref n=1 fx=- ph=- card id="" led="" row
  sum="$(clean_field "$5")"; ref="$(clean_field "$6")"
  shift 6
  while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || die 1 "--defect: $1 needs a value"
    case "$1" in
      --n) n="$2" ;;
      --fixed-in) fx="$2" ;;
      *) die 1 "--defect: unknown argument '$1'" ;;
    esac
    shift 2
  done
  one_of slug "$slug" '[a-z0-9._-]+|-' '[a-z0-9._-]+|-'
  case "$slug" in *..*) die 1 "--defect slug='$slug' is not one of [a-z0-9._-]+|-" ;; esac
  one_of slice "$sl" 'S[0-9]+|final|-' 'S<n>|final|-'
  one_of finder "$fnd" 'checker|codex|human|production|post-close-review|fix-commit' 'checker|codex|human|production|post-close-review|fix-commit'
  one_of severity "$sev" 'blocker|major|minor|unrated' 'blocker|major|minor|unrated'
  # R26: a checker report carries no severity; Codex minor findings are not recorded.
  [ "$fnd" != checker ] || one_of severity "$sev" unrated 'unrated (finder checker: a checker report has no severity)'
  [ "$sev" != unrated ] || one_of finder "$fnd" checker 'checker (severity unrated is for checker rows only)'
  [ "$fnd" != codex ] || one_of severity "$sev" 'blocker|major' 'blocker|major (finder codex: minor findings are not recorded)'
  one_of n "$n" '[1-9][0-9]*' 'an integer >= 1'
  [ "$fx" = - ] || one_of fixed-in "$fx" '[0-9a-f]{7,40}' 'a commit id (7-40 hex)'
  [ -n "$sum" ] || die 1 "--defect summary is empty"
  [ -n "$ref" ] || ref=-
  # Checker and Codex rows come only from evidence.sh, naming the record it wrote.
  case "$fnd:$ref" in
    checker:check@*) id="${ref#check@}" led="$ROOT/.claude/evidence/checker.jsonl" ;;
    codex:codex@*) id="${ref#codex@}" led="$ROOT/.claude/evidence/codex.jsonl" ;;
  esac
  case "$fnd" in checker|codex)
    [[ "$id" =~ ^[0-9a-f]{8}$ ]] && grep -q "^{\"id\":\"$id\"," "$led" 2>/dev/null ||
      die 1 "finder $fnd needs ref check@<id>|codex@<id> of an existing ledger record (written by evidence.sh)" ;;
  esac
  # The phase is derived, never typed: closed card -> post-close; a done
  # slice, or the final check -> post-done; otherwise pre-done.
  if [ "$slug" != - ]; then
    card="$T/$slug/card.md"
    if grep -q '^Closed:' "$card" 2>/dev/null; then ph=post-close
    elif [ "$sl" = final ] || grep -qE "^- \[x\] $sl([[:space:]]|\$)" "$card" 2>/dev/null; then ph=post-done
    else ph=pre-done
    fi
  fi
  row="$(date -u +%F),$slug,$sl,$fnd,$ph,$sev,$n,$sum,$fx,$ref"
  df_open
  printf '%s\n' "$row" >> "$DF"
  echo "defect recorded: $row"
}

do_dismiss() {
  [ $# = 1 ] || die 1 "--defect-dismiss needs <sha>"
  local full row
  full="$(git rev-parse -q --verify "$1^{commit}" 2>/dev/null)" || die 1 "--defect-dismiss: '$1' is not a commit in this repository"
  row="$(date -u +%F),-,-,fix-commit,-,none,0,dismissed: not a defect of the closed work,${full:0:7},-"
  df_open
  printf '%s\n' "$row" >> "$DF"
  echo "defect candidate ${full:0:7} dismissed"
}

# --- --row: one scoreboard-v4.csv row from the card and the donelog only ---------
# The evidence ledger is per machine (D10): scoring from it would make the
# row depend on where /wrap ran. interventions is counted from transcripts
# by the workshop's fleet-report, never here.
do_row() {
  local card="$T/$SLUG/card.md" dl="$T/$SLUG/donelog" closed=0 x b s c first last cr d end t0 t1 dur=- slices
  [ -f "$card" ] || die 3 "tasks/$SLUG/card.md not found — --row scores v4 tasks only"
  check_sb4
  grep -q '^Closed:' "$card" && closed=1
  [ -f "$dl" ] || dl=/dev/null
  x="$(awk -F'\t' 'NR == 1 {f = $1} {l = $1} $2 == "BLOCK" {b++} $2 == "STUCK" {s++} $2 == "CODEX" {c++} $2 == "CLOSE" {k = $1}
        END {printf "%d %d %d %s %s %s\n", b, s, c, (f == "" ? "-" : f), (l == "" ? "-" : l), (k == "" ? "-" : k)}' "$dl")"
  read -r b s c first last cr <<<"$x"
  if [ -z "$OUTCOME" ]; then
    if [ $closed = 1 ] && [ "$cr" != - ]; then OUTCOME=success
    elif [ $closed = 1 ]; then
      die 3 "tasks/$SLUG has a Closed: line but its donelog has no CLOSE row (written by hand?) — run bash scripts/evidence.sh close, or ask the human: failed or abandoned? then: --row $SLUG --outcome <failed|abandoned>"
    else
      die 3 "tasks/$SLUG has no Closed: line — ask the human: failed or abandoned? then: --row $SLUG --outcome <failed|abandoned>"
    fi
  elif [ "$OUTCOME" = success ] && { [ $closed = 0 ] || [ "$cr" = - ]; }; then
    die 3 "success needs a Closed: line (bash scripts/evidence.sh close)"
  fi
  slices="$(grep -cE '^- \[[ ~ox]\] S[0-9]+ ' "$card" || true)"
  d="${cr:0:10}"; [ "$cr" != - ] || d="$(date -u +%F)"
  end="$cr"; [ "$end" != - ] || end="$last"
  if t0="$(epoch "$first")" && t1="$(epoch "$end")"; then dur=$(( (t1 - t0 + 30) / 60 )); fi
  if [ ! -s "$SB4" ]; then
    echo "$SB_V4"
  elif awk -F, -v s="$SLUG" 'NR > 1 && $2 == s {f = 1} END {exit !f}' "$SB4"; then
    echo "harness-report: scoreboard-v4.csv already has a row for $SLUG — this one is appended after it (corrections are appended)" >&2
  fi
  echo "$d,$SLUG,$slices,$b,$s,$c,-,$dur,$OUTCOME,$(stamp)"
}

# --- --tripwire (D7): scope creep, reported by evidence.sh status, never a block --
# Lines added since the card's base (tracked diff + untracked files, outside
# .ai_context/ and .claude/), split by the done-lanes @verify-paths prefixes,
# and hours since the first APPROVE row, against the card's estimate.
do_tripwire() {
  local card="$T/$SLUG/card.md" hdr base h L vp p v el=- ap
  [ -f "$card" ] || die 3 "tasks/$SLUG/card.md not found — no tripwire"
  hdr="$(grep -m 1 '^<!-- card v4 ' "$card" || true)"
  [[ "$hdr" =~ base:\ ([0-9a-f]{7,40})\ .*estimate:\ ([0-9]+(\.[0-9]+)?)h\ ([0-9]+)L ]] ||
    die 3 "tasks/$SLUG/card.md has no base:/estimate: header — no tripwire"
  base="${BASH_REMATCH[1]}" h="${BASH_REMATCH[2]}" L="${BASH_REMATCH[4]}"
  git -C "$ROOT" rev-parse -q --verify "$base^{commit}" >/dev/null 2>&1 || die 3 "base $base is not a commit here — no tripwire"
  vp="$(sed -nE 's/^@verify-paths[[:space:]]+//p' "$ROOT/.claude/done-lanes" 2>/dev/null | sed -E 's/[[:space:]]+#.*$//' | tr '\n' ' ')" || true
  read -r p v < <({
    git -C "$ROOT" diff --numstat --no-renames "$base" -- . ':(exclude).ai_context' ':(exclude).claude' 2>/dev/null |
      awk -F'\t' '{print ($1 ~ /^[0-9]+$/ ? $1 : 0) "\t" $3}'
    git -C "$ROOT" ls-files -z --others --exclude-standard -- . ':(exclude).ai_context' ':(exclude).claude' 2>/dev/null |
      while IFS= read -r -d '' f; do printf '%s\t%s\n' "$(wc -l < "$ROOT/$f" 2>/dev/null | tr -d ' ')" "$f"; done
  } | awk -F'\t' -v vp="$vp" '
    BEGIN { n = split(vp, P, " "); for (i = 1; i <= n; i++) sub(/\/$/, "", P[i]) }
    { iv = 0; for (i = 1; i <= n; i++) if (P[i] == "." || $2 == P[i] || index($2, P[i] "/") == 1) iv = 1
      if (iv) v += $1; else p += $1 }
    END { print p + 0, v + 0 }')
  ap="$(awk -F'\t' '$2 == "APPROVE" {print $1; exit}' "$T/$SLUG/donelog" 2>/dev/null || true)"
  ap="$(epoch "$ap")" && el=$(( $(date -u +%s) - ap ))
  awk -v p="$p" -v v="$v" -v h="$h" -v L="$L" -v el="$el" -v b="${base:0:7}" 'BEGIN {
    r = ""; e = (el == "-" ? "-" : sprintf("%.1fh", el / 3600))
    if (el != "-" && h + 0 > 0 && el / 3600 > 2 * h) r = r ", " sprintf("time %.1fx", el / 3600 / h)
    if (L + 0 > 0 && p + v > 2 * L) r = r ", " sprintf("lines %.1fx", (p + v) / L)
    if (v > p && v >= 50) r = r ", verify>product"
    printf "tripwire: product +%d · verify +%d lines since base %s · %s of %sh est. — %s\n", p, v, b, e, h, (r == "" ? "ok" : "TRIPPED: " substr(r, 3))
  }'
}

# --- report and --csv: normalize every source into one pipe-delimited stream ----
# SB|3or4|date|slug|slices|blocks|stuck|codex_runs|interventions|duration|outcome|harness
#   (v3 rows leave the v4-only columns empty; scoreboard-v4.csv keeps the last
#    row per slug — corrections are appended)
# CUR|slug   DL|slug|block|stuck|escalate|gate_error|waiting|codex|approve|reject|unbound|none
# CARD|slug|closed|close_row|[x] slices without evidence (space-separated)
# RL|slug|runs|completed|not_started|blocked|record_failed     (v4 pair runlogs)
# DF|date|slug|slice|finder|phase|severity|n|fixed_in
# FC|slug|sha7|date|subject|files      (fix-commit candidates)
# FR|date|harness|area|severity|summary|ref
normalize() {
  local d s dl sbs=()
  [ -s "$SB" ] && sbs+=("$SB")
  [ -s "$SB4" ] && sbs+=("$SB4")
  if [ ${#sbs[@]} -gt 0 ]; then
    awk -F, -v v4f="$SB4" '
      function f(k,   i, v) { i = col[k]; if (i == "" || i > NF) return ""; v = $i; gsub(/[| \r]/, "_", v); return v }
      FNR == 1 { split("", col); for (i = 1; i <= NF; i++) { k = $i; sub(/\r$/, "", k); col[k] = i }; v4 = (FILENAME == v4f); next }
      NF < 2 { next }
      { h = f("harness"); if (h == "") h = "unknown"
        r = sprintf("SB|%d|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s", (v4 ? 4 : 3), f("date"), f("slug"), f("slices"), f("blocks"),
                    f("stuck"), f("codex_runs"), f("interventions"), f("duration_min"), f("outcome"), h)
        if (!v4) { print r; next }
        s = f("slug"); if (!(s in last)) ord[++no] = s; last[s] = r }
      END { for (i = 1; i <= no; i++) print last[ord[i]] }' "${sbs[@]}"
  fi
  printf 'CUR|%s\n' "$(tr -d '[:space:]' 2>/dev/null < "$T/CURRENT" || true)"
  for d in "$T"/*/; do
    [ -d "$d" ] || continue
    s="$(basename "$d")"; dl="${d}donelog"
    if [ -f "$dl" ]; then
      awk -F'\t' -v s="$s" '
        $2 == "BLOCK" {b++} $2 == "STUCK" {st++} $2 == "GATE-ERROR" {g++} $2 == "WAITING" {w++}
        $2 == "ESCALATE" && $7 !~ /^escalated: / {e++}
        $2 == "CODEX" {c++; r[$7]++}
        END {printf "DL|%s|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d\n", s, b, st, e, g, w, c, r["approve"], r["reject"], r["unbound"], r["none"]}' "$dl"
    else
      dl=/dev/null
    fi
    [ -f "${d}card.md" ] || continue   # no card: a v3 task dir, history only
    # An [x] counts as evidence.sh's only with its check-mark tokens and a DONE row.
    awk -F'\t' -v s="$s" -v dl="$dl" '
      FILENAME == dl { if ($2 == "DONE") done[$3] = 1; if ($2 == "CLOSE") cr = 1; next }
      /^Closed:/ { cl = 1 }
      /^- \[x\] S[0-9]+([ \t]|$)/ { match($0, /S[0-9]+/); id = substr($0, RSTART, RLENGTH)
        if (index($0, " ✓ ") == 0 || !(id in done)) x = x " " id }
      END { printf "CARD|%s|%d|%d|%s\n", s, cl, cr, substr(x, 2) }' "$dl" "${d}card.md"
    # task-pair.sh runlog (11 TAB columns, detail last). An end:failed whose
    # detail is not_started or herdr_blocked never reached the model: no
    # record, no quota, and never a Codex run here either.
    [ -f "${d}pair/runlog" ] && awk -F'\t' -v s="$s" '
      $3 ~ /^end:/ { if ($3 == "end:failed" && ($11 == "not_started" || $11 == "herdr_blocked")) ns++
                     else { n++; if ($3 == "end:completed") ok++ } }
      $3 == "blocked" {bl++} $3 == "record_failed" {rf++}
      END { if (n + ns + bl + rf) printf "RL|%s|%d|%d|%d|%d|%d\n", s, n, ok, ns, bl, rf }' "${d}pair/runlog"
  done
  if [ -s "$DF" ]; then
    if [ "$(head -n 1 "$DF" | tr -d '\r')" = "$DF_HDR" ]; then
      awk -F, 'NR > 1 && NF >= 10 { gsub(/[|\r]/, "_"); printf "DF|%s|%s|%s|%s|%s|%s|%s|%s\n", $1, $2, $3, $4, $5, $6, $7, $9 }' "$DF"
    else
      echo "harness-report: $DF has a non-v4 header — its rows are skipped (migrate them to $DF_HDR)" >&2
    fi
  fi
  [ "$MODE" = csv ] || fix_candidates
  if [ -f "$FR" ]; then
    awk -F, '
      NR==1 && $1=="date" {next}
      NF>=4 {
        sum=""; for (i=5;i<NF;i++) sum = (sum=="" ? $i : sum " " $i)
        ref=(NF>=6 ? $NF : "-"); if (NF==5) { sum=$5; ref="-" }
        gsub(/\|/,"/",sum)
        h=($2==""?"unknown":$2)
        printf "FR|%s|%s|%s|%s|%s|%s\n", $1, h, $3, $4, sum, ref
      }' "$FR"
  fi
}

# Fix-commit candidates (D18): commits within 30 days after a card's last
# CLOSE row that touch the files the task changed (base..Closed head:, minus
# .ai_context/ and .claude/), with a fix-like subject. A sha already in
# defects.csv fixed_in (confirmed or dismissed) is settled. No git -> none.
fix_candidates() {
  git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || return 0
  local known="" card s base head ts t0 files fl f
  if [ -s "$DF" ] && [ "$(head -n 1 "$DF" | tr -d '\r')" = "$DF_HDR" ]; then
    known=" $(awk -F, 'NR > 1 && $9 ~ /^[0-9a-f]+$/ {printf "%s ", substr($9, 1, 7)}' "$DF")"
  fi
  for card in "$T"/*/card.md; do
    [ -f "$card" ] || continue
    s="$(basename "$(dirname "$card")")"
    head="$(sed -nE 's/^Closed: tree:[0-9a-f]+ head:([0-9a-f]+) .*/\1/p' "$card" | tail -n 1)"
    base="$(sed -nE 's/^<!-- card v4 .* base: ([0-9a-f]{7,40}) .*/\1/p' "$card" | head -n 1)"
    ts="$(awk -F'\t' '$2 == "CLOSE" {t = $1} END {print t}' "${card%card.md}donelog" 2>/dev/null || true)"
    [ -n "$head" ] && [ -n "$base" ] && t0="$(epoch "$ts")" || continue
    files="$(git -C "$ROOT" diff --name-only --no-renames "$base" "$head" -- . ':(exclude).ai_context' ':(exclude).claude' 2>/dev/null)" || continue
    [ -n "$files" ] || continue
    fl=()
    while IFS= read -r f; do fl+=("$f"); done <<<"$files"
    GIT_LITERAL_PATHSPECS=1 git -C "$ROOT" log --since="@$t0" --until="@$((t0 + 30 * 86400))" \
        --format='%x01%H %cs %s' --name-only HEAD -- "${fl[@]}" 2>/dev/null |
      awk -v s="$s" -v known="$known" '
        function fixlike(t,   l) { l = tolower(t)
          if (l ~ /^chore\(context\)/) return 0
          if (l ~ /^(fix|hotfix|revert)(\([^)]*\))?!?:/ || l ~ /^revert "/) return 1
          return (" " l " ") ~ /[^a-z0-9_](fix|fixes|fixed|bug|regression)[^a-z0-9_]/ }
        function flush() {
          if (sha != "" && fixlike(subj) && index(known, " " substr(sha, 1, 7) " ") == 0) {
            gsub(/\|/, "/", subj); if (length(subj) > 60) subj = substr(subj, 1, 57) "..."
            printf "FC|%s|%s|%s|%s|%d\n", s, substr(sha, 1, 7), dt, subj, nf }
          sha = "" }
        /^\001/ { flush(); h = substr($0, 2); i = index(h, " "); sha = substr(h, 1, i - 1)
                  dt = substr(h, i + 1, 10); subj = substr(h, i + 12); nf = 0; next }
        NF { nf++ }
        END { flush() }' || true
  done
  return 0
}

report() {
  check_sb
  normalize | awk -F'|' -v mode="$MODE" -v project="$(basename "$(cd "$ROOT" && pwd)")" -v stamp="$(stamp)" -v hdr="$CSV_V2" '
function sortkeys(arr, keys,   k, n, i, j, t) {
  n=0; for (k in arr) keys[++n]=k
  for (i=2;i<=n;i++){ t=keys[i]; j=i-1
    while (j>0 && keys[j]>t){ keys[j+1]=keys[j]; j-- } keys[j+1]=t }
  return n
}
function median(list, n,   i, j, t, v) {
  if (n==0) return "-"
  for (i=2;i<=n;i++){ t=list[i]; j=i-1
    while (j>0 && list[j]+0>t+0){ list[j+1]=list[j]; j-- } list[j+1]=t }
  if (n%2) v=list[(n+1)/2]; else v=(list[n/2]+list[n/2+1])/2
  return int(v+0.5)
}
function isnum(s){ return s ~ /^[0-9]+(\.[0-9]+)?$/ }
function vof(s) { return (s in slug2ver) ? slug2ver[s] : stamp }   # in-flight tasks: the current stamp
function per_slug(a,   k, n, i, o) { n = sortkeys(a, k); o = ""
  for (i = 1; i <= n; i++) if (a[k[i]] > 0) o = o (o == "" ? "" : " ") k[i] ":" a[k[i]]
  return o }

$1=="SB" {
  n++; src=$2; slug=$4; sl=$5; bl=$6; st=$7; cx=$8; iv=$9; dur=$10; out=$11; h=$12
  o[out]++; ver[h]++; vout[h","out]++; slug2ver[slug]=h; sb_seen[slug]=1
  if (out!="success" && out!="failed" && out!="abandoned")
    en[++nen]="scoreboard " slug ": outcome=\"" out "\""
  if (src==4) { v4[slug]=1; sb_b[slug]=bl; sb_s[slug]=st; sb_c[slug]=cx }
  if (isnum(sl)) { sl_ver[h]+=sl; sl_all[++sl_n]=sl }
  if (isnum(cx)) { cx_ver[h]+=cx; cx_all[++cx_n]=cx }
  if (isnum(iv)) { iv_all[++iv_n]=iv; iv_ver[h]+=iv }
  if (isnum(dur)) { du_all[++du_n]=dur; dv_n[h]++; dur_ver[h","dv_n[h]]=dur }
}
$1=="CUR" { cur=$2 }
$1=="DL" { s=$2; ndl++; dl[s]=1; d_b[s]=$3; d_s[s]=$4; d_e[s]=$5; d_g[s]=$6; d_c[s]=$8
  t_b+=$3; t_s+=$4; t_e+=$5; t_g+=$6; t_w+=$7; t_c+=$8; t_ap+=$9; t_rj+=$10; t_ub+=$11; t_nv+=$12 }
$1=="CARD" { s=$2; ncard++; card[s]=1
  m=split($5, X, " "); for (i=1;i<=m;i++) xev[++nxev]="tasks/" s "/ " X[i]
  if ($3==1 && $4==0) clw[++nclw]="tasks/" s "/" }
$1=="RL" { nrl++; r_n+=$3; r_ok+=$4; r_ns+=$5; r_bl+=$6; r_rf+=$7 }
$1=="DF" {
  ndf++; f_s[ndf]=$3; f_fi[ndf]=$5; f_ph[ndf]=$6; f_sev[ndf]=$7; f_n[ndf]=(isnum($8) ? $8+0 : 0)
  if ($5!="checker" && $5!="codex" && $5!="human" && $5!="production" && $5!="post-close-review" && $5!="fix-commit")
    en[++nen]="defects " $2 ": finder=\"" $5 "\""
  if ($6!="pre-done" && $6!="post-done" && $6!="post-close" && $6!="-")
    en[++nen]="defects " $2 ": phase=\"" $6 "\""
  if ($7!="blocker" && $7!="major" && $7!="minor" && $7!="unrated" && $7!="none")
    en[++nen]="defects " $2 ": severity=\"" $7 "\""
}
$1=="FC" { fc[++nfc]=$3 " " $4 " \"" $5 "\" touches " $6 " file(s) of tasks/" $2 "/ — a defect: bash scripts/harness-report.sh --defect " $2 " - fix-commit <severity> \"<summary>\" - --fixed-in " $3 "; not one: bash scripts/harness-report.sh --defect-dismiss " $3 }
$1=="FR" {
  fr++; fh=$3; fa=$4; fs=$5
  fr_ver[fh]++; fr_area[fa]++; fr_sev[fs]++; ver_seen[fh]=1
  if (fs=="blocker") { fb++; fb_ver[fh]++; blk[fb]=$2"  "fa"  "$6"  ("$7")" }
  if (fa!="setup" && fa!="task" && fa!="wrap" && fa!="hooks" && fa!="sync" && fa!="skills" && fa!="other")
    en[++nen]="friction " $2 ": area=\"" fa "\""
  if (fs!="blocker" && fs!="friction" && fs!="papercut")
    en[++nen]="friction " $2 ": severity=\"" fs "\""
}
END {
  for (v in ver) ver_seen[v]=1
  # donelog and defect rows belong to the version their slug was scored under
  for (s in dl) { v=vof(s); ver_seen[v]=1
    b_ver[v]+=d_b[s]; s_ver[v]+=d_s[s]; e_ver[v]+=d_e[s]; g_ver[v]+=d_g[s]; stuck_by[s]=d_s[s]; gerr_by[s]=d_g[s] }
  for (i=1;i<=ndf;i++) {
    if (f_sev[i]=="none") continue
    v=(f_s[i]=="-" ? stamp : vof(f_s[i])); ver_seen[v]=1; k=f_n[i]; sev_n[f_sev[i]]+=k
    if (f_ph[i]=="pre-done") { pre_ver[v]+=k; pre+=k; pre_by[f_fi[i]]+=k }
    else if (f_ph[i]=="post-done") { pd_ver[v]+=k; pd+=k }
    else if (f_ph[i]=="post-close") { pc_ver[v]+=k; pc+=k; pc_by[f_fi[i]]+=k }
    else notask+=k
  }

  if (mode=="csv") {
    print hdr
    nv=sortkeys(ver_seen, vk)
    for (i=1;i<=nv;i++) { v=vk[i]
      m=dv_n[v]; for (j=1;j<=m;j++) dtmp[j]=dur_ver[v","j]
      printf "2,%s,%s,%d,%d,%d,%d,%d,%d,%d,%s,%d,%d,%d,%d,%d,%d,%d,%d,%d\n", project, v, \
        ver[v]+0, vout[v",success"]+0, vout[v",failed"]+0, vout[v",abandoned"]+0, \
        sl_ver[v]+0, cx_ver[v]+0, iv_ver[v]+0, median(dtmp, m+0), \
        b_ver[v]+0, s_ver[v]+0, e_ver[v]+0, g_ver[v]+0, pre_ver[v]+0, pd_ver[v]+0, pc_ver[v]+0, \
        fr_ver[v]+0, fb_ver[v]+0
    }
    exit 0
  }

  printf "harness-report · %s\n", project
  if (n==0 && fr==0 && ncard==0 && ndl==0 && ndf==0) { print "no harness data yet (no scoreboard, donelog, card, defects.csv or friction.csv rows)"; exit 0 }

  print "== dataset"
  line=sprintf("tasks: %d (success %d, failed %d, abandoned %d) · versions:", n, o["success"]+0, o["failed"]+0, o["abandoned"]+0)
  nv=sortkeys(ver, vk)
  for (i=1;i<=nv;i++) line=line sprintf(" %s(%d)", vk[i], ver[vk[i]])
  print line
  # Printed OUTSIDE the scoreboard-gated sections on purpose: the gate hands
  # a run over mid-task, before any /wrap writes a scoreboard row.
  if (t_s+0 > 0) print "!! donelog STUCK rows: " t_s " (" per_slug(stuck_by) ") — the gate handed a blocked slice to the human"
  if (t_g+0 > 0) print "!! donelog GATE-ERROR rows: " t_g " (" per_slug(gerr_by) ") — the gate failed open; read those rows"

  if (n>0) {
    print "== cells (harness — % only when N>=5)"
    for (i=1;i<=nv;i++) { c=vk[i]
      line=sprintf("%s : n=%d success=%d failed=%d abandoned=%d", c, ver[c], vout[c",success"]+0, vout[c",failed"]+0, vout[c",abandoned"]+0)
      if (ver[c]>=5) line=line sprintf(" (success %d%%)", int(vout[c",success"]*100/ver[c]+0.5))
      print line
    }
  }
  if (ndl>0 || nrl>0) {
    print "== gates"
    if (ndl>0) printf "donelog: BLOCK %d · STUCK %d · ESCALATE %d · GATE-ERROR %d · WAITING %d · CODEX %d (approve %d, reject %d, unbound %d, no verdict %d)\n", \
      t_b, t_s, t_e, t_g, t_w, t_c, t_ap, t_rj, t_ub, t_nv
    if (nrl>0) printf "pair runlog: Codex runs %d (completed %d, failed %d) · not started %d (never a run) · blocked mid-run %d · record failed %d\n", \
      r_n, r_ok, r_n-r_ok, r_ns, r_bl, r_rf
  }
  if (n>0) {
    print "== cost"
    printf "duration_min median: %s · slices median: %s · codex runs median: %s · interventions median: %s\n", \
      median(du_all, du_n+0), median(sl_all, sl_n+0), median(cx_all, cx_n+0), median(iv_all, iv_n+0)
  }
  if (ndf>0 || nfc>0) {
    print "== defects"
    printf "pre-done: %d (checker %d, codex %d) · post-done: %d · post-close: %d (human %d, production %d, post-close-review %d, fix-commit %d)%s\n", \
      pre, pre_by["checker"], pre_by["codex"], pd, pc, pc_by["human"], pc_by["production"], pc_by["post-close-review"], pc_by["fix-commit"], \
      (notask>0 ? sprintf(" · outside a task: %d", notask) : "")
    printf "by severity: blocker %d · major %d · minor %d · unrated %d\n", sev_n["blocker"], sev_n["major"], sev_n["minor"], sev_n["unrated"]
    for (i=1;i<=nfc && i<=10;i++) print "defect candidate: " fc[i]
    if (nfc>10) print "(+" nfc-10 " more)"
  }

  # Cross-checks: the scoreboard row is computed at /wrap and cards are
  # edited in sessions; donelogs are the ground truth. Disagreements are
  # surfaced, never repaired.
  print "== integrity"
  nix=0
  nc=sortkeys(card, ck)
  for (i=1;i<=nc;i++) { s=ck[i]
    if (s!=cur && !(s in sb_seen)) { print "  orphan task: tasks/" s "/ has a card but no scoreboard row — wrap it (abandoned runs count too)"; nix++ } }
  for (i=1;i<=nxev;i++) { print "  [x] without evidence: " xev[i] " — marked done by hand, not by evidence.sh done"; nix++ }
  for (i=1;i<=nclw;i++) { print "  Closed: without a CLOSE row: " clw[i] " — written by hand?"; nix++ }
  m=sortkeys(v4, sk)
  for (i=1;i<=m;i++) { s=sk[i]; if (!(s in dl)) continue
    if (isnum(sb_b[s]) && sb_b[s]+0 != d_b[s]+0) { print "  scoreboard/donelog mismatch: " s " — blocks: scoreboard " sb_b[s] ", donelog " d_b[s]; nix++ }
    if (isnum(sb_s[s]) && sb_s[s]+0 != d_s[s]+0) { print "  scoreboard/donelog mismatch: " s " — stuck: scoreboard " sb_s[s] ", donelog " d_s[s]; nix++ }
    if (isnum(sb_c[s]) && sb_c[s]+0 != d_c[s]+0) { print "  scoreboard/donelog mismatch: " s " — codex_runs: scoreboard " sb_c[s] ", donelog " d_c[s]; nix++ }
  }
  for (i=1;i<=nen;i++) { print "  enum violation: " en[i]; nix++ }
  if (nix==0) print "clean — scoreboard, donelogs, cards and defects agree"

  print "== friction"
  if (fr==0) print "none recorded"
  else {
    printf "blocker:%d friction:%d papercut:%d", fr_sev["blocker"]+0, fr_sev["friction"]+0, fr_sev["papercut"]+0
    line=" · by area:"
    na=sortkeys(fr_area, ak)
    for (i=1;i<=na;i++) line=line sprintf(" %s=%d", ak[i], fr_area[ak[i]])
    print line
    if (fb>0) { print "blockers:"
      for (i=1;i<=fb;i++) print "  " blk[i] }
  }
}'
}

# --- dispatch ---------------------------------------------------------------------
MODE=human SLUG="" OUTCOME=""
paths .
case "${1:-}" in
  --defect) shift; do_defect "$@"; exit 0 ;;
  --defect-dismiss) shift; do_dismiss "$@"; exit 0 ;;
esac
while [ $# -gt 0 ]; do
  case "$1" in
    --csv) MODE=csv ;;
    --row|--tripwire)
      [ $# -ge 2 ] || die 1 "$1 needs <slug>"
      MODE="${1#--}"; SLUG="$2"; shift ;;
    --outcome)
      [ $# -ge 2 ] || die 1 "--outcome needs success|failed|abandoned"
      OUTCOME="$2"; shift ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    -*) die 1 "unknown option $1" ;;
    *) ROOT="$1" ;;
  esac
  shift
done
[ -d "$ROOT" ] || die 1 "no such directory: $ROOT"
paths "$ROOT"
case "$MODE" in row|tripwire) slug_ok "$SLUG" || die 1 "--$MODE: '$SLUG' is not a task slug" ;; esac
[ -z "$OUTCOME" ] || [ "$MODE" = row ] || die 1 "--outcome goes with --row"
[ -z "$OUTCOME" ] || [[ "$OUTCOME" =~ ^(success|failed|abandoned)$ ]] || die 1 "--outcome '$OUTCOME' is not one of success|failed|abandoned"
case "$MODE" in
  row) do_row ;;
  tripwire) do_tripwire ;;
  *) report ;;
esac
