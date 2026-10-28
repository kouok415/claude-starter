#!/usr/bin/env bash
#
# pre-commit hook — S2 backstop: no bulk dumps into .ai_context/.
#
# Any single staged .ai_context file over 100 KB is almost certainly a
# pasted log, a dataset, or a binary that belongs elsewhere — S2 says to
# reference bulk by path, commit hash, or link instead. The cap is set an
# order of magnitude above any legitimate memory file on purpose: this
# guard exists to catch dumps, not to nag prose. (state.md has its own
# 5 KB cap — S7, check-state-size.sh.)

set -uo pipefail

git rev-parse --git-dir >/dev/null 2>&1 || exit 0

CAP=102400
bad=0
while IFS= read -r f; do
  case "$f" in .ai_context/*) ;; *) continue ;; esac
  # The harness's own machine logs are not dumps: scripts and hooks append one
  # row per event (the append-only guard protects them) and long tasks outgrow
  # the cap (v3 gatelogs reached 137 KB on one project).
  case "$f" in .ai_context/tasks/*/donelog|.ai_context/tasks/*/gatelog|.ai_context/tasks/*/spawnlog) continue ;; esac
  sz="$(git cat-file -s ":$f" 2>/dev/null || echo 0)"
  if [ "${sz:-0}" -gt "$CAP" ]; then
    echo "S2 violation: $f is ${sz} bytes staged (cap ${CAP})."
    echo "  Externalize bulk: keep the artifact outside .ai_context/ (or outside"
    echo "  git) and reference it by path, commit hash, or link."
    bad=1
  fi
done < <(git diff --cached --name-only --diff-filter=ACMR)

exit "$bad"
