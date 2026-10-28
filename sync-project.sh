#!/usr/bin/env bash
#
# sync-project.sh — bring an existing claude-starter project up to the
# current template's mechanisms.
#
# Conservative by design:
#   - only ADDS files that are missing (never overwrites anything)
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
      echo "                  stock copies); customized files are never touched"
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

copy_if_missing() {
  local rel="$1"
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
stock_update() {
  local rel="$1" src="$SCRIPT_DIR/$1" dst="$TARGET/$1" h
  [ "$UPDATE_STOCK" = 1 ] || return 0
  [ -f "$src" ] && [ -f "$dst" ] || return 0
  cmp -s "$dst" "$src" && return 0
  git -C "$SCRIPT_DIR" rev-parse --git-dir >/dev/null 2>&1 || return 0
  while IFS= read -r h; do
    if git -C "$SCRIPT_DIR" show "$h:$rel" 2>/dev/null | cmp -s - "$dst"; then
      cp "$src" "$dst"
      updated+=("$rel")
      return 0
    fi
  done < <(git -C "$SCRIPT_DIR" log --format=%H -- "$rel")
  suggest+=("$rel differs from every known template version (customized) — merge by hand: diff \"$TARGET/$rel\" \"$SCRIPT_DIR/$rel\"")
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
# NOTICE is stock only while it carries the template's marker; a project's
# own NOTICE is never replaced (it gets the append suggestion below).
if grep -qF 'claude-starter third-party notices' "$TARGET/NOTICE" 2>/dev/null; then stock_update NOTICE; fi

chmod +x "$TARGET"/.claude/hooks/*.sh "$TARGET"/scripts/*.sh 2>/dev/null || true

# Any sync that changed mechanisms leaves a provenance trail: the stamp
# records which template vintage the mechanisms were last synced to
# (stale-spawner debugging; per-version fleet attribution). v3.9 stamped
# only under --update-stock, so a default sync that ADDED new-version
# files kept the old vintage and mis-attributed later task rows (F15).
if [ "$(( ${#updated[@]} + ${#added[@]} ))" -gt 0 ]; then
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
if [ -f "$TARGET/.gitignore" ] && ! grep -qF '.ai_context/tasks/*/STATUS.md' "$TARGET/.gitignore"; then
  printf '\n# Task live view + last verify output (claude-starter v3.12) — regenerated\n# by hooks/scripts; a VIEW, never memory. Ignored for the same fingerprint\n# reason as .gate-cache.\n.ai_context/tasks/*/STATUS.md\n.ai_context/tasks/*/.last-verify\n' \
    >> "$TARGET/.gitignore"
  added+=(".gitignore (+ tasks/*/STATUS.md + .last-verify)")
fi
if [ -f "$TARGET/.gitignore" ] && ! grep -qF '.ai_context/tasks/*/pair/.fp-*' "$TARGET/.gitignore"; then
  printf '\n# pair-codex in-flight tree fingerprints (claude-starter, ADR-028) — written\n# by scripts/task-pair.sh per run and removed on settle; never memory.\n.ai_context/tasks/*/pair/.fp-*\n' \
    >> "$TARGET/.gitignore"
  added+=(".gitignore (+ tasks/*/pair/.fp-*)")
fi

# --- Report-only checks -----------------------------------------------------------
cur_schema="$(grep -m1 -Eo 'schema: v[0-9]+' "$SCRIPT_DIR/.ai_context/INDEX.md" 2>/dev/null || echo 'unknown')"
tgt_schema="$(grep -m1 -Eo 'schema: v[0-9]+' "$TARGET/.ai_context/INDEX.md" 2>/dev/null || echo 'none')"
if [ "$tgt_schema" != "$cur_schema" ]; then
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

if [ -f "$TARGET/.pre-commit-config.yaml" ] && [ ! -f "$TARGET/.git/hooks/pre-commit" ]; then
  suggest+=("pre-commit config present but not installed — run: (cd \"$TARGET\" && pre-commit install)")
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

if [ -f "$TARGET/.claude/hooks/session-start.sh" ] && ! grep -q 'tasks/CURRENT' "$TARGET/.claude/hooks/session-start.sh"; then
  suggest+=("session-start.sh predates the /task harness — diff against the template to add active-task plan injection")
fi

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
if [ "${#suggest[@]}" -gt 0 ]; then
  echo "Suggestions (apply by hand — nothing was changed):"
  for s in "${suggest[@]}"; do echo "  * $s"; done
else
  echo "Suggestions: none."
fi
echo ""
echo "Nothing was overwritten or deleted. Review with: git -C \"$TARGET\" status"
