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
#   - appends known-safe .gitignore lines if absent
#   - everything else is REPORTED as a suggestion for you to apply by hand
#
# Usage:
#   ./sync-project.sh <path-to-project>

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
TPL_GIT=0
git -C "$SCRIPT_DIR" rev-parse --git-dir >/dev/null 2>&1 && TPL_GIT=1

# --- Adopt an existing repo (create the skeleton first) -------------------------
if [ ! -d "$TARGET/.ai_context" ]; then
  if [ "$ADOPT" = 1 ]; then
    [ -d "$TARGET" ] || { echo "Error: $TARGET does not exist"; exit 1; }
    mkdir -p "$TARGET/.ai_context"
    for f in INDEX.md state.md decisions.md; do
      [ -e "$TARGET/.ai_context/$f" ] || cp "$SCRIPT_DIR/.ai_context/$f" "$TARGET/.ai_context/$f"
    done
    for d in journal knowledge private tasks; do
      mkdir -p "$TARGET/.ai_context/$d"
      [ -e "$TARGET/.ai_context/$d/.gitkeep" ] || : > "$TARGET/.ai_context/$d/.gitkeep"
    done
    if [ ! -f "$TARGET/CLAUDE.md" ]; then
      cp "$SCRIPT_DIR/templates/CLAUDE.md.code" "$TARGET/CLAUDE.md"
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

# --- A v3 task (R15): tasks/CURRENT names a plan.md task without card.md -------
# v4 cannot continue it. "Active" = a commit or an uncommitted change under the
# task within 7 days — never mtimes, which a worktree or a fresh clone resets;
# a target that is no git repository has neither, so its task counts as idle.
v3slug=""
if [ -f "$TARGET/.ai_context/tasks/CURRENT" ]; then v3slug="$(tr -d '[:space:]' < "$TARGET/.ai_context/tasks/CURRENT" || true)"; fi
case "$v3slug" in */*|*..*) v3slug="" ;; esac
if [ -n "$v3slug" ] && [ -f "$TARGET/.ai_context/tasks/$v3slug/plan.md" ] && [ ! -f "$TARGET/.ai_context/tasks/$v3slug/card.md" ]; then
  v3ct="$(git -C "$TARGET" log -1 --format=%ct -- ".ai_context/tasks/$v3slug" .ai_context/tasks/CURRENT 2>/dev/null || true)"
  v3wip="$(git -C "$TARGET" status --porcelain -- ".ai_context/tasks/$v3slug" .ai_context/tasks/CURRENT 2>/dev/null || true)"
  if [ -n "$v3wip" ] || { [ -n "$v3ct" ] && [ $(( $(date +%s) - v3ct )) -lt 604800 ]; }; then
    if [ "$UPDATE_STOCK" = 1 ]; then
      echo "Error: $TARGET has an active v3 task '$v3slug' (tasks/CURRENT → plan.md, changed within 7 days)."
      echo "  v4 cannot continue a v3 task. Finish it with a v3-final checkout of claude-starter,"
      echo "  or abandon it (delete .ai_context/tasks/CURRENT — the task directory stays), then re-run."
      exit 1
    fi
    suggest+=("active v3 task '$v3slug' — do not run --update-stock until it is finished or abandoned (v4 cannot continue it)")
  else
    suggest+=("tasks/CURRENT names v3 task '$v3slug' (plan.md, no card.md) — v4 ignores it; finish it on v3-final or delete .ai_context/tasks/CURRENT (the directory stays as history)")
  fi
fi

copy_if_missing() {
  local rel="$1"
  shipped+=("$rel")
  local src="$SCRIPT_DIR/$rel"
  local dst="$TARGET/$rel"
  [ -f "$src" ] || return 0
  [ -e "$dst" ] && return 0
  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst"
  added+=("$rel")
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
# A file is replaced ONLY if its content matches some historical version of
# the same file in this template's git history — i.e. it is provably an
# unmodified stock copy that has merely fallen behind. Customized files are
# never touched.
matches_history() { # $1 = template path, $2 = file: byte-identical to some version of $1?
  # Every commit that touched $1, its deletion included (show fails there and
  # is skipped). No git checkout, or a shallow one missing the version: no —
  # the caller falls back to a suggestion, the safe direction.
  local h
  [ "$TPL_GIT" = 1 ] || return 1
  while IFS= read -r h; do
    if git -C "$SCRIPT_DIR" show "$h:$1" 2>/dev/null | cmp -s - "$2"; then return 0; fi
  done < <(git -C "$SCRIPT_DIR" log --format=%H -- "$1")
  return 1
}
stock_update() {
  local rel="$1" src="$SCRIPT_DIR/$1" dst="$TARGET/$1" note=""
  shipped+=("$rel")
  [ "$UPDATE_STOCK" = 1 ] || return 0
  [ -f "$src" ] && [ -f "$dst" ] || return 0
  cmp -s "$dst" "$src" && return 0
  [ "$TPL_GIT" = 1 ] || return 0
  if matches_history "$rel" "$dst"; then
    cp "$src" "$dst"
    updated+=("$rel")
    return 0
  fi
  case "$rel" in
    .claude/hooks/stop-gate.sh|.claude/hooks/session-start.sh|.claude/hooks/spawn-log.sh|.claude/skills/task/*|.claude/agents/executor.md|scripts/task-pair.sh|.claude/skills/wrap/reference.md)
      note=" — v4 rewrote this file: port your change onto the v4 copy instead of merging v3 lines into it" ;;
    .claude/gitleaks.toml)
      note=" — keep your rules and add the template's internal-ipv4 [[rules]] block (lane and canary logs are scanned with it); any change to this file needs a lane re-trust (bash scripts/evidence.sh trust <lane>)" ;;
  esac
  suggest+=("$rel differs from every known template version (customized) — merge by hand: diff \"$TARGET/$rel\" \"$SCRIPT_DIR/$rel\"$note")
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
# template's own, the missing fixtures come along (R32).
if [ -f "$TARGET/tests/run.sh" ] && cmp -s "$TARGET/tests/run.sh" "$SCRIPT_DIR/tests/run.sh"; then
  while IFS= read -r rel; do copy_if_missing "$rel"; done < <(cd "$SCRIPT_DIR" && find tests/fixtures -type f 2>/dev/null | LC_ALL=C sort)
fi

# --- Retire files the template no longer ships (v4) ------------------------------
# Only --update-stock deletes, and only a provably stock copy; the deletion
# shows in the project's git status for the human to commit (no git rm here).
# A task directory's v3 files (plan.md, gatelog, ...) are history, not stock.
retire() {
  local rel="$1"
  [ -f "$TARGET/$rel" ] || return 0
  if [ "$UPDATE_STOCK" != 1 ] || [ "$TPL_GIT" != 1 ]; then
    retire_pending+=("$rel")
  elif matches_history "$rel" "$TARGET/$rel"; then
    rm -f "$TARGET/$rel"
    retired+=("$rel")
  else
    suggest+=("$rel is retired in v4 but differs from every template version (customized) — kept; nothing reads it any more. Review, then: git -C \"$TARGET\" rm \"$rel\"")
  fi
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
  rp="$(printf '%s, ' "${retire_pending[@]}")"
  if [ "$UPDATE_STOCK" = 1 ]; then
    suggest+=("retired in v4, still present (${#retire_pending[@]}): ${rp%, } — this template checkout has no git history to prove them stock copies; review them, then delete them by hand")
  else
    suggest+=("retired in v4, still present (${#retire_pending[@]}): ${rp%, } — re-run with --update-stock to delete the stock copies; customized copies are listed separately")
  fi
fi

# Exec bits only on files this template ships — never on project-owned
# scripts (the v3 blanket chmod flipped modes on project files).
for rel in ${shipped[@]+"${shipped[@]}"}; do
  case "$rel" in *.sh) if [ -f "$TARGET/$rel" ]; then chmod +x "$TARGET/$rel" 2>/dev/null || true; fi ;; esac
done

# Any sync that changed mechanisms leaves a provenance trail: the stamp
# records which template vintage the mechanisms were last synced to
# (stale-spawner debugging; per-version fleet attribution). v3.9 stamped
# only under --update-stock, so a default sync that ADDED new-version
# files kept the old vintage and mis-attributed later task rows (F15).
n_replaced=${#updated[@]}
if [ "$(( ${#updated[@]} + ${#added[@]} + ${#retired[@]} ))" -gt 0 ]; then
  ref="$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  printf 'synced-to: claude-starter@%s on %s\n' "$ref" "$(date +%F)" \
    >> "$TARGET/.claude/.starter-version" 2>/dev/null || true
  updated+=(".claude/.starter-version (synced-to stamp)")
fi

# --- .gitignore additions --------------------------------------------------------
if [ -f "$TARGET/.gitignore" ] && ! grep -q 'settings\.local\.json' "$TARGET/.gitignore"; then
  printf '\n# Local-only Claude Code settings (machine-specific)\n.claude/settings.local.json\n' \
    >> "$TARGET/.gitignore"
  added+=(".gitignore (+ .claude/settings.local.json)")
fi
if [ -f "$TARGET/.gitignore" ] && ! grep -q '^\.secrets/\*' "$TARGET/.gitignore"; then
  printf '\n# Runtime-only credentials (claude-starter v3.8): code reads them at\n# execution time; Claude Read-denied; git sees only the placeholder.\n.secrets/*\n**/.secrets/*\n!.secrets/.gitkeep\n' \
    >> "$TARGET/.gitignore"
  added+=(".gitignore (+ .secrets/)")
fi
if [ -f "$TARGET/.gitignore" ] && ! grep -qxF '.claude/evidence/' "$TARGET/.gitignore"; then
  printf '\n# Evidence ledger (claude-starter v4): per-machine lane, checker and Codex\n# records, run logs (mode 600), pid locks and pair-codex run state — written\n# only by scripts/evidence.sh and scripts/task-pair.sh. Never memory, never\n# committed; .claude/done-lanes.trust and tasks/*/donelog are the tracked side.\n.claude/evidence/\n' \
    >> "$TARGET/.gitignore"
  added+=(".gitignore (+ .claude/evidence/)")
fi

# v3 task-runtime ignores (R32): the PASS cache, the STATUS view, .last-verify
# and pair/.fp-* name files v4 never writes (pair run state moved under
# .claude/evidence/). --update-stock drops a block only while it is verbatim
# template or sync text and none of those files exists — a dropped ignore
# would put a leftover runtime file into git status. Edited blocks stay.
if [ "$UPDATE_STOCK" = 1 ] && [ -f "$TARGET/.gitignore" ]; then
  gi="$(cat "$TARGET/.gitignore"; printf x)"; gi="${gi%x}"; gi4="$gi"
  for b in \
    $'# Stop-gate PASS-cache — runtime state; MUST stay ignored (gitignoring it\n# keeps it out of its own change-fingerprint).\n.ai_context/tasks/*/.gate-cache\n\n' \
    $'# Task live view + last verify output — regenerated by hooks/scripts; a\n# VIEW, never memory. Ignored for the same fingerprint reason as the cache.\n.ai_context/tasks/*/STATUS.md\n.ai_context/tasks/*/.last-verify\n.ai_context/tasks/*/pair/.fp-*\n\n' \
    $'# Task live view + last verify output — regenerated by hooks/scripts; a\n# VIEW, never memory. Ignored for the same fingerprint reason as the cache.\n.ai_context/tasks/*/STATUS.md\n.ai_context/tasks/*/.last-verify\n\n' \
    $'\n# Task live view + last verify output (claude-starter v3.12) — regenerated\n# by hooks/scripts; a VIEW, never memory. Ignored for the same fingerprint\n# reason as .gate-cache.\n.ai_context/tasks/*/STATUS.md\n.ai_context/tasks/*/.last-verify\n' \
    $'\n# pair-codex in-flight tree fingerprints (claude-starter, ADR-028) — written\n# by scripts/task-pair.sh per run and removed on settle; never memory.\n.ai_context/tasks/*/pair/.fp-*\n'; do
    gi4="${gi4/"$b"/}"
  done
  if [ "$gi4" != "$gi" ]; then
    v3rt=""
    for g in STATUS.md .last-verify .gate-cache 'pair/.fp-*'; do
      if compgen -G "$TARGET/.ai_context/tasks/*/$g" >/dev/null; then v3rt=1; fi
    done
    if [ -n "$v3rt" ]; then
      suggest+=("v3 task-runtime files exist (tasks/*/STATUS.md, .last-verify, .gate-cache, pair/.fp-*) — views, never memory; delete them, then re-run to drop their .gitignore lines")
    else
      printf '%s' "$gi4" > "$TARGET/.gitignore"
      retired+=(".gitignore: v3 task-runtime block")
    fi
  fi
fi

# --- Report-only checks -----------------------------------------------------------
cur_schema="$(grep -m1 -Eo 'schema: v[0-9]+' "$SCRIPT_DIR/.ai_context/INDEX.md" 2>/dev/null || echo 'unknown')"
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
  suggest+=("CLAUDE.md has no 'Definition of done' section — copy one from templates/CLAUDE.md.<kind>")
fi

# /number-check ships as a skill; the DoD line that makes it a rule lives in
# CLAUDE.md, which sync never edits. Suggest it once — on the sync that
# installs the skill — so projects that report no numbers are not nagged.
if printf '%s\n' "${added[@]}" | grep -qx '.claude/skills/number-check/SKILL.md' \
   && [ -f "$TARGET/CLAUDE.md" ] && ! grep -q 'number-check' "$TARGET/CLAUDE.md"; then
  suggest+=("new skill /number-check installed — if this project reports measured numbers (backtests, benchmarks, metrics), add to CLAUDE.md's Definition of done:
      - Every reported number passed \`/number-check\`: work count (trades / rows), quiet-failure count (errors / NaN), run or window spread, and the limiter stated with it.")
fi

# v4 /task proves slices with declared lanes; like the DoD line above, said
# once — on the sync that installs evidence.sh.
if printf '%s\n' ${added[@]+"${added[@]}"} | grep -qx 'scripts/evidence.sh' && [ ! -f "$TARGET/.claude/done-lanes" ]; then
  suggest+=("v4 /task needs declared lanes — open Claude in the project and run /setup: it writes .claude/skills/verify/SKILL.md from .claude/skills/setup/verify-template.md, declares .claude/done-lanes (≤3 lanes) and runs: bash scripts/evidence.sh trust <lane>")
fi
if [ -f "$TARGET/CLAUDE.md" ] && grep -qE 'Task profile:|task-profile\.sh' "$TARGET/CLAUDE.md"; then
  suggest+=("CLAUDE.md still pins a v3 task profile ('Task profile:' / task-profile.sh) — profiles are gone in v4; replace the '## Long-horizon tasks' body with the template's (templates/CLAUDE.md.<kind>)")
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
if [ -f "$TARGET/.claude/settings.json" ] && ! grep -q 'SubagentStop' "$TARGET/.claude/settings.json"; then
  suggest+=("settings.json has no SubagentStop wiring (v4) — replace its \"SubagentStart\" block with the template's \"SubagentStart\" + \"SubagentStop\" blocks (matchers executor, checker → spawn-log.sh); without them no checker record is written and evidence.sh done refuses every slice")
fi
if [ -f "$TARGET/.claude/settings.json" ] && { ! grep -qF '.claude/evidence/' "$TARGET/.claude/settings.json" || ! grep -qF '.claude/gitleaks.toml' "$TARGET/.claude/settings.json"; }; then
  suggest+=("settings.json lacks the v4 evidence denies — add to permissions.deny: \"Edit(./.claude/evidence/**)\", \"Edit(./.claude/done-lanes.trust)\", \"Edit(./.ai_context/tasks/**/donelog)\", \"Edit(./.claude/gitleaks.toml)\" (keep the gatelog/spawnlog denies: they protect v3 evidence)")
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
  done < <(sed -n '/"ask": \[/,/\]/p' "$SCRIPT_DIR/.claude/settings.json" | grep -oE '"Edit\([^"]*\)"')
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

# --- Summary ------------------------------------------------------------------------
echo ""
echo "sync-project: $TARGET"
echo ""
if [ "${#added[@]}" -gt 0 ]; then
  echo "Added (${#added[@]}):"
  for a in "${added[@]}"; do echo "  + $a"; done
else
  echo "Added: nothing — all mechanism files already present."
fi
echo ""
if [ "${#updated[@]}" -gt 0 ]; then
  echo "Updated stock files (${#updated[@]}):"
  for u in "${updated[@]}"; do echo "  ~ $u"; done
  echo ""
fi
if [ "${#retired[@]}" -gt 0 ]; then
  echo "Retired — stock copies of files v4 removed, deleted (${#retired[@]}):"
  for r in "${retired[@]}"; do echo "  - $r"; done
  echo ""
fi
if [ "${#suggest[@]}" -gt 0 ]; then
  echo "Suggestions (apply by hand — nothing was changed):"
  for s in "${suggest[@]}"; do echo "  * $s"; done
else
  echo "Suggestions: none."
fi
echo ""
if [ "$n_replaced" -gt 0 ] || [ "${#retired[@]}" -gt 0 ]; then
  echo "Stock copies were replaced or deleted as listed above; customized files were not touched. Review with: git -C \"$TARGET\" status"
else
  echo "Nothing was overwritten or deleted. Review with: git -C \"$TARGET\" status"
fi
