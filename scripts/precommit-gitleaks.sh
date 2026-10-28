#!/usr/bin/env bash
#
# precommit-gitleaks.sh — the project's gitleaks wrapper.
#   (no args)            pre-commit hook: scan the STAGED diff with gitleaks' own config
#                        lookup (a repo-root .gitleaks.toml if the project has one).
#                        Skips with a warning when gitleaks is missing.
#   --scan-file <path>   scan one file with .claude/gitleaks.toml (evidence.sh lane and
#                        canary logs); prints the rule ids that fired, one per line.
#                        Without gitleaks only internal-ipv4 runs (grep -E on the same
#                        regex and allowlist, read from .claude/gitleaks.toml).
# Exit: 0 clean · 1 leak or scan error · 2 usage · 3 clean, but only internal-ipv4 was
#       checked (gitleaks missing; --scan-file only)

set -uo pipefail

if [ $# -eq 0 ]; then
  if ! command -v gitleaks >/dev/null 2>&1; then
    echo "warning: gitleaks not installed — H1 secret scan skipped (see bootstrap-machine.sh)"
    exit 0
  fi

  # gitleaks >= 8.19 uses `git --staged`; older versions use `protect --staged`.
  if gitleaks help git >/dev/null 2>&1; then
    exec gitleaks git --staged --redact --no-banner
  else
    exec gitleaks protect --staged --redact --no-banner
  fi
fi

[ "$1" = --scan-file ] && [ $# -eq 2 ] || { echo "usage: precommit-gitleaks.sh [--scan-file <path>]" >&2; exit 2; }
f="$2"; cfg="$(cd "$(dirname "$0")/.." && pwd)/.claude/gitleaks.toml"
[ -f "$f" ] || { echo "precommit-gitleaks: no such file: $f" >&2; exit 2; }
[ -f "$cfg" ] || echo "precommit-gitleaks: .claude/gitleaks.toml missing — default rules only (re-sync the template)" >&2

if command -v gitleaks >/dev/null 2>&1; then
  set -- --redact --no-banner -v --log-level error
  [ -f "$cfg" ] && set -- -c "$cfg" "$@"
  if gitleaks help dir >/dev/null 2>&1; then out="$(gitleaks dir "$f" "$@" 2>&1)"; else out="$(gitleaks detect --no-git -s "$f" "$@" 2>&1)"; fi
  rc=$?
  [ "$rc" = 0 ] && exit 0
  ids="$(printf '%s\n' "$out" | sed -n 's/^RuleID:[[:space:]]*\([^[:space:]]*\).*/\1/p' | sort -u)"
  # A scan that broke (bad config, crash) fails the run too — never "clean".
  if [ "$rc" = 1 ] && [ -n "$ids" ]; then printf '%s\n' "$ids"; else echo scan-error; fi
  exit 1
fi

# No gitleaks: the internal-ipv4 rule alone, read from the same config.
[ -f "$cfg" ] || { echo scan-error; exit 1; }
re="$(sed -n "/^id = \"internal-ipv4\"/,/^regex = / s/^regex = '''\(.*\)'''\$/\1/p" "$cfg")"
allow="$(sed -n "/^id = \"internal-ipv4\"/,/^regexes = / s/^regexes = \['''\(.*\)'''\]\$/\1/p" "$cfg")"
[ -n "$re" ] || { echo scan-error; exit 1; }
if grep -Eo "$re" "$f" | sed -E 's/^[^0-9]//; s/[^0-9]+$//' | grep -vE "${allow:-^$}" | grep -q .; then
  echo internal-ipv4; exit 1
fi
exit 3
