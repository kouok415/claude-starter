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
TARGET="${1:?Usage: ./sync-project.sh <path-to-project>}"
TARGET="${TARGET%/}"

if [ ! -d "$TARGET/.ai_context" ]; then
  echo "Error: $TARGET doesn't look like a claude-starter project (.ai_context/ missing)"
  exit 1
fi

added=()
suggest=()

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
copy_if_missing .claude/hooks/lint.sh.example
copy_if_missing .claude/skills/wrap/SKILL.md
copy_if_missing .claude/hooks/stop-gate.sh
copy_if_missing .claude/skills/task/SKILL.md
copy_if_missing .claude/agents/planner.md
copy_if_missing .claude/agents/plan-critic.md
copy_if_missing .claude/agents/executor.md
copy_if_missing .claude/agents/verifier.md
copy_if_missing .claude/agents/reframer.md
copy_if_missing .ai_context/tasks/.gitkeep
copy_if_missing scripts/check-state-size.sh
copy_if_missing scripts/precommit-gitleaks.sh
copy_if_missing .pre-commit-config.yaml

chmod +x "$TARGET"/.claude/hooks/*.sh "$TARGET"/scripts/*.sh 2>/dev/null || true

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
         README.zh-TW.md .claudeignore CLAUDE.md.template; do
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
if [ "${#suggest[@]}" -gt 0 ]; then
  echo "Suggestions (apply by hand — nothing was changed):"
  for s in "${suggest[@]}"; do echo "  * $s"; done
else
  echo "Suggestions: none."
fi
echo ""
echo "Nothing was overwritten or deleted. Review with: git -C \"$TARGET\" status"
