#!/usr/bin/env bash
#
# PostToolUse hook (Edit|Write|MultiEdit) — instant lint feedback loop.
#
# Delegates to .claude/hooks/lint.sh if the project has created one (copy
# lint.sh.example after your language init). On lint failure this exits 2
# with the errors on stderr, which Claude Code feeds back to Claude so it
# can fix the problem immediately instead of at review time.
#
# No lint.sh => no-op. Never blocks the edit itself (the tool already ran).

set -uo pipefail

ROOT="${CLAUDE_PROJECT_DIR:-.}"
LINT="$ROOT/.claude/hooks/lint.sh"
if [ -f "$LINT" ] && [ ! -x "$LINT" ]; then
  # Present but not executable (a forgotten chmod, a mode-stripping checkout):
  # the lint loop is silently OFF — say so, never block (warning layer, F14).
  printf 'WARNING: .claude/hooks/lint.sh exists but is not executable — the lint loop is OFF. chmod +x it to arm.\n' >&2
  exit 0
fi
[ -x "$LINT" ] || exit 0

# Hook input is JSON on stdin; best-effort extraction of the edited path.
payload="$(cat 2>/dev/null || true)"
file="$(printf '%s' "$payload" | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"

if out="$("$LINT" "$file" 2>&1)"; then
  exit 0
else
  # Bounded: a catastrophic lint run must not flood the context window.
  printf '%s\n' "$out" | tail -n 40 >&2
  exit 2
fi
