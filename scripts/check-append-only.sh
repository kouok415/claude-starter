#!/usr/bin/env bash
#
# pre-commit hook — mechanical enforcement of the append-only contracts in
# .ai_context/INDEX.md's writing protocol: decisions.md, journal/*.md,
# scoreboard.csv, friction.csv and tasks/*/gatelog accumulate history — a
# commit may ADD lines to them, never change or remove what is already
# there, and never delete or rename the files themselves.
#
# Deliberately NOT covered: lessons.md and brief.md — /wrap legitimately
# distills them when they exceed their 4 KB caps. state.md is overwrite-
# friendly by design (it has its own S7 size check instead).
#
# Corrections to covered files are made by APPENDING a correcting row or a
# dated addendum entry. For the rare legitimate rewrite (e.g. pruning a
# years-old journal), commit with --no-verify and say why in the message.

set -uo pipefail

git rev-parse --git-dir >/dev/null 2>&1 || exit 0
# Initial commit: everything is an addition — nothing to protect yet.
git rev-parse --verify -q HEAD >/dev/null 2>&1 || exit 0

bad=""
while IFS=$'\t' read -r status path _rest; do
  [ -n "${path:-}" ] || continue
  case "$path" in
    .ai_context/decisions.md) ;;
    .ai_context/scoreboard.csv) ;;
    .ai_context/friction.csv) ;;
    .ai_context/journal/*.md) ;;
    .ai_context/tasks/*/gatelog) ;;
    *) continue ;;
  esac
  case "$status" in
    A) continue ;;   # new file: pure addition
    D|R*|C*)
      bad="$bad
  $path (status $status: append-only files are never deleted, renamed, or copied over)"
      continue ;;
  esac
  # Modified: any removed or changed existing line is a violation.
  if git diff --cached -U0 HEAD -- "$path" | grep -Eq '^-([^-]|$)'; then
    bad="$bad
  $path (existing lines were changed or removed)"
  fi
done < <(git diff --cached --name-status HEAD)

if [ -n "$bad" ]; then
  echo "Append-only violation (.ai_context writing protocol):$bad"
  echo "These files accumulate history: append new lines only; fix mistakes by"
  echo "appending a correcting row/entry. Legitimate rewrite? Use --no-verify"
  echo "and explain why in the commit message."
  exit 1
fi
