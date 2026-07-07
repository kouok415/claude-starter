#!/usr/bin/env bash
#
# pre-commit hook — mechanical enforcement of S7: .ai_context/state.md ≤ 5 KB.

set -euo pipefail

f=".ai_context/state.md"
[ -f "$f" ] || exit 0

size="$(wc -c < "$f" | tr -d ' ')"
if [ "$size" -gt 5120 ]; then
  echo "S7 violation: $f is ${size} bytes (cap: 5120)."
  echo "Archive resolved sections to .ai_context/journal/YYYY-MM-DD-<topic>.md and trim."
  exit 1
fi
