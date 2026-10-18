#!/usr/bin/env bash
#
# harness-report.sh — deterministic scoring over the harness's own usage
# data. Reads three sources under PROJECT_ROOT (each optional):
#
#   .ai_context/scoreboard.csv    one row per finished/abandoned /task
#   .ai_context/tasks/*/gatelog   TAB rows: ts, milestone, verdict, cmd/reason
#   .ai_context/friction.csv      date,harness,area,severity,summary,ref
#
# The scored object is the HARNESS VERSION (relative, version-over-version)
# — never the model, the project, or the human. Hard rules, on purpose:
#   - percentages print only where a cell has N >= 5 (below: counts only —
#     small N is noise, not signal);
#   - no composite score, ever (single numbers invite Goodhart);
#   - everything is computed from files, nothing from memory.
#
# Usage: harness-report.sh [--csv] [PROJECT_ROOT]      (default root: .)
#   --csv    machine mode: one aggregate row per harness version (the
#            fleet-aggregation interface; header below is a contract).
# Exit: 0 report produced (even "no data") · 1 usage error · 2 malformed
#       scoreboard header.

set -euo pipefail

MODE=human
ROOT=.
for a in "$@"; do
  case "$a" in
    --csv) MODE=csv ;;
    -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
    -*) echo "harness-report: unknown option $a" >&2; exit 1 ;;
    *) ROOT="$a" ;;
  esac
done
[ -d "$ROOT" ] || { echo "harness-report: no such directory: $ROOT" >&2; exit 1; }

AI="$ROOT/.ai_context"
SB="$AI/scoreboard.csv"
FR="$AI/friction.csv"
PROJECT="$(basename "$(cd "$ROOT" && pwd)")"

# Validate the scoreboard header up front (before any output is produced).
if [ -f "$SB" ]; then
  sb_hdr="$(head -1 "$SB")"
  case "$sb_hdr" in date,*) : ;; *)
    echo "harness-report: malformed scoreboard header in $SB" >&2; exit 2 ;;
  esac
  for need in slug outcome; do
    case ",$sb_hdr," in *",$need,"*) : ;; *)
      echo "harness-report: scoreboard header lacks the $need column ($SB)" >&2; exit 2 ;;
    esac
  done
fi

# --- normalize the three sources into one pipe-delimited stream ------------
# SB|date|slug|profile|size|milestones|gate_failures|rung|interv|duration|outcome|harness
# GL|slug|fail_rows|integrity_rows|unarmed_rows|stuck_rows
# VC|slug|milestone|last_fail_cmd|pass_cmd
# DG|slug|gaps|med_high_done|milestones
# FR|date|harness|area|severity|summary|ref
normalize() {
  if [ -f "$SB" ]; then
    awk -F, '
      NR==1 { for (i=1;i<=NF;i++) col[$i]=i; next }
      NF<2 {next}
      { printf "SB|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n", \
          f(col["date"]), f(col["slug"]), f(col["profile"]), f(col["size"]), \
          f(col["milestones"]), f(col["gate_failures"]), f(col["highest_rung"]), \
          f(col["interventions"]), f(col["duration_min"]), f(col["outcome"]), \
          (f(col["harness"])=="" ? "unknown" : f(col["harness"])) }
      function f(i){ if (i=="" || i==0 || i>NF) return ""; v=$i; gsub(/[| ]/,"_",v); return v }
    ' "$SB"
  fi
  if [ -d "$AI/tasks" ]; then
    for gl in "$AI"/tasks/*/gatelog; do
      [ -f "$gl" ] || continue
      slug="$(basename "$(dirname "$gl")")"
      # VC rows: a milestone that went green on a command none of its FAILs
      # ran — the verify was changed after it failed (A5: whoever wants the
      # green should not be the only one who saw the gate move).
      awk -F'\t' -v s="$slug" '
        $3=="FAIL"{fail++; failed[$2]=1; fcmd[$2 SUBSEP $4]=1; lastf[$2]=$4}
        $3=="PASS" && ($2 in failed) && !(($2 SUBSEP $4) in fcmd) && !($2 in vc) {
          vc[$2]=1; vcl[++nvc]=$2 "|" cut(lastf[$2]) "|" cut($4) }
        $3=="INTEGRITY"{integ++} $3=="UNARMED"{unarm++}
        $3=="STUCK"{stuck++}
        function cut(c){ gsub(/\|/,"/",c); return (length(c)>70 ? substr(c,1,67) "..." : c) }
        END{ printf "GL|%s|%d|%d|%d|%d\n", s, fail, integ, unarm, stuck
             for (i=1;i<=nvc;i++) printf "VC|%s|%s\n", s, vcl[i] }' "$gl"
    done
    # Task-dir census for the integrity cross-checks: CURRENT slug, plus
    # per-dir [done]-milestone counts and how many have gate evidence.
    cur=""
    [ -f "$AI/tasks/CURRENT" ] && cur="$(tr -d '[:space:]' < "$AI/tasks/CURRENT")"
    printf 'CUR|%s\n' "$cur"
    T="$(printf '\t')"
    for pl in "$AI"/tasks/*/plan.md; do
      [ -f "$pl" ] || continue
      tdir="${pl%/plan.md}"; tslug="$(basename "$tdir")"
      dn=0; cv=0
      while IFS= read -r mid; do
        [ -n "$mid" ] || continue
        dn=$((dn+1))
        if [ -f "$tdir/gatelog" ] && { grep -qF "${T}${mid}${T}PASS" "$tdir/gatelog" \
             || grep -qF "${T}${mid}${T}UNARMED" "$tdir/gatelog"; }; then
          cv=$((cv+1))
        fi
      done < <(sed -n 's/^## \([^:]*\):.*\[done\].*/\1/p' "$pl")
      printf 'TD|%s|%d|%d\n' "$tslug" "$dn" "$cv"
      # Verification depth (M/L only — S skips the verifier step by design):
      # a [done] risk:med/high milestone whose verifier seat left no trace.
      # Claude seat = a spawnlog verifier row for the milestone ("other" in
      # spawnlogs that predate the verifier class); pair-*: the Codex seat
      # (runlog verifier start row) takes med and joins high. No spawnlog =
      # SubagentStart never fired here, so the Claude seat goes unjudged.
      sl=/dev/null; rl=/dev/null
      [ -s "$tdir/spawnlog" ] && sl="$tdir/spawnlog"
      [ -s "$tdir/pair/runlog" ] && rl="$tdir/pair/runlog"
      awk -F'\t' -v s="$tslug" -v sl="$sl" -v rl="$rl" '
        FILENAME==sl { hs=1; if ($3=="verifier") vcls=1; sp[$2 SUBSEP $3]=1; next }
        FILENAME==rl { if ($3=="start" && $4=="verifier") rv[$5]=1; next }
        /^<!-- profile:/ { if (match($0, /profile: *[a-z-]+/)) { prof=substr($0, RSTART, RLENGTH); sub(/profile: */, "", prof) }
                           if (match($0, /size: *[SML]/)) size=substr($0, RSTART+RLENGTH-1, 1) }
        /^## / { flush(); ms=""; r=""
                 if ($0 ~ /\[done\]/) { ms=$0; sub(/^## /, "", ms); sub(/:.*/, "", ms) }
                 next }
        ms!="" && /^- risk:/ { r=$0; sub(/^- risk: */, "", r); sub(/[^a-z].*/, "", r) }
        function flush(   pr, ok) {
          if (ms=="" || (r!="med" && r!="high")) return
          nd++; ok=1; pr=(prof ~ /^pair-/)
          if (hs && (!pr || r=="high") && !((ms SUBSEP (vcls ? "verifier" : "other")) in sp)) ok=0
          if (pr && !(ms in rv)) ok=0
          if (!ok) { ng++; gl=gl " " ms }
        }
        END { flush(); if (ng && (size=="M" || size=="L")) printf "DG|%s|%d|%d|%s\n", s, ng, nd, substr(gl, 2) }
      ' "$sl" "$rl" "$pl"
    done
  fi
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

# --- aggregate + format -----------------------------------------------------
normalize | awk -F'|' -v mode="$MODE" -v project="$PROJECT" '
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

$1=="SB" {
  n++; d=$2; slug=$3; prof=($4==""?"?":$4); size=($5==""?"?":$5)
  miles=$6; gf=$7; rung=$8; iv=$9; dur=$10; out=$11; h=$12
  o[out]++; ver[h]++; vout[h","out]++
  slug2ver[slug]=h
  sb_seen[slug]=1; sb_gf[slug]=gf
  if (out!="success" && out!="failed" && out!="abandoned")
    enum_bad[++neb]="scoreboard " slug ": outcome=\"" out "\""
  if (prof!="opus-tier" && prof!="fable-tier" && prof!="mixed" && prof!="mixed-judge" && prof!="pair-codex" && prof!="?")
    enum_bad[++neb]="scoreboard " slug ": profile=\"" prof "\""
  if (size!="S" && size!="M" && size!="L" && size!="?")
    enum_bad[++neb]="scoreboard " slug ": size=\"" size "\""
  ck=h" · "prof" · "size; cell_n[ck]++; cell[ck","out]++
  if (isnum(miles)) mile_sum+=miles
  if (isnum(gf)) { gf_sum+=gf; gf_ver[h]+=gf }
  if (isnum(rung)) { if (rung>=2) r2++; if (rung>=3) { r3++; r3_ver[h]++ } }
  if (isnum(iv)) { iv_all[++iv_n]=iv; iv_ver[h]+=iv }
  if (isnum(dur)) { dur_size[size]=dur_size[size]" "dur
                    dv_n[h]++; dur_ver[h","dv_n[h]]=dur }
}
$1=="GL" { gl_fail[$2]=$3; gl_integ[$2]=$4; gl_unarm[$2]=$5; gl_stuck[$2]=$6 }
$1=="CUR" { cur=$2 }
$1=="DG" { dgm[++ndg]="tasks/" $2 "/ — " $3 " of " $4 " [done] risk:med/high milestones had no verifier spawn while in progress (" $5 ")" }
$1=="VC" { vcm[++nvc]="tasks/" $2 "/ " $3 " — FAIL ran `" $4 "`, PASS ran `" $5 "`" }
$1=="TD" { td_done[$2]=$3; td_cov[$2]=$4; ntd++ }
$1=="FR" {
  fr++; fh=$3; fa=$4; fs=$5
  fr_ver[fh]++; fr_area[fa]++; fr_sev[fs]++; ver_seen[fh]=1
  if (fs=="blocker") { fb++; fb_ver[fh]++; blk[fb]=$2"  "fa"  "$6"  ("$7")" }
  if (fa!="setup" && fa!="task" && fa!="wrap" && fa!="hooks" && fa!="sync" && fa!="skills" && fa!="other")
    enum_bad[++neb]="friction " $2 ": area=\"" fa "\""
  if (fs!="blocker" && fs!="friction" && fs!="papercut")
    enum_bad[++neb]="friction " $2 ": severity=\"" fs "\""
}
END {
  # attribute gatelog rows to versions via the slug map
  for (s in gl_fail) {
    v=(s in slug2ver ? slug2ver[s] : "unknown")
    glf_ver[v]+=gl_fail[s]; gli_ver[v]+=gl_integ[s]
    glf+=gl_fail[s]; gli+=gl_integ[s]; glu+=gl_unarm[s]
    if (gl_stuck[s]+0 > 0) { gls+=gl_stuck[s]; gls_slugs=gls_slugs (gls_slugs?" ":"") s ":" gl_stuck[s] }
  }
  for (v in ver) ver_seen[v]=1

  if (mode=="csv") {
    print "project,harness,n_tasks,n_success,n_failed,n_abandoned,gate_fail_rows,integrity_rows,rung_ge3,interventions_sum,duration_med,friction_total,friction_blockers"
    nv=sortkeys(ver_seen, vk)
    for (i=1;i<=nv;i++) { v=vk[i]
      m=dv_n[v]; for (j=1;j<=m;j++) dtmp[j]=dur_ver[v","j]
      printf "%s,%s,%d,%d,%d,%d,%d,%d,%d,%d,%s,%d,%d\n", project, v, \
        ver[v]+0, vout[v",success"]+0, vout[v",failed"]+0, vout[v",abandoned"]+0, \
        gf_ver[v]+0, gli_ver[v]+0, r3_ver[v]+0, iv_ver[v]+0, median(dtmp, m+0), \
        fr_ver[v]+0, fb_ver[v]+0
    }
    exit 0
  }

  printf "harness-report · %s\n", project
  # Early exit only when there is truly nothing: task dirs without any
  # scoreboard are exactly the orphan case the integrity section exists
  # for, so their presence must not short-circuit it.
  if (n==0 && fr==0 && ntd==0) { print "no harness data yet (scoreboard.csv and friction.csv absent or empty)"; exit 0 }

  print "== dataset"
  line=sprintf("tasks: %d (success %d, failed %d, abandoned %d) · versions:", n, o["success"]+0, o["failed"]+0, o["abandoned"]+0)
  nv=sortkeys(ver, vk)
  for (i=1;i<=nv;i++) line=line sprintf(" %s(%d)", vk[i], ver[vk[i]])
  print line
  # STUCK = the gate yielded a red milestone to the human (v3.9 counted
  # yields). Printed OUTSIDE the scoreboard-gated sections on purpose: the
  # handoff happens mid-task, before any wrap writes a scoreboard row.
  if (gls+0 > 0) print "!! gatelog STUCK yields: " gls " (" gls_slugs ") — the gate handed a red milestone to the human"

  if (n>0) {
    print "== cells (harness · profile · size — % only when N>=5)"
    nc=sortkeys(cell_n, ck2)
    for (i=1;i<=nc;i++) { c=ck2[i]
      line=sprintf("%s : n=%d success=%d failed=%d abandoned=%d", c, cell_n[c], cell[c",success"]+0, cell[c",failed"]+0, cell[c",abandoned"]+0)
      if (cell_n[c]>=5) line=line sprintf(" (success %d%%)", int(cell[c",success"]*100/cell_n[c]+0.5))
      print line
    }
    print "== gates"
    if (mile_sum>0) printf "scoreboard gate_failures: %d across %d milestones (%.2f per milestone)\n", gf_sum, mile_sum, gf_sum/mile_sum
    else printf "scoreboard gate_failures: %d (milestone count unavailable)\n", gf_sum
    line=sprintf("gatelog FAIL rows: %d · INTEGRITY rows: %d", glf+0, gli+0)
    if (gli>0) { line=line" ("
      ni=sortkeys(gli_ver, ik)
      for (i=1;i<=ni;i++) if (gli_ver[ik[i]]>0) line=line sprintf("%s%s:%d", (sub_first++?" ":""), ik[i], gli_ver[ik[i]])
      line=line")" }
    print line sprintf(" · UNARMED rows: %d", glu+0)
    printf "== escalation\nrung>=2: %d of %d · rung>=3: %d of %d\n", r2+0, n, r3+0, n
    print "== cost"
    line="duration_min median:"
    ns=sortkeys(dur_size, sk)
    if (ns==0) line=line" -"
    for (i=1;i<=ns;i++) { m=split(dur_size[sk[i]], dl, " "); line=line sprintf(" %s=%d", sk[i], median(dl, m)) }
    print line sprintf(" · interventions median: %s", median(iv_all, iv_n+0))
  }

  # Cross-checks: the scoreboard is model-written at /wrap; the gatelog and
  # task dirs are ground truth. Disagreements are surfaced, never repaired.
  print "== integrity"
  nix=0
  for (s in sb_seen) if (s in gl_fail) {
    if (isnum(sb_gf[s]) && (sb_gf[s]+0) != (gl_fail[s]+0)) {
      print "  gate_failures mismatch: " s " — scoreboard says " sb_gf[s] ", gatelog has " gl_fail[s] " FAIL row(s)"; nix++
    }
  }
  for (s in td_done) {
    if (s == cur) continue
    if (!(s in sb_seen)) {
      print "  orphan task: tasks/" s "/ has a plan but no scoreboard row — wrap it (abandoned runs count too)"; nix++
    } else if (td_cov[s]+0 < td_done[s]+0) {
      print "  gate evidence gap: tasks/" s "/ — " td_cov[s] " of " td_done[s] " [done] milestones have a PASS/UNARMED row (pre-v3.6 run?)"; nix++
    }
  }
  for (i=1; i<=neb; i++) { print "  enum violation: " enum_bad[i]; nix++ }
  for (i=1; i<=ndg; i++) { print "  verification depth gap: " dgm[i]; nix++ }
  for (i=1; i<=nvc; i++) { print "  verify changed after FAIL: " vcm[i] " — the reason belongs in lessons.md"; nix++ }
  if (nix==0) print "clean — scoreboard, gatelogs and task dirs agree"

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
