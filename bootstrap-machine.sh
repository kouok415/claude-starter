#!/usr/bin/env bash
#
# bootstrap-machine.sh — one-time setup for a machine that will use the
# claude-starter workflow.
#
# What it does:
#   1. Ensures git + gh are installed (apt or brew), gh authenticated
#   2. Configures git user.name / user.email if missing
#   3. Installs or updates ~/.claude/CLAUDE.md (Layer 1 — global principles)
#      Source: global/CLAUDE.md inside this repo (canonical); falls back to
#      a sibling global-claude/ checkout for older setups.
#      Updates never happen silently: you see a diff and confirm, and a
#      dated .bak backup is kept.
#   4. Optional: bun + uv toolchains (the starter itself is language-
#      agnostic; these are conveniences, not requirements)
#   5. Optional: pre-commit + gitleaks (mechanical H1/S7 enforcement)
#   6. Optional: PUA plugin (tanweai/pua). Note: the template's hooks and
#      Definition-of-done already mechanize its core ideas (evidence-first,
#      done-checks); install only if you want the coaching flavor too.
#
# Usage:
#   ./bootstrap-machine.sh [--yes] [--force-global] [--with-toolchains]
#
#   --yes             Non-interactive: required steps only, skip optional
#                     prompts (combine with --with-toolchains as needed)
#   --force-global    Update ~/.claude/CLAUDE.md without prompting
#                     (dated backup still kept)
#   --with-toolchains Install bun + uv without asking
#
# Idempotent: safe to re-run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
SKILLS_DIR="$CLAUDE_DIR/skills"

YES=0
FORCE_GLOBAL=0
WITH_TOOLCHAINS=0

while [ $# -gt 0 ]; do
  case "$1" in
    --yes)             YES=1 ;;
    --force-global)    FORCE_GLOBAL=1 ;;
    --with-toolchains) WITH_TOOLCHAINS=1 ;;
    -h|--help)         sed -n '2,30p' "$0" | sed 's/^#//; s/^ //'; exit 0 ;;
    *) echo "Error: unknown option: $1"; exit 1 ;;
  esac
  shift
done

# --- Helpers ------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

confirm() {
  # Optional steps: skipped in --yes mode and when there is no TTY.
  [ "$YES" = 1 ] && return 1
  [ -t 0 ] || return 1
  local ans
  read -rp "$1 (y/n): " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

pkg_install() {
  if have apt-get; then
    sudo apt-get update -y
    sudo apt-get install -y "$@"
  elif have brew; then
    brew install "$@"
  else
    echo "No apt-get or brew found — install manually: $*"
    return 1
  fi
}

# --- 1. Core tools: git + gh ----------------------------------------------------
if ! have git; then
  echo "Installing git..."
  pkg_install git
fi

if ! have gh; then
  echo "Installing gh (GitHub CLI)..."
  pkg_install gh || {
    if have apt-get; then
      echo "Falling back to GitHub's apt repo for gh..."
      curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
      sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
      sudo apt-get update && sudo apt-get install -y gh
    else
      echo "Install gh manually: https://cli.github.com"
      exit 1
    fi
  }
fi

# --- 2. Git identity --------------------------------------------------------------
if [ -z "$(git config --global user.name || true)" ] \
   || [ -z "$(git config --global user.email || true)" ]; then
  if [ -t 0 ]; then
    echo "Git user identity not configured."
    read -rp "  Git user.name:  " gname
    read -rp "  Git user.email: " gmail
    git config --global user.name "$gname"
    git config --global user.email "$gmail"
  else
    echo "WARNING: git user.name/user.email not configured and no TTY —"
    echo "  set them manually: git config --global user.{name,email}"
  fi
fi

# --- 3. gh auth ---------------------------------------------------------------------
if ! gh auth status >/dev/null 2>&1; then
  if [ -t 0 ]; then
    echo "Authenticating gh CLI..."
    gh auth login
  else
    echo "WARNING: gh not authenticated and no TTY — run 'gh auth login' manually."
  fi
fi

# --- 4. Layer 1: ~/.claude/CLAUDE.md ---------------------------------------------------
mkdir -p "$CLAUDE_DIR" "$SKILLS_DIR"

global_version() {
  grep -m1 -Eo 'global-claude schema: v[0-9]+' "$1" 2>/dev/null \
    | grep -Eo 'v[0-9]+' || echo "v0"
}

GLOBAL_SRC=""
for candidate in \
  "$SCRIPT_DIR/global/CLAUDE.md" \
  "$SCRIPT_DIR/../global-claude/CLAUDE.md"; do
  if [ -f "$candidate" ]; then
    GLOBAL_SRC="$candidate"
    break
  fi
done

if [ -z "$GLOBAL_SRC" ]; then
  echo "ERROR: global/CLAUDE.md not found in this checkout ($SCRIPT_DIR/global/)."
  echo "  The repo should be self-contained — re-clone it, or copy the file manually:"
  echo "    cp <source>/CLAUDE.md $CLAUDE_DIR/CLAUDE.md"
  exit 1
fi

DEST="$CLAUDE_DIR/CLAUDE.md"
if [ ! -f "$DEST" ]; then
  cp "$GLOBAL_SRC" "$DEST"
  echo "Installed $DEST ($(global_version "$DEST"), from $GLOBAL_SRC)"
else
  src_v="$(global_version "$GLOBAL_SRC")"
  dst_v="$(global_version "$DEST")"
  if [ "$FORCE_GLOBAL" = 0 ] && { [ "$src_v" = "$dst_v" ] && cmp -s "$GLOBAL_SRC" "$DEST"; }; then
    echo "$DEST is up to date ($dst_v)."
  else
    echo "Global CLAUDE.md differs (installed: $dst_v, available: $src_v). Diff:"
    diff -u "$DEST" "$GLOBAL_SRC" || true
    if [ "$FORCE_GLOBAL" = 1 ] || confirm "Update $DEST? (dated backup will be kept)"; then
      BAK="$DEST.bak-$(date +%F)"
      cp "$DEST" "$BAK"
      cp "$GLOBAL_SRC" "$DEST"
      echo "Updated $DEST to $src_v (backup: $BAK)"
    else
      echo "Left $DEST unchanged."
    fi
  fi
fi

# --- 5. Optional: language toolchains (bun + uv) ------------------------------------------
# The starter is deliberately language-agnostic; these are conveniences.
if [ "$WITH_TOOLCHAINS" = 1 ] || confirm "Install bun + uv (JS/Python toolchains)?"; then
  if ! have bun; then
    echo "Installing bun..."
    curl -fsSL https://bun.sh/install | bash
    export PATH="$HOME/.bun/bin:$PATH"
  fi
  if ! have uv; then
    echo "Installing uv..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
  fi
fi

# --- 6. Optional: pre-commit + gitleaks (mechanical H1/S7 enforcement) ----------------------
if confirm "Install pre-commit + gitleaks (mechanical secret/size checks at commit time)?"; then
  if ! have pre-commit; then
    if have uv; then
      uv tool install pre-commit && echo "pre-commit installed via uv."
    elif have brew; then
      brew install pre-commit
    else
      echo "Install pre-commit manually: https://pre-commit.com"
    fi
  fi
  if ! have gitleaks; then
    if have brew; then
      brew install gitleaks
    else
      echo "Install gitleaks manually: https://github.com/gitleaks/gitleaks/releases"
      echo "  (The pre-commit hook skips gracefully while it's missing.)"
    fi
  fi
fi

# --- 7. Optional: PUA plugin -----------------------------------------------------------------
if ! have claude; then
  echo ""
  echo "Note: 'claude' CLI not detected — skipping PUA plugin offer."
elif confirm "Install PUA plugin (tanweai/pua — optional coaching flavor)?"; then
  claude plugin marketplace add tanweai/pua \
    || echo "Warning: marketplace add failed — see https://github.com/tanweai/pua"
  claude plugin install pua@pua-skills \
    || echo "Warning: plugin install failed — see https://github.com/tanweai/pua"
fi

# --- Done --------------------------------------------------------------------------------------
cat <<EOF

✓ Machine bootstrap complete.

Tools:    $(have git && echo "git ✓") $(have gh && echo "gh ✓") $(have bun && echo "bun ✓") $(have uv && echo "uv ✓") $(have pre-commit && echo "pre-commit ✓") $(have gitleaks && echo "gitleaks ✓") $(have claude && echo "claude ✓")
Global:   $CLAUDE_DIR/CLAUDE.md ($(global_version "$CLAUDE_DIR/CLAUDE.md"))
Skills:   $SKILLS_DIR
Plugins:  managed by 'claude plugin' — see 'claude plugin list'

To create a new project:
  ./start_project.sh [--kind code|research|analysis] <project-name>

To upgrade an existing claude-starter project to current mechanisms:
  ./sync-project.sh <path-to-project>

EOF
