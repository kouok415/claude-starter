#!/usr/bin/env bash
#
# pre-commit hook — mechanical enforcement of H1: no secrets in commits.
# Uses gitleaks if installed; skips with a warning otherwise so the hook
# never blocks machines that don't have it (bootstrap-machine.sh offers it).

set -uo pipefail

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
