#!/usr/bin/env bash
#
# pre-commit hook — mechanical enforcement of the append-only contracts in
# .ai_context/INDEX.md's writing protocol: decisions.md, journal/*.md,
# scoreboard.csv, scoreboard-v4.csv, friction.csv, defects.csv,
# tasks/*/donelog, .claude/done-lanes.trust (and v3's tasks/*/gatelog,
# tasks/*/spawnlog) accumulate history — a commit may ADD to them, never
# change or remove what is already there, and never delete, rename or
# retype the files themselves. The logs and decisions.md grow at the END
# only (no line inserted mid-file); a journal entry, once committed, is
# never edited — a new dated entry corrects it. Their writers (evidence.sh,
# the hooks, harness-report.sh) only append; the v3 logs stay frozen
# evidence.
#
# Wired with always_run: pre-commit hands a hook only the files it lists,
# and it never lists a deleted one, so this script reads the staged diff
# itself (-z, core.quotePath=false: any file name, as it is).
#
# Deliberately NOT covered: card.md (scripts flip its status marks),
# notes.md (rewritten as facts change), state.md (overwrite-friendly; S7
# has its own check).
#
# Corrections to covered files are made by APPENDING a correcting row or a
# dated addendum entry. For the rare legitimate rewrite (e.g. pruning a
# years-old journal), commit with --no-verify and say why in the message.

set -uo pipefail

git rev-parse --git-dir >/dev/null 2>&1 || exit 0
# Initial commit: everything is an addition — nothing to protect yet.
git rev-parse --verify -q HEAD >/dev/null 2>&1 || exit 0
cd "$(git rev-parse --show-toplevel)" || exit 1
export GIT_LITERAL_PATHSPECS=1

bad=""
flag() { bad="$bad
  $1"; }
# -U0 hunks of one modified file: every hunk at the old end, and no removed
# line — except the one way an append shows up when the old last line had no
# newline: that line removed (with the no-newline marker) and re-added
# unchanged as the first added line.
tail_only() { # $1 = path, $2 = line count of the committed version
  git diff --cached -U0 --no-color --no-ext-diff --diff-algorithm=myers HEAD -- "$1" | awk -v n="$2" '
    /^@@ / { if (want) bad = 1
             h = 1; split($2, o, ","); os = substr(o[1], 2) + 0; oc = (2 in o) ? o[2] + 0 : 1
             if (os != n || oc > 1) bad = 1
             want = (oc == 1); nl = 0; prev = "@"; next }
    !h { next }
    { c = substr($0, 1, 1) }
    c == "-" { rm = substr($0, 2); prev = "-"; next }
    c == "\\" { if (prev == "-") nl = 1; prev = "\\"; next }
    c == "+" { if (want) { if (!nl || substr($0, 2) != rm) bad = 1; want = 0 }; prev = "+"; next }
    END { if (want) bad = 1; exit bad }'
}

while IFS= read -r -d '' rec; do
  a="${rec%%$'\t'*}"; r="${rec#*$'\t'}"; d="${r%%$'\t'*}"; path="${r#*$'\t'}"
  [ -n "$path" ] || continue
  case "$path" in
    .ai_context/decisions.md) ;;
    .ai_context/scoreboard.csv) ;;
    .ai_context/scoreboard-v4.csv) ;;
    .ai_context/friction.csv) ;;
    .ai_context/defects.csv) ;;
    .ai_context/journal/*.md) ;;
    .ai_context/tasks/*/donelog) ;;
    .ai_context/tasks/*/gatelog) ;;      # v3 evidence — still history (the v4 pilot compares against it)
    .ai_context/tasks/*/spawnlog) ;;     # v3 evidence — still history
    .claude/done-lanes.trust) ;;
    *) continue ;;
  esac
  # A new file is a pure addition (a new journal entry too).
  git cat-file -e "HEAD:$path" 2>/dev/null || continue
  if ! git cat-file -e ":$path" 2>/dev/null; then
    flag "$path (deleted or renamed: append-only files are never deleted, renamed, or copied over)"; continue
  fi
  hm="$(git ls-tree HEAD -- "$path" | cut -d' ' -f1)"; im="$(git ls-files -s -- "$path" | cut -d' ' -f1)"
  if [ "$hm" != "$im" ]; then
    case "$hm $im" in *120000*|*160000*)
      flag "$path (replaced by a link or a submodule: append-only files stay regular files)"; continue ;;
    esac
  fi
  case "$path" in .ai_context/journal/*)
    flag "$path (a committed journal entry is never edited — add a new dated entry instead)"; continue ;;
  esac
  case "$a$d" in *-*) flag "$path (binary change)"; continue ;; esac
  n="$(git cat-file -p "HEAD:$path" | awk 'END {print NR}')"
  tail_only "$path" "$n" || flag "$path (existing lines were changed or removed, or lines inserted before the end — append at the end only)"
done < <(git -c core.quotePath=false diff --cached --numstat -z --no-color --no-renames HEAD)

if [ -n "$bad" ]; then
  echo "Append-only violation (.ai_context writing protocol):$bad"
  echo "These files accumulate history: append new lines only; fix mistakes by"
  echo "appending a correcting row/entry. Legitimate rewrite? Use --no-verify"
  echo "and explain why in the commit message."
  exit 1
fi
