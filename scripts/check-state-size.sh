#!/usr/bin/env bash
#
# pre-commit hook — mechanical enforcement of S7: .ai_context/state.md ≤ 5 KB.
# Measures the STAGED content (what this commit actually records); falls back
# to the working tree outside git.

set -euo pipefail

f=".ai_context/state.md"
[ -f "$f" ] || exit 0

size="$(git show ":$f" 2>/dev/null | wc -c | tr -d ' ')"
if [ -z "$size" ] || [ "$size" -eq 0 ]; then
  size="$(wc -c < "$f" | tr -d ' ')"
fi

if [ "$size" -gt 5120 ]; then
  echo "S7 violation: $f is ${size} bytes staged (cap: 5120)."
  echo "Archive resolved sections to .ai_context/journal/YYYY-MM-DD-<topic>.md and trim."
  exit 1
fi
