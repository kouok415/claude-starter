#!/usr/bin/env bash
#
# pre-commit hook — mechanical enforcement of S7: .ai_context/state.md ≤ 5 KB.
# Measures the STAGED content (what this commit actually records); falls back
# to the working tree when the file is untracked or we are outside git — and
# says which one it measured (F20: the fallback used to be dead code under
# errexit, and its measurement was mislabeled as staged).

set -uo pipefail

f=".ai_context/state.md"
[ -f "$f" ] || exit 0

if size="$(git cat-file -s ":$f" 2>/dev/null)"; then
  src=staged
else
  src=worktree
  size="$(wc -c < "$f" | tr -d ' ')"
fi

if [ "${size:-0}" -gt 5120 ]; then
  echo "S7 violation: $f is ${size} bytes (${src}; cap: 5120)."
  echo "Archive resolved sections to .ai_context/journal/YYYY-MM-DD-<topic>.md and trim."
  exit 1
fi
