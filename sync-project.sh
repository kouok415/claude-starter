#!/usr/bin/env bash
#
# sync-project.sh — bring an existing claude-starter project up to the
# current template's mechanisms.
#
# Conservative by design:
#   - by default only ADDS files that are missing (never overwrites)
#   - --update-stock also replaces, and deletes when the template retired
#     them, files byte-identical to some historical template version —
#     provably unmodified stock copies; customized files are never touched
#   - the v4 /task core (CORE below) moves as one unit: while any of its
#     files would stay older than the template, none of it is added or
#     replaced and nothing is retired
#   - ships what the template COMMITTED (its HEAD), never its working tree
#   - never writes through a symlink
#   - appends known-safe .gitignore lines if absent
#   - everything else is REPORTED as a suggestion for you to apply by hand
#
# Usage:
#   ./sync-project.sh [--update-stock] [--adopt] <path-to-project>
# Exit: 0 done · 1 usage error, not a project, or an active v3 task under
#       --update-stock (nothing written) · 2 --update-stock from a template
#       without git history (nothing written), or MIGRATION INCOMPLETE: a
#       customized core file kept the v4 core back (other files synced)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET=""; UPDATE_STOCK=0; ADOPT=0
for a in "$@"; do
  case "$a" in
    --update-stock) UPDATE_STOCK=1 ;;
    --adopt)        ADOPT=1 ;;
    -h|--help)
      echo "Usage: ./sync-project.sh [--update-stock] [--adopt] <path-to-project>"
      echo "  --update-stock  replace mechanism files whose content matches ANY"
      echo "                  historical template version (provably unmodified"
      echo "                  stock copies), and delete stock copies of files the"
      echo "                  template retired; customized files are never touched"
      echo "  --adopt         onboard an existing non-starter repo: create the"
      echo "                  .ai_context skeleton + CLAUDE.md template first"
      echo "Exit: 0 done; 1 usage, not a project, or an active v3 task (--update-stock);"
      echo "      2 --update-stock without template git history, or MIGRATION INCOMPLETE"
      exit 0 ;;
    *) if [ -z "$TARGET" ]; then TARGET="$a"; else echo "Error: unexpected argument: $a"; exit 1; fi ;;
  esac
done
[ -n "$TARGET" ] || { echo "Usage: ./sync-project.sh [--update-stock] [--adopt] <path-to-project>"; exit 1; }
TARGET="${TARGET%/}"

added=()
updated=()
suggest=()
retired=()
retire_pending=()
shipped=()
linked=()
STARTED=0 FINISHED=0 STAMPED="" TPLD="" GI_CHANGED=0 V3IDLE=0

# The v4 /task core: the gate, the hooks and settings that wire it, the
# helpers they share, the evidence and pair scripts, the task skill and the
# two agents it spawns. Half of it on v4 fails open or refuses (a v4 gate on
# a v3 guard-patterns.sh, a v3 task skill whose agents were retired).
CORE=" .claude/settings.json .claude/hooks/stop-gate.sh .claude/hooks/session-start.sh .claude/hooks/spawn-log.sh .claude/hooks/bash-guard.sh .claude/hooks/guard-patterns.sh scripts/evidence.sh scripts/task-pair.sh .claude/skills/task/SKILL.md .claude/skills/task/reference.md .claude/skills/task/pair.md .claude/agents/executor.md .claude/agents/checker.md "
is_core() { case "$CORE" in *" $1 "*) return 0 ;; esac; return 1; }

# The template's git history proves stock copies; its HEAD is what ships. A
# checkout nested in another repository works too (paths go through ./).
TPL_GIT=0
if git -C "$SCRIPT_DIR" cat-file -e HEAD:./sync-project.sh 2>/dev/null; then TPL_GIT=1; fi
REF="unknown"
if [ "$TPL_GIT" = 1 ]; then REF="$(git -C "$SCRIPT_DIR" rev-parse --short HEAD)"; fi

# An abort (set -e) prints what was already done; nothing is stamped then.
on_exit() {
  local rc=$? x
  if [ -n "$TPLD" ]; then rm -rf "$TPLD"; fi
  [ "$STARTED" = 1 ] && [ "$FINISHED" = 0 ] && [ "$rc" != 0 ] || return 0
  {
    echo ""
    echo "sync-project: stopped by an error (exit $rc) before it finished — done by then:"
    for x in ${added[@]+"${added[@]}"}; do echo "  + $x"; done
    for x in ${updated[@]+"${updated[@]}"}; do echo "  ~ $x"; done
    for x in ${retired[@]+"${retired[@]}"}; do echo "  - $x"; done
    if [ -n "$STAMPED" ]; then x="The $STAMPED stamp was written already."; else x="No stamp was written."; fi
    echo "  $x Fix the error above, then re-run (the sync is idempotent). Review with: git -C \"$TARGET\" status"
  } >&2
}
trap on_exit EXIT

if [ "$UPDATE_STOCK" = 1 ] && [ "$TPL_GIT" = 0 ]; then
  echo "Error: --update-stock cannot prove stock without git history — run from a git checkout of the template (a clone, not a zip or a git archive)"
  exit 2
fi

# SRC = the files that ship: the template's last commit, exported once.
SRC="$SCRIPT_DIR"
if [ "$TPL_GIT" = 1 ]; then
  TPLD="$(mktemp -d "${TMPDIR:-/tmp}/sync-project.XXXXXX")"
  git -C "$SCRIPT_DIR" archive HEAD:./ | tar -x -C "$TPLD"
  SRC="$TPLD"
  if [ -n "$(git -C "$SCRIPT_DIR" status --porcelain --untracked-files=no -- . 2>/dev/null)" ]; then
    suggest+=("this template checkout has uncommitted changes — the sync shipped its last commit ($REF), never the working tree; commit them first if they should ship")
  fi
fi

# --- Adopt an existing repo (create the skeleton first) -------------------------
if [ ! -d "$TARGET/.ai_context" ]; then
  if [ "$ADOPT" = 1 ]; then
    [ -d "$TARGET" ] || { echo "Error: $TARGET does not exist"; exit 1; }
    STARTED=1
    mkdir -p "$TARGET/.ai_context"
    for f in INDEX.md state.md decisions.md; do
      [ -e "$TARGET/.ai_context/$f" ] || cp "$SRC/.ai_context/$f" "$TARGET/.ai_context/$f"
    done
    for d in journal knowledge private tasks; do
      mkdir -p "$TARGET/.ai_context/$d"
      [ -e "$TARGET/.ai_context/$d/.gitkeep" ] || : > "$TARGET/.ai_context/$d/.gitkeep"
    done
    if [ ! -f "$TARGET/CLAUDE.md" ]; then
      cp "$SRC/templates/CLAUDE.md.code" "$TARGET/CLAUDE.md"
      suggest+=("adopted with the 'code' CLAUDE.md template — for research/analysis projects copy templates/CLAUDE.md.<kind> instead")
    fi
    base="$(basename "$TARGET")"; today="$(date +%F)"
    for f in "$TARGET/CLAUDE.md" "$TARGET/.ai_context/state.md"; do
      [ -f "$f" ] || continue
      sed -i.bak -e "s/{{PROJECT_NAME}}/$base/g" -e "s/{{DATE}}/$today/g" -e "s/<DATE>/$today/g" "$f"
      rm -f "$f.bak"
    done
    added+=(".ai_context/ skeleton (adopted)")
    suggest+=("open Claude in the project and run /setup — it drafts CLAUDE.md/README/state.md from the existing code")
  else
    echo "Error: $TARGET doesn't look like a claude-starter project (.ai_context/ missing)"
    echo "  To onboard an existing repo, re-run with --adopt"
    exit 1
  fi
fi

# --- A v3 task (R15): tasks/CURRENT names a task directory without card.md ---
# that holds v3 files (spec.md, plan.md, brief.md, gatelog). v4 cannot
# continue it. Active = no plan.md yet (v3 writes CURRENT first: mid-intake),
# a plan.md milestone still [in_progress] or [pending] whatever its age, or a
# change git saw within 7 days — a commit or an uncommitted change; never
# mtimes, which a worktree or a fresh clone resets (a target that is no git
# repository has neither).
v3slug="" v3has="" v3why=""
if [ -f "$TARGET/.ai_context/tasks/CURRENT" ]; then v3slug="$(tr -d '[:space:]' < "$TARGET/.ai_context/tasks/CURRENT" || true)"; fi
v3slug="${v3slug#$'\xef\xbb\xbf'}"   # an editor's UTF-8 BOM
case "$v3slug" in */*|*..*) v3slug="" ;; esac
v3d="$TARGET/.ai_context/tasks/$v3slug"
if [ -n "$v3slug" ] && [ -d "$v3d" ] && [ ! -f "$v3d/card.md" ]; then
  for f in spec.md plan.md brief.md gatelog; do
    if [ -f "$v3d/$f" ]; then v3has="$v3has, $f"; fi
  done
  v3has="${v3has#, }"
fi
if [ -n "$v3has" ]; then
  if [ ! -f "$v3d/plan.md" ]; then
    v3why="no plan.md yet: mid-intake"
  elif grep -qE '^##+ .*\[(in_progress|pending)\]' "$v3d/plan.md"; then
    v3why="plan.md has an [in_progress] or [pending] milestone"
  else
    v3ct="$(git -C "$TARGET" log -1 --format=%ct -- ".ai_context/tasks/$v3slug" .ai_context/tasks/CURRENT 2>/dev/null || true)"
    v3wip="$(git -C "$TARGET" status --porcelain -- ".ai_context/tasks/$v3slug" .ai_context/tasks/CURRENT 2>/dev/null || true)"
    if [ -n "$v3wip" ] || { [ -n "$v3ct" ] && [ $(( $(date +%s) - v3ct )) -lt 604800 ]; }; then v3why="changed within 7 days"; fi
  fi
  if [ -n "$v3why" ]; then
    if [ "$UPDATE_STOCK" = 1 ]; then
      echo "Error: $TARGET has an active v3 task '$v3slug' (tasks/CURRENT → $v3has, no card.md; $v3why)."
      echo "  v4 cannot continue a v3 task. Finish it with a v3-final checkout of claude-starter,"
      echo "  or abandon it (delete .ai_context/tasks/CURRENT — the task directory stays), then re-run."
      exit 1
    fi
    suggest+=("active v3 task '$v3slug' ($v3why) — do not run --update-stock until it is finished or abandoned (v4 cannot continue it)")
  else
    V3IDLE=1   # noted after the sync, with how to restore what it replaced
  fi
fi
STARTED=1

# --- How a project file stands against the template -----------------------------
# Never write through a symlink: a link (or a linked directory on the way) may
# point into another project or a shared tree.
safe_dst() { # $1 = rel: 0 when no component of $TARGET/$1 is a symlink
  local p="$1"
  while :; do
    [ ! -L "$TARGET/$p" ] || return 1
    case "$p" in */*) p="${p%/*}" ;; *) return 0 ;; esac
  done
}
add_linked() { case " ${linked[*]-} " in *" $1 "*) ;; *) linked+=("$1") ;; esac; }
# A file is stock ONLY if its content matches some committed version of the
# same file in this template's history (any branch) — i.e. it is provably an
# unmodified stock copy that has merely fallen behind.
matches_history() { # $1 = template path, $2 = file: byte-identical to some version of $1?
  # Every commit that touched $1, its deletion included (show fails there and
  # is skipped). A shallow checkout missing the version: no — the caller
  # falls back to a suggestion, the safe direction.
  local h
  [ "$TPL_GIT" = 1 ] || return 1
  while IFS= read -r h; do
    if git -C "$SCRIPT_DIR" show "$h:./$1" 2>/dev/null | cmp -s - "$2"; then return 0; fi
  done < <(git -C "$SCRIPT_DIR" log --all --format=%H -- "$1")
  return 1
}
HIST=";"
hist_ok() { # matches_history, asked once per file (a file is written only after the answer)
  case "$HIST" in *";$1=1;"*) return 0 ;; *";$1=0;"*) return 1 ;; esac
  if matches_history "$1" "$2"; then HIST="$HIST$1=1;"; return 0; fi
  HIST="$HIST$1=0;"; return 1
}
# A customized copy that still carries every line of the template's version,
# in order (indentation and a trailing comma aside), is that version plus
# local lines: a finished hand merge, nothing left to merge.
contains_tpl() { # $1 = rel, $2 = file
  awk 'function n(s) { sub(/\r$/, "", s); gsub(/^[ \t]+|[ \t]+$/, "", s); sub(/,$/, "", s); return s }
       FNR == NR { t[++nt] = n($0); next }
       i < nt && n($0) == t[i + 1] { i++ }
       END { exit !(nt > 0 && i == nt) }' "$SRC/$1" "$2" 2>/dev/null
}
# ST = absent | current | stock (an older template version) | merged |
#      custom | linked (reached through a symlink, not the template's)
state_of() { # $1 = rel
  local dst="$TARGET/$1"
  if ! safe_dst "$1"; then
    if [ -f "$dst" ] && cmp -s "$dst" "$SRC/$1"; then ST=current; else ST=linked; fi
  elif [ ! -e "$dst" ]; then ST=absent
  elif [ ! -f "$dst" ]; then ST=custom
  elif cmp -s "$dst" "$SRC/$1"; then ST=current
  elif hist_ok "$1" "$dst"; then ST=stock
  elif contains_tpl "$1" "$dst"; then ST=merged
  else ST=custom
  fi
  return 0
}

# --- The core moves as one unit -----------------------------------------------
# --update-stock: a customized (or linked) core file holds ALL of the core
# back — nothing of it added or replaced, nothing retired — and the run ends
# MIGRATION INCOMPLETE (exit 2). Add-only: the core's missing files are added
# only while every present one already is the template's.
CORE_HOLD=0 CORE_N=0 core_bad=() core_old=()
for rel in $CORE; do
  [ -f "$SRC/$rel" ] || continue
  state_of "$rel"
  case "$ST" in
    current|merged) ;;
    absent) CORE_N=$((CORE_N + 1)) ;;
    stock) CORE_N=$((CORE_N + 1)); core_old+=("$rel") ;;
    *) CORE_N=$((CORE_N + 1)); core_bad+=("$rel") ;;
  esac
done
if [ "${#core_bad[@]}" -gt 0 ] || { [ "$UPDATE_STOCK" = 0 ] && [ "${#core_old[@]}" -gt 0 ]; }; then CORE_HOLD=1; fi

copy_if_missing() {
  local rel="$1" dst="$TARGET/$1"
  [ -f "$SRC/$rel" ] || return 0
  [ ! -e "$dst" ] || return 0                                     # present (a link too): stock_update's business
  if [ "$CORE_HOLD" = 1 ] && is_core "$rel"; then return 0; fi   # never half a core
  if ! safe_dst "$rel"; then add_linked "$rel"; return 0; fi
  mkdir -p "$(dirname "$dst")"
  cp "$SRC/$rel" "$dst"
  added+=("$rel"); shipped+=("$rel")
}

# --- Add missing mechanism files -----------------------------------------------
copy_if_missing .claude/settings.json
copy_if_missing .claude/hooks/session-start.sh
copy_if_missing .claude/hooks/post-edit.sh
copy_if_missing .claude/hooks/bash-guard.sh
copy_if_missing .claude/hooks/guard-patterns.sh
copy_if_missing .claude/hooks/spawn-log.sh
copy_if_missing .claude/hooks/lint.sh.example
copy_if_missing .claude/skills/wrap/SKILL.md
copy_if_missing .claude/skills/wrap/reference.md
copy_if_missing .claude/hooks/stop-gate.sh
copy_if_missing .claude/skills/task/SKILL.md
copy_if_missing .claude/skills/task/reference.md
copy_if_missing .claude/skills/task/pair.md
copy_if_missing .claude/skills/setup/SKILL.md
copy_if_missing .claude/skills/setup/verify-template.md
copy_if_missing .claude/skills/number-check/SKILL.md
copy_if_missing .claude/skills/prove/SKILL.md
copy_if_missing .claude/skills/debug/SKILL.md
copy_if_missing .claude/skills/defect/SKILL.md
copy_if_missing .claude/skills/backtest-check/SKILL.md
copy_if_missing .claude/agents/executor.md
copy_if_missing .claude/agents/checker.md
copy_if_missing .ai_context/tasks/.gitkeep
copy_if_missing .secrets/.gitkeep
copy_if_missing scripts/check-state-size.sh
copy_if_missing scripts/check-append-only.sh
copy_if_missing scripts/check-context-bulk.sh
copy_if_missing scripts/harness-report.sh
copy_if_missing scripts/precommit-gitleaks.sh
copy_if_missing scripts/task-pair.sh
copy_if_missing scripts/evidence.sh
copy_if_missing .claude/gitleaks.toml
copy_if_missing .pre-commit-config.yaml
copy_if_missing NOTICE

# --- Update stock mechanism files (opt-in) --------------------------------------
# Replaced ONLY when stock (matches_history); customized files are never
# touched. Exec bits go only to what is added, replaced or provably stock.
stock_update() {
  local rel="$1" dst="$TARGET/$1" note=""
  [ -f "$SRC/$rel" ] || return 0
  state_of "$rel"
  case "$ST" in
    absent|merged) return 0 ;;
    current) shipped+=("$rel"); return 0 ;;
    linked) add_linked "$rel"; return 0 ;;
    stock)
      shipped+=("$rel")
      if [ "$UPDATE_STOCK" = 1 ] && { [ "$CORE_HOLD" = 0 ] || ! is_core "$rel"; }; then
        cp "$SRC/$rel" "$dst"
        updated+=("$rel")
      fi
      return 0 ;;
  esac
  # Customized. tests/ may be the project's own suite: never a word about it.
  case "$rel" in tests/*) return 0 ;; esac
  [ "$UPDATE_STOCK" = 1 ] || return 0
  case "$rel" in
    .claude/settings.json|.claude/hooks/stop-gate.sh|.claude/hooks/session-start.sh|.claude/hooks/spawn-log.sh|.claude/hooks/bash-guard.sh|.claude/hooks/guard-patterns.sh|.claude/skills/task/*|.claude/agents/executor.md|scripts/task-pair.sh|.claude/skills/wrap/reference.md)
      note=" — v4 rewrote this file: port your change onto the v4 copy instead of merging v3 lines into it" ;;
    .claude/gitleaks.toml)
      note=" — keep your rules and add the template's internal-ipv4 [[rules]] block (lane and canary logs are scanned with it); any change to this file needs a lane re-trust (bash scripts/evidence.sh trust <lane>)" ;;
    NOTICE)
      note=" — it carries an older copy of the template's notices: replace that part with the current file's text" ;;
  esac
  suggest+=("$rel differs from every known template version (customized) — merge by hand: diff \"$TARGET/$rel\" \"$SCRIPT_DIR/$rel\"$note")
  return 0
}

stock_update .claude/settings.json
stock_update .claude/hooks/session-start.sh
stock_update .claude/hooks/post-edit.sh
stock_update .claude/hooks/bash-guard.sh
stock_update .claude/hooks/guard-patterns.sh
stock_update .claude/hooks/spawn-log.sh
stock_update .claude/hooks/stop-gate.sh
stock_update .claude/skills/wrap/SKILL.md
stock_update .claude/skills/wrap/reference.md
stock_update .claude/skills/task/SKILL.md
stock_update .claude/skills/task/reference.md
stock_update .claude/skills/task/pair.md
stock_update .claude/skills/setup/SKILL.md
stock_update .claude/skills/setup/verify-template.md
stock_update .claude/skills/number-check/SKILL.md
stock_update .claude/skills/prove/SKILL.md
stock_update .claude/skills/debug/SKILL.md
stock_update .claude/skills/defect/SKILL.md
stock_update .claude/skills/backtest-check/SKILL.md
stock_update .claude/agents/executor.md
stock_update .claude/agents/checker.md
stock_update .ai_context/INDEX.md
stock_update scripts/check-state-size.sh
stock_update scripts/check-append-only.sh
stock_update scripts/check-context-bulk.sh
stock_update scripts/harness-report.sh
stock_update scripts/precommit-gitleaks.sh
stock_update scripts/task-pair.sh
stock_update scripts/evidence.sh
stock_update .claude/gitleaks.toml
stock_update .pre-commit-config.yaml
# tests/ may be the project's own suite, so the template's is never added —
# only a provably stock copy advances (R32).
stock_update tests/run.sh
stock_update tests/fake-herdr.sh
# NOTICE is stock only while it carries the template's marker; a project's
# own NOTICE is never replaced (it gets the append suggestion below).
if grep -qF 'claude-starter third-party notices' "$TARGET/NOTICE" 2>/dev/null; then stock_update NOTICE; fi
# The template suite reads tests/fixtures/ (recorded hook payloads, Codex
# rollouts) and fails, not skips, without them: wherever tests/run.sh is the
# template's own, the missing fixtures come along (R32) — committed ones only.
if [ -f "$TARGET/tests/run.sh" ] && cmp -s "$TARGET/tests/run.sh" "$SRC/tests/run.sh"; then
  while IFS= read -r rel; do copy_if_missing "$rel"; done < <(cd "$SRC" && find tests/fixtures -type f 2>/dev/null | LC_ALL=C sort)
fi

# --- Retire files the template no longer ships (v4) ------------------------------
# Only --update-stock deletes, only a provably stock copy, and only while the
# core moved; the deletion shows in the project's git status for the human
# to commit (no git rm here). A task directory's v3 files (plan.md, gatelog,
# ...) are history, not stock.
retire() {
  local rel="$1" f="$TARGET/$1"
  [ -e "$f" ] || [ -L "$f" ] || return 0
  if ! safe_dst "$rel"; then add_linked "$rel"; return 0; fi
  [ -f "$f" ] || return 0
  if [ "$rel" = scripts/task-statusline.sh ] && grep -qsF 'task-statusline' "$TARGET/.claude/settings.json" "$TARGET/.claude/settings.local.json"; then
    suggest+=("scripts/task-statusline.sh is retired in v4, but a statusLine in .claude/settings*.json still runs it — kept until that statusLine runs: bash scripts/evidence.sh status --line (then re-run)")
    return 0
  fi
  if [ "$TPL_GIT" != 1 ]; then
    retire_pending+=("$rel")
  elif ! hist_ok "$rel" "$f"; then
    suggest+=("$rel is retired in v4 but differs from every template version (customized) — kept; nothing reads it any more. Review, then: git -C \"$TARGET\" rm \"$rel\"")
  elif [ "$UPDATE_STOCK" = 1 ] && [ "$CORE_HOLD" = 0 ]; then
    rm -f "$f"
    retired+=("$rel")
  else
    retire_pending+=("$rel")
  fi
  return 0
}
retire .claude/agents/scout.md
retire .claude/agents/planner.md
retire .claude/agents/plan-critic.md
retire .claude/agents/verifier.md
retire .claude/agents/reframer.md
retire .claude/agents/final-verifier.md
retire scripts/task-status.sh
retire scripts/task-statusline.sh
retire scripts/task-profile.sh
if [ "${#retire_pending[@]}" -gt 0 ]; then
  rp="$(printf '%s, ' ${retire_pending[@]+"${retire_pending[@]}"})"
  if [ "$TPL_GIT" != 1 ]; then
    suggest+=("retired in v4, still present (${#retire_pending[@]}): ${rp%, } — this template checkout has no git history to tell stock copies from customized ones; review them, then delete them by hand")
  elif [ "$UPDATE_STOCK" = 1 ]; then
    suggest+=("retired in v4, still present (${#retire_pending[@]}): ${rp%, } — stock copies, kept while the v4 core is held back (MIGRATION INCOMPLETE below); the re-run deletes them")
  else
    suggest+=("retired in v4, still present (${#retire_pending[@]}): ${rp%, } — re-run with --update-stock to delete the stock copies")
  fi
fi

# Exec bits only on files this template ships — never on project-owned
# scripts (the v3 blanket chmod flipped modes on project files).
for rel in ${shipped[@]+"${shipped[@]}"}; do
  case "$rel" in *.sh) if [ -f "$TARGET/$rel" ] && safe_dst "$rel"; then chmod +x "$TARGET/$rel" 2>/dev/null || true; fi ;; esac
done

# Any sync that changed mechanisms leaves a provenance trail. synced-to
# names the template ref only when the whole core now is that ref's (each
# core file the template's, or carrying all of it); otherwise partial-sync
# names no version, so later rows keep the vintage of the last real stamp
# (harness-report.sh reads the last spawned-by:/synced-to: line).
n_replaced=${#updated[@]}
if [ "$(( ${#updated[@]} + ${#added[@]} + ${#retired[@]} ))" -gt 0 ]; then
  if ! safe_dst .claude/.starter-version; then
    add_linked .claude/.starter-version
  elif [ "$CORE_HOLD" = 0 ]; then
    printf 'synced-to: claude-starter@%s on %s\n' "$REF" "$(date +%F)" >> "$TARGET/.claude/.starter-version" 2>/dev/null && STAMPED=synced-to
    updated+=(".claude/.starter-version (synced-to stamp)")
  else
    printf 'partial-sync: %s on %s (%s core files kept back)\n' "$REF" "$(date +%F)" "$CORE_N" \
      >> "$TARGET/.claude/.starter-version" 2>/dev/null && STAMPED=partial-sync
    updated+=(".claude/.starter-version (partial-sync stamp)")
  fi
fi

# --- .gitignore additions --------------------------------------------------------
gi_ok=0
if [ -f "$TARGET/.gitignore" ]; then
  if safe_dst .gitignore; then gi_ok=1; else add_linked .gitignore; fi
fi
if [ "$gi_ok" = 1 ] && ! grep -q 'settings\.local\.json' "$TARGET/.gitignore"; then
  printf '\n# Local-only Claude Code settings (machine-specific)\n.claude/settings.local.json\n' \
    >> "$TARGET/.gitignore"
  added+=(".gitignore (+ .claude/settings.local.json)"); GI_CHANGED=1
fi
if [ "$gi_ok" = 1 ] && ! grep -q '^\.secrets/\*' "$TARGET/.gitignore"; then
  printf '\n# Runtime-only credentials (claude-starter v3.8): code reads them at\n# execution time; Claude Read-denied; git sees only the placeholder.\n.secrets/*\n**/.secrets/*\n!.secrets/.gitkeep\n' \
    >> "$TARGET/.gitignore"
  added+=(".gitignore (+ .secrets/)"); GI_CHANGED=1
fi
if [ "$gi_ok" = 1 ] && ! grep -qxF '.claude/evidence/' "$TARGET/.gitignore"; then
  printf '\n# Evidence ledger (claude-starter v4): per-machine lane, checker and Codex\n# records, run logs (mode 600), pid locks and pair-codex run state — written\n# only by scripts/evidence.sh and scripts/task-pair.sh. Never memory, never\n# committed; .claude/done-lanes.trust and tasks/*/donelog are the tracked side.\n.claude/evidence/\n' \
    >> "$TARGET/.gitignore"
  added+=(".gitignore (+ .claude/evidence/)"); GI_CHANGED=1
fi
# v4 voids a lane run that leaves an untracked, unignored file in the lane's
# paths: the template's test and build cache block comes along, with only
# the patterns the project lacks.
if [ "$gi_ok" = 1 ]; then
  cb_head="" cb_miss="" cb_n=0
  while IFS= read -r l; do
    case "$l" in
      '#'*) cb_head="$cb_head$l"$'\n' ;;
      '') ;;
      *) if ! grep -qxF -- "$l" "$TARGET/.gitignore"; then cb_miss="$cb_miss$l"$'\n'; cb_n=$((cb_n + 1)); fi ;;
    esac
  done < <(sed -n '/^# Test and build caches/,/^$/p' "$SRC/.gitignore")
  if [ -n "$cb_miss" ]; then
    printf '\n%s%s' "$cb_head" "$cb_miss" >> "$TARGET/.gitignore"
    added+=(".gitignore (+ test and build caches: $cb_n patterns)"); GI_CHANGED=1
  fi
fi

# v3 task-runtime ignores (R32): the PASS cache, the STATUS view, .last-verify
# and pair/.fp-* name files v4 never writes (pair run state moved under
# .claude/evidence/). --update-stock drops a block only while it is verbatim
# template or sync text and none of those files exists — a dropped ignore
# would put a leftover runtime file into git status. Edited blocks stay, and
# so does every block while the core is held back (the v3 gate still runs).
if [ "$UPDATE_STOCK" = 1 ] && [ "$CORE_HOLD" = 0 ] && [ "$gi_ok" = 1 ]; then
  gi="$(cat "$TARGET/.gitignore"; printf x)"; gi="${gi%x}"; gi4="$gi"
  for b in \
    $'# Stop-gate PASS-cache — runtime state; MUST stay ignored (gitignoring it\n# keeps it out of its own change-fingerprint).\n.ai_context/tasks/*/.gate-cache\n\n' \
    $'# Task live view + last verify output — regenerated by hooks/scripts; a\n# VIEW, never memory. Ignored for the same fingerprint reason as the cache.\n.ai_context/tasks/*/STATUS.md\n.ai_context/tasks/*/.last-verify\n.ai_context/tasks/*/pair/.fp-*\n\n' \
    $'# Task live view + last verify output — regenerated by hooks/scripts; a\n# VIEW, never memory. Ignored for the same fingerprint reason as the cache.\n.ai_context/tasks/*/STATUS.md\n.ai_context/tasks/*/.last-verify\n\n' \
    $'\n# Task live view + last verify output (claude-starter v3.12) — regenerated\n# by hooks/scripts; a VIEW, never memory. Ignored for the same fingerprint\n# reason as .gate-cache.\n.ai_context/tasks/*/STATUS.md\n.ai_context/tasks/*/.last-verify\n'; do
    gi4="${gi4/"$b"/}"
  done
  # The block a v3 sync appended for pair fingerprints named a decision
  # number: matched with the digits as a pattern.
  fp1=$'\n# pair-codex in-flight tree fingerprints (claude-starter, ADR-'
  fp2=$') — written\n# by scripts/task-pair.sh per run and removed on settle; never memory.\n.ai_context/tasks/*/pair/.fp-*\n'
  gi4="${gi4/"$fp1"[0-9][0-9][0-9]"$fp2"/}"
  if [ "$gi4" != "$gi" ]; then
    v3rt=""
    for f in "$TARGET"/.ai_context/tasks/*/STATUS.md "$TARGET"/.ai_context/tasks/*/.last-verify \
             "$TARGET"/.ai_context/tasks/*/.gate-cache "$TARGET"/.ai_context/tasks/*/pair/.fp-*; do
      if [ -e "$f" ]; then v3rt=1; fi
    done
    if [ -n "$v3rt" ]; then
      suggest+=("v3 task-runtime files exist (tasks/*/STATUS.md, .last-verify, .gate-cache, pair/.fp-*) — views, never memory; delete them, then re-run to drop their .gitignore lines")
    else
      printf '%s' "$gi4" > "$TARGET/.gitignore"
      retired+=(".gitignore: v3 task-runtime block"); GI_CHANGED=1
    fi
  fi
fi

# --- Report-only checks -----------------------------------------------------------
if [ "$CORE_HOLD" = 1 ] && [ "$UPDATE_STOCK" = 0 ]; then
  x="$(printf '%s, ' ${core_old[@]+"${core_old[@]}"} ${core_bad[@]+"${core_bad[@]}"})"
  suggest+=("v4 /task core not installed: ${x%, } predate this template — the core (settings.json, the stop/session/spawn/bash hooks, guard-patterns.sh, evidence.sh, task-pair.sh, the task skill, executor, checker) moves as one unit, so its missing files were not added either; run with --update-stock (customized files among them need a hand merge first)")
fi

cur_schema="$(grep -m1 -Eo 'schema: v[0-9]+' "$SRC/.ai_context/INDEX.md" 2>/dev/null || echo 'unknown')"
tgt_schema="$(grep -m1 -Eo 'schema: v[0-9]+' "$TARGET/.ai_context/INDEX.md" 2>/dev/null || echo 'none')"
if [ "$tgt_schema" != "$cur_schema" ] && [ "$cur_schema" = "schema: v4" ] && [ "$tgt_schema" = "schema: v3" ]; then
  suggest+=("INDEX.md is schema v3 — a stock copy is replaced by --update-stock; a customized one needs a hand merge: replace the 'Active /task' row and the tasks/<slug>/ rows (spec.md, plan.md, brief.md, lessons.md, gatelog, spawnlog, pair/*, STATUS.md) with the template's card.md / notes.md / donelog / pair/* rows, add the knowledge/lessons/, scoreboard-v4/defects and .claude/evidence/ rows, set '<!-- schema: v4 -->', and keep it ≤4 KB:
      diff \"$TARGET/.ai_context/INDEX.md\" \"$SCRIPT_DIR/.ai_context/INDEX.md\"")
elif [ "$tgt_schema" != "$cur_schema" ]; then
  suggest+=("INDEX.md schema is '$tgt_schema', template is '$cur_schema' — review and merge by hand:
      diff \"$TARGET/.ai_context/INDEX.md\" \"$SCRIPT_DIR/.ai_context/INDEX.md\"")
fi

for f in start_project.sh bootstrap-machine.sh sync-project.sh MIGRATION.md \
         README.zh-TW.md TUTORIAL.md TUTORIAL.zh-TW.md .claudeignore \
         CLAUDE.md.template; do
  if [ -e "$TARGET/$f" ]; then
    suggest+=("template leftover: $f — consider: git -C \"$TARGET\" rm -f $f")
  fi
done

# NOTICE carries the MIT notices for the third-party text adapted under
# .claude/; a project that already had its own NOTICE got no copy.
if [ -f "$TARGET/NOTICE" ] && ! grep -qF 'claude-starter third-party notices' "$TARGET/NOTICE"; then
  suggest+=("NOTICE exists but lacks claude-starter's third-party notices — MIT requires them next to the adapted .claude/ files; append them: cat \"$SCRIPT_DIR/NOTICE\" >> \"$TARGET/NOTICE\"")
fi

if [ -f "$TARGET/CLAUDE.md" ] && ! grep -qi 'definition of done' "$TARGET/CLAUDE.md"; then
  suggest+=("CLAUDE.md has no 'Definition of done' section — copy one from \"$SCRIPT_DIR/templates/CLAUDE.md.<kind>\"")
fi

# /number-check ships as a skill; the DoD line that makes it a rule lives in
# CLAUDE.md, which sync never edits. Suggest it once — on the sync that
# installs the skill — so projects that report no numbers are not nagged.
if printf '%s\n' ${added[@]+"${added[@]}"} | grep -qx '.claude/skills/number-check/SKILL.md' \
   && [ -f "$TARGET/CLAUDE.md" ] && ! grep -q 'number-check' "$TARGET/CLAUDE.md"; then
  suggest+=("new skill /number-check installed — if this project reports measured numbers (backtests, benchmarks, metrics), add to CLAUDE.md's Definition of done:
      - Every reported number passed \`/number-check\`: work count (trades / rows), quiet-failure count (errors / NaN), run or window spread, and the limiter stated with it.")
fi

# v4 /task proves slices with declared lanes — said on every sync until the
# lanes exist (nothing in /task runs without them).
if [ -f "$TARGET/scripts/evidence.sh" ] && [ ! -f "$TARGET/.claude/done-lanes" ]; then
  suggest+=("v4 /task needs declared lanes — open Claude in the project and run /setup §4–§5 (lanes) only: it writes .claude/skills/verify/SKILL.md from .claude/skills/setup/verify-template.md, declares .claude/done-lanes (≤3 lanes) and runs: bash scripts/evidence.sh trust <lane> (a project that never runs /task can skip this)")
fi
if [ -f "$TARGET/CLAUDE.md" ] && grep -qE 'Task profile:|task-profile\.sh' "$TARGET/CLAUDE.md"; then
  suggest+=("CLAUDE.md still names a v3 task profile ('Task profile:' / task-profile.sh, commented out or not) — profiles are gone in v4; replace the '## Long-horizon tasks' body with the one in \"$SCRIPT_DIR/templates/CLAUDE.md.<kind>\" (code, research or analysis)")
fi
# X1: Codex reads AGENTS.override.md, then AGENTS.md, before CLAUDE.md.
if [ -f "$TARGET/.claude/done-lanes" ] && grep -qE '^@pair[[:space:]]+codex' "$TARGET/.claude/done-lanes"; then
  for f in AGENTS.md AGENTS.override.md; do
    if [ -f "$TARGET/$f" ] && ! cmp -s "$TARGET/$f" "$TARGET/CLAUDE.md"; then
      suggest+=("$f differs from CLAUDE.md — Codex reads $f first, so scripts/task-pair.sh ensure refuses to start the judge (X1); delete $f or make it a copy of CLAUDE.md")
    fi
  done
fi

if [ -f "$TARGET/.pre-commit-config.yaml" ] && [ ! -f "$TARGET/.git/hooks/pre-commit" ]; then
  suggest+=("pre-commit config present but not installed — run: (cd \"$TARGET\" && pre-commit install)")
fi
# v4's files regex still lists gatelog|spawnlog (frozen v3 evidence), so
# donelog is what tells the v4 hook apart.
if [ -f "$TARGET/.pre-commit-config.yaml" ] && ! grep -q 'donelog' "$TARGET/.pre-commit-config.yaml"; then
  suggest+=(".pre-commit-config.yaml's append-only hook does not cover tasks/*/donelog — switch its files regex to the template's (adds donelog, scoreboard-v4.csv, defects.csv and .claude/done-lanes.trust; keeps gatelog|spawnlog), then re-run pre-commit install")
fi
# pre-commit calls a hook only for the files it lists, and it never lists a
# deleted one: without always_run a commit that deletes or renames an
# append-only file passes unchecked.
if [ -f "$TARGET/.pre-commit-config.yaml" ] && grep -q 'check-append-only\.sh' "$TARGET/.pre-commit-config.yaml" \
   && ! sed -n '/id: ai-context-append-only/,/pass_filenames/p' "$TARGET/.pre-commit-config.yaml" | grep -q 'always_run: true' \
   && sed -n '/id: ai-context-append-only/,/pass_filenames/p' "$SRC/.pre-commit-config.yaml" | grep -q 'always_run: true'; then
  suggest+=(".pre-commit-config.yaml's append-only hook lacks 'always_run: true' — without it a commit that only deletes or renames decisions.md, a donelog or the trust file never reaches the check; add it to that hook (the script picks its files itself)")
fi

# v3 harness: these two files predate v3 in older projects, and sync never
# overwrites — so wiring changes are surfaced as suggestions instead.
if [ -f "$TARGET/.claude/settings.json" ] && ! grep -q 'stop-gate\.sh' "$TARGET/.claude/settings.json"; then
  suggest+=("settings.json has no Stop-gate wiring — merge the \"Stop\" hook block from the template's .claude/settings.json")
fi

# v3.7: bash-guard wiring + gatelog write-deny live in settings.json, which
# customized projects must merge by hand.
if [ -f "$TARGET/.claude/settings.json" ] && ! grep -q 'bash-guard\.sh' "$TARGET/.claude/settings.json"; then
  suggest+=("settings.json has no bash-guard wiring (v3.7) — merge the \"PreToolUse\" hook block from the template's .claude/settings.json")
fi
if [ -f "$TARGET/.claude/settings.json" ] && ! grep -q 'gatelog' "$TARGET/.claude/settings.json"; then
  suggest+=("settings.json does not deny Edit/Write on tasks/*/gatelog (v3.7) — merge the deny entries from the template's .claude/settings.json")
fi

# v3.9 spawnlog write-deny: kept in v4 — it protects frozen v3 evidence.
if [ -f "$TARGET/.claude/settings.json" ] && ! grep -q 'spawnlog' "$TARGET/.claude/settings.json"; then
  suggest+=("settings.json does not deny Edit/Write on tasks/*/spawnlog (v3.9) — merge the deny entries from the template's .claude/settings.json")
fi

# v4: SubagentStart/Stop write SPAWN/RETURN rows and the checker record; the
# evidence ledger is Edit-denied; trust/approve/check ask even under bypass.
# The spawn-log calls and the denies are read from the template, so these
# checks never drift from it.
if [ -f "$TARGET/.claude/settings.json" ]; then
  if ! grep -q 'SubagentStop' "$TARGET/.claude/settings.json"; then
    suggest+=("settings.json has no SubagentStop wiring (v4) — replace its \"SubagentStart\" block with the template's \"SubagentStart\" + \"SubagentStop\" blocks (matchers executor, checker → spawn-log.sh); without them no checker record is written and evidence.sh done refuses every slice")
  else
    miss=""
    while IFS= read -r e; do
      grep -qF -- "$e" "$TARGET/.claude/settings.json" || miss="$miss, ${e#*\" }"
    done < <(grep -oE 'spawn-log\.sh\\" [a-z]+ [a-z]+' "$SRC/.claude/settings.json")
    [ -z "$miss" ] || suggest+=("settings.json's SubagentStart/SubagentStop blocks lack the v4 spawn-log.sh calls: ${miss#, } — copy the template's two blocks (matchers executor, checker); without them no checker record is written and evidence.sh done refuses every slice")
  fi
  miss=""
  while IFS= read -r e; do
    case "$e" in *gatelog*|*spawnlog*|*/pair/**|*.codex/sessions*) continue ;; esac   # suggested on their own
    grep -qF -- "$e" "$TARGET/.claude/settings.json" || miss="$miss, $e"
  done < <(sed -n '/"deny": \[/,/\]/p' "$SRC/.claude/settings.json" | grep -oE '"Edit\([^"]*\)"')
  [ -z "$miss" ] || suggest+=("settings.json lacks the v4 evidence denies — add to permissions.deny: ${miss#, } (keep the gatelog/spawnlog denies: they protect v3 evidence)")
fi
if [ -f "$TARGET/.claude/settings.json" ] && ! grep -qF 'evidence.sh trust' "$TARGET/.claude/settings.json"; then
  suggest+=("settings.json lacks the v4 evidence.sh rules — add to permissions.ask: \"Bash(bash scripts/evidence.sh trust:*)\", \"Bash(bash scripts/evidence.sh approve:*)\", \"Bash(bash scripts/evidence.sh check:*)\" (declarative asks are the only ones that survive bypassPermissions), and to permissions.allow the same form for run, status, show, start, done, close and lint (unattended slices in the default mode)")
fi
if [ -f "$TARGET/.claude/settings.json" ] && grep -qE 'tasks/\*\*/ack-|scout\|planner|"matcher": "verifier"' "$TARGET/.claude/settings.json"; then
  suggest+=("settings.json still carries v3 task wiring — remove the ack-* deny entry and the \"verifier\" and \"scout|planner|plan-critic|final-verifier|reframer\" SubagentStart matchers, and lower the Stop hook timeout to 30 (keep the gatelog/spawnlog denies)")
fi
# The pair review (7aca9b0): the judge's mailbox and Codex's own session logs
# are evidence; and the hooks review: an Edit of a script or setting the
# evidence chain trusts asks first. The asks are read from the template, so
# this list never drifts from it.
if [ -f "$TARGET/.claude/settings.json" ]; then
  miss=""
  for e in 'Edit(./.ai_context/tasks/**/pair/**)' 'Edit(~/.codex/sessions/**)'; do
    grep -qF "\"$e\"" "$TARGET/.claude/settings.json" || miss="$miss, \"$e\""
  done
  [ -z "$miss" ] || suggest+=("settings.json lacks the v4 pair-codex denies — add to permissions.deny: ${miss#, } (judge results and Codex session logs are written only by task-pair.sh and Codex)")
  miss=""
  while IFS= read -r e; do
    grep -qF -- "$e" "$TARGET/.claude/settings.json" || miss="$miss, $e"
  done < <(sed -n '/"ask": \[/,/\]/p' "$SRC/.claude/settings.json" | grep -oE '"Edit\([^"]*\)"')
  [ -z "$miss" ] || suggest+=("settings.json lacks the v4 Edit asks on the scripts and settings the evidence chain trusts — add to permissions.ask: ${miss#, }")
fi

if [ -f "$TARGET/.claude/hooks/session-start.sh" ] && ! grep -q 'card\.md' "$TARGET/.claude/hooks/session-start.sh"; then
  suggest+=("session-start.sh predates the v4 /task harness — diff against the template to add task-card injection (v4)")
fi

# v3 pair-codex kept its judge record and in-flight fingerprints in the
# tracked pair/ mailbox; v4 keeps them in .claude/evidence/pair/<slug>/ and
# names the judge judge-<repo id>-<slug>. Leftovers are reported, never deleted.
pl=""
for f in "$TARGET"/.ai_context/tasks/*/pair/judge "$TARGET"/.ai_context/tasks/*/pair/.fp-*; do
  if [ -f "$f" ]; then pl="$pl ${f#"$TARGET"/}"; fi
done
if [ -n "$pl" ]; then
  suggest+=("v3 pair-codex state left in tasks/*/pair/:$pl — v4 reads none of it (its judge record and fingerprints live in .claude/evidence/pair/<slug>/, gitignored); once no v3 pair run is in flight, delete it by hand (git -C \"$TARGET\" rm the tracked ones)")
fi
case "$pl" in
  */pair/judge*) suggest+=("v4 starts a new Codex judge pane named judge-<repo id>-<slug>; an existing herdr pane named judge-<slug> is not reused — close it in herdr once the first v4 'task-pair.sh ensure' has opened the new one") ;;
esac

# An idle v3 task can still be finished on v3-final — with the v3 files back.
if [ "$V3IDLE" = 1 ]; then
  r=""
  for x in ${updated[@]+"${updated[@]}"} ${retired[@]+"${retired[@]}"}; do
    case "$x" in *' ('*|*:*) continue ;; esac   # the stamp line, the .gitignore block
    r="$r $x"
  done
  [ "$GI_CHANGED" = 0 ] || r="$r .gitignore"
  m="tasks/CURRENT names v3 task '$v3slug' ($v3has, no card.md) — v4 ignores it; finish it on v3-final or delete .ai_context/tasks/CURRENT (the directory stays as history)"
  if [ -n "$r" ] && git -C "$TARGET" rev-parse --git-dir >/dev/null 2>&1; then
    m="$m. To finish it on v3-final, first restore the v3 files this sync replaced or deleted: git -C \"$TARGET\" checkout HEAD --$r (once the sync is committed: the commit before it instead of HEAD)"
  elif [ -n "$r" ]; then
    m="$m. To finish it on v3-final, first restore the v3 files this sync replaced or deleted from your backup:$r"
  fi
  suggest+=("$m")
fi

if [ "${#linked[@]}" -gt 0 ]; then
  x="$(printf '%s, ' ${linked[@]+"${linked[@]}"})"
  suggest+=("reached through a symlink, left alone (${#linked[@]}): ${x%, } — sync never writes through a link (it may point into another project or a shared tree); update each where it points, by hand: diff it against \"$SCRIPT_DIR/<path>\"")
fi

# --- Summary ------------------------------------------------------------------------
FINISHED=1
echo ""
echo "sync-project: $TARGET"
echo ""
if [ "${#added[@]}" -gt 0 ]; then
  echo "Added (${#added[@]}):"
  for a in ${added[@]+"${added[@]}"}; do echo "  + $a"; done
else
  echo "Added: nothing — all mechanism files already present."
fi
echo ""
if [ "${#updated[@]}" -gt 0 ]; then
  echo "Updated stock files (${#updated[@]}):"
  for u in ${updated[@]+"${updated[@]}"}; do echo "  ~ $u"; done
  echo ""
fi
if [ "${#retired[@]}" -gt 0 ]; then
  echo "Retired — stock copies of files v4 removed, deleted (${#retired[@]}):"
  for r in ${retired[@]+"${retired[@]}"}; do echo "  - $r"; done
  echo ""
fi
if [ "${#suggest[@]}" -gt 0 ]; then
  echo "Suggestions (apply by hand — nothing was changed):"
  for s in ${suggest[@]+"${suggest[@]}"}; do echo "  * $s"; done
else
  echo "Suggestions: none."
fi
echo ""
if [ "$n_replaced" -gt 0 ] || [ "${#retired[@]}" -gt 0 ]; then
  echo "Stock copies were replaced or deleted as listed above; customized files were not touched. Review with: git -C \"$TARGET\" status"
else
  echo "Nothing was overwritten or deleted. Review with: git -C \"$TARGET\" status"
fi
if [ "$UPDATE_STOCK" = 1 ] && [ "${#core_bad[@]}" -gt 0 ]; then
  x="$(printf '%s, ' ${core_bad[@]+"${core_bad[@]}"})"
  echo ""
  echo "MIGRATION INCOMPLETE — v4 /task is not safe until: ${x%, } are merged by hand (diff against the template, then re-run)"
  echo "  The v4 core moves as one unit: none of it was added or replaced and nothing was retired; the stamp says partial-sync."
  exit 2
fi
