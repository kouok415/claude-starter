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
copy_if_missing .claude/hooks/lint.sh.example
copy_if_missing .claude/skills/wrap/SKILL.md
copy_if_missing .claude/hooks/stop-gate.sh
copy_if_missing .claude/skills/task/SKILL.md
copy_if_missing .claude/skills/task/reference.md
copy_if_missing .claude/skills/setup/SKILL.md
copy_if_missing .claude/agents/scout.md
copy_if_missing .claude/agents/planner.md
copy_if_missing .claude/agents/plan-critic.md
copy_if_missing .claude/agents/executor.md
copy_if_missing .claude/agents/verifier.md
copy_if_missing .claude/agents/reframer.md
copy_if_missing .ai_context/tasks/.gitkeep
copy_if_missing scripts/check-state-size.sh
copy_if_missing scripts/check-append-only.sh
copy_if_missing scripts/check-context-bulk.sh
copy_if_missing scripts/harness-report.sh
copy_if_missing scripts/precommit-gitleaks.sh
copy_if_missing .pre-commit-config.yaml

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
stock_update .claude/hooks/stop-gate.sh
stock_update .claude/skills/wrap/SKILL.md
stock_update .claude/skills/task/SKILL.md
stock_update .claude/skills/task/reference.md
stock_update .claude/skills/setup/SKILL.md
stock_update .claude/agents/scout.md
stock_update .claude/agents/planner.md
stock_update .claude/agents/plan-critic.md
stock_update .claude/agents/executor.md
stock_update .claude/agents/verifier.md
stock_update .claude/agents/reframer.md
stock_update .ai_context/INDEX.md
stock_update scripts/check-state-size.sh
stock_update scripts/check-append-only.sh
stock_update scripts/check-context-bulk.sh
stock_update scripts/harness-report.sh
stock_update scripts/precommit-gitleaks.sh
stock_update .pre-commit-config.yaml

chmod +x "$TARGET"/.claude/hooks/*.sh "$TARGET"/scripts/*.sh 2>/dev/null || true

# --update-stock leaves a provenance trail: the spawn stamp records which
# template vintage the mechanisms were last synced to (stale-spawner debugging).
if [ "$UPDATE_STOCK" = 1 ] && [ "$(( ${#updated[@]} + ${#added[@]} ))" -gt 0 ]; then
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

if [ -f "$TARGET/CLAUDE.md" ] && ! grep -qi 'definition of done' "$TARGET/CLAUDE.md"; then
  suggest+=("CLAUDE.md has no 'Definition of done' section — copy one from templates/CLAUDE.md.<kind>")
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
