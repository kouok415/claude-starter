#!/usr/bin/env bash
#
# task-status.sh — regenerate the machine region of a task's STATUS.md.
#
# STATUS.md is the HUMAN-facing live view of an active /task: where the run
# stands, what each milestone promises (`- demo:` lines), the latest verify
# evidence, and every interpretation call on record. It is a VIEW, not
# memory: everything between the machine markers is regenerated here (the
# stop-gate calls this after every real verify run; session-start refreshes
# it on resume); the model owns only what follows the end marker
# (§Architecture). The file is gitignored — like .gate-cache it must never
# feed the PASS-cache fingerprint (its churn would evict the cache on every
# stop), and it can always be rebuilt from plan.md + spec.md + gatelog.
#
# Usage: task-status.sh <task-dir>     e.g. .ai_context/tasks/<slug>
# Silent on success. From hooks it is best-effort (`|| true` at call site).

set -uo pipefail

TDIR="${1:-}"
if [ -z "$TDIR" ] || [ ! -d "$TDIR" ]; then
  echo "usage: task-status.sh <task-dir>" >&2
  exit 1
fi
plan="$TDIR/plan.md"
[ -f "$plan" ] || exit 0   # mid-intake: nothing to render yet

slug="$(basename "$TDIR")"
root="$(cd "$TDIR/../../.." && pwd)"
status_md="$TDIR/STATUS.md"

title="$(sed -n 's/^# Plan:[[:space:]]*//p' "$plan" | head -n1)"
[ -n "$title" ] || title="$slug"

# Recorded profile/size (skip the placeholder options-form of the header).
profsize="$(grep -m1 'profile:' "$plan" | grep -v '|' \
  | sed -n 's/.*profile:[[:space:]]*\([a-z-]*\)[[:space:]]*;[[:space:]]*size:[[:space:]]*\([SML]\).*/\1 · \2/p')"

# --- Milestone table: id <TAB> status <TAB> title -----------------------------
ms_tsv="$(awk '
  /^## / {
    line = $0; sub(/^## /, "", line)
    st = "pending"
    if (line ~ /\[in_progress\]/) st = "in_progress"
    else if (line ~ /\[done\]/)   st = "done"
    sub(/[[:space:]]*\[(pending|in_progress|done)\].*$/, "", line)
    id = line; sub(/:.*$/, "", id)
    ttl = line; sub(/^[^:]*:[[:space:]]*/, "", ttl)
    gsub(/[`"\[\]{}<>|]/, "", ttl)
    printf "%s\t%s\t%s\n", id, st, ttl
  }
' "$plan")"
[ -n "$ms_tsv" ] || exit 0

n_total="$(printf '%s\n' "$ms_tsv" | wc -l | tr -d ' ')"
cur_id="$(printf '%s\n' "$ms_tsv" | awk -F'\t' '$2=="in_progress"{print $1; exit}')"
cur_idx="$(printf '%s\n' "$ms_tsv" | awk -F'\t' '$2=="in_progress"{print NR; exit}')"
cur_ttl="$(printf '%s\n' "$ms_tsv" | awk -F'\t' '$2=="in_progress"{print $3; exit}')"

if [ -n "$cur_id" ]; then
  position="▶ **${cur_id} (${cur_idx}/${n_total}) — ${cur_ttl}**"
elif ! printf '%s\n' "$ms_tsv" | awk -F'\t' '$2!="done"{exit 1}'; then
  position="✔ **all ${n_total} milestones done** — wrap-up pending"
else
  position="○ **no milestone armed** (${n_total} planned)"
fi

# --- Mermaid map --------------------------------------------------------------
mermaid="$(printf '%s\n' "$ms_tsv" | awk -F'\t' '
  {
    g = ($2=="done") ? "✓" : ($2=="in_progress") ? "▶" : "○"
    t = $3; if (length(t) > 30) t = substr(t, 1, 29) "…"
    gsub(/["()]/, "", t)
    n = sprintf("%s[\"%s %s %s\"]", $1, g, $1, t)
    out = (NR==1) ? n : out " --> " n
  }
  END { print "flowchart LR\n  " out }
')"

# --- Demo promises ------------------------------------------------------------
promises="$(awk '
  /^## / {
    id = $0; sub(/^## /, "", id); sub(/:.*$/, "", id)
    st = ($0 ~ /\[done\]/) ? "✓" : ($0 ~ /\[in_progress\]/) ? "▶" : "○"
    next
  }
  /^- demo:/ {
    d = $0; sub(/^- demo:[[:space:]]*/, "", d); gsub(/`/, "", d)
    printf "- %s %s — %s\n", st, id, d
  }
' "$plan")"

# --- Change footprint (vs the default branch, when in git) --------------------
diffline=""
if git -C "$root" rev-parse HEAD >/dev/null 2>&1; then
  base=""
  for b in main master; do
    git -C "$root" rev-parse --verify -q "$b" >/dev/null 2>&1 && { base="$b"; break; }
  done
  if [ -n "$base" ]; then
    diffline="$(git -C "$root" diff --shortstat "$base"...HEAD 2>/dev/null | sed 's/^ *//')"
  fi
fi

# --- Latest gate evidence -----------------------------------------------------
gate_line=""
if [ -s "$TDIR/gatelog" ]; then
  gate_line="$(awk -F'\t' 'END { printf "%s %s @ %s", $3, $2, $1 }' "$TDIR/gatelog")"
fi
verify_tail=""
[ -s "$TDIR/.last-verify" ] && verify_tail="$(cat "$TDIR/.last-verify")"

# --- Interpretation ledger (view of spec §Assumptions) ------------------------
assumed="$(grep -o '\[ASSUMED[^]]*\]' "$TDIR/spec.md" 2>/dev/null | sed 's/^/- /')"

# --- Preserve the model-owned tail --------------------------------------------
END_MARK='<!-- status:machine:end -->'
if [ -f "$status_md" ] && grep -qF "$END_MARK" "$status_md"; then
  tail_part="$(awk -v m="$END_MARK" 'found; index($0, m) {found=1}' "$status_md")"
elif [ -f "$status_md" ]; then
  tail_part="$(cat "$status_md")"   # marker lost: demote old content, lose nothing
else
  tail_part="## Architecture

_(unwritten — orchestrator: at plan approval, describe here in problem
language what is being built and how the pieces fit; keep it current as
milestones land)_"
fi

tmp="$(mktemp "${TMPDIR:-/tmp}/task-status.XXXXXX")" || exit 0
{
  printf '# Status: %s\n\n' "$title"
  printf '<!-- VIEW, not memory — machine region regenerated by scripts/task-status.sh; -->\n'
  printf '<!-- edit ONLY below the end marker. Gitignored; rebuilt from plan/spec/gatelog. -->\n'
  printf '<!-- status:machine:begin -->\n'
  printf '%s' "$position"
  [ -n "$profsize" ] && printf ' · %s' "$profsize"
  printf ' · refreshed %s\n\n' "$(date '+%Y-%m-%d %H:%M')"
  printf '```mermaid\n%s\n```\n\n' "$mermaid"
  if [ -n "$promises" ]; then
    printf '**Promises (`- demo:` — what you will be able to see):**\n%s\n\n' "$promises"
  fi
  [ -n "$diffline" ] && printf '**Change footprint:** %s\n\n' "$diffline"
  if [ -n "$gate_line" ]; then
    printf '**Last gate:** %s\n' "$gate_line"
    if [ -n "$verify_tail" ]; then
      printf '\n```\n%s\n```\n' "$verify_tail"
    fi
    printf '\n'
  fi
  printf '**Interpretations on record (spec §Assumptions):**\n%s\n' \
    "${assumed:-- none yet}"
  printf '%s\n\n' "$END_MARK"
  printf '%s\n' "$tail_part"
} > "$tmp" && mv "$tmp" "$status_md"
exit 0
