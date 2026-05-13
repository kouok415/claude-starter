#!/usr/bin/env bash
#
# bootstrap-machine.sh — one-time setup for a machine that will use
# the claude-starter workflow.
#
# What it does:
#   1. Ensures git, gh, bun, uv are installed (skips if already present)
#   2. Configures git user.name / user.email if missing
#   3. Authenticates gh CLI if needed
#   4. Installs ~/.claude/CLAUDE.md (global engineering principles)
#   5. Optionally installs the PUA plugin (tanweai/pua) via Claude plugin
#      marketplace — corporate-pressure mode that escalates when Claude
#      gets stuck
#
# Usage:
#   ./bootstrap-machine.sh
#
# Idempotent: safe to re-run.

set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
SKILLS_DIR="$CLAUDE_DIR/skills"

# --- Helpers ----------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

confirm() {
  local prompt="$1"
  read -rp "$prompt (y/n): " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

# --- 1. Install tools -------------------------------------------------------
install_apt() {
  if have apt-get; then
    sudo apt-get update -y
    sudo apt-get install -y "$@"
  else
    echo "apt-get not available — install manually: $*"
    return 1
  fi
}

if ! have git; then
  echo "Installing git..."
  install_apt git
fi

if ! have gh; then
  echo "Installing gh (GitHub CLI)..."
  install_apt gh || {
    echo "Falling back to curl install for gh..."
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
    sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
    sudo apt-get update && sudo apt-get install -y gh
  }
fi

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

# --- 2. Git config ----------------------------------------------------------
if [ -z "$(git config --global user.name || true)" ] \
   || [ -z "$(git config --global user.email || true)" ]; then
  echo "Git user identity not configured."
  read -rp "  Git user.name:  " gname
  read -rp "  Git user.email: " gmail
  git config --global user.name "$gname"
  git config --global user.email "$gmail"
fi

# --- 3. gh auth -------------------------------------------------------------
if ! gh auth status >/dev/null 2>&1; then
  echo "Authenticating gh CLI..."
  gh auth login
fi

# --- 4. ~/.claude/ setup ----------------------------------------------------
mkdir -p "$CLAUDE_DIR" "$SKILLS_DIR"

# Locate the source global-claude/CLAUDE.md. Try, in order:
#   1. Sibling of this script (claude-starter and global-claude both extracted
#      side-by-side, e.g. /code/claude-starter and /code/global-claude)
#   2. Inside the script's own repo (if someone vendored it in)
#   3. Inside the current working directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GLOBAL_SRC=""
for candidate in \
  "$SCRIPT_DIR/../global-claude/CLAUDE.md" \
  "$SCRIPT_DIR/global-claude/CLAUDE.md" \
  "./global-claude/CLAUDE.md"; do
  if [ -f "$candidate" ]; then
    GLOBAL_SRC="$candidate"
    break
  fi
done

# Global CLAUDE.md
if [ ! -f "$CLAUDE_DIR/CLAUDE.md" ]; then
  if [ -n "$GLOBAL_SRC" ]; then
    cp "$GLOBAL_SRC" "$CLAUDE_DIR/CLAUDE.md"
    echo "Installed $CLAUDE_DIR/CLAUDE.md (from $GLOBAL_SRC)"
  else
    echo "ERROR: could not locate global-claude/CLAUDE.md"
    echo "  Tried:"
    echo "    $SCRIPT_DIR/../global-claude/CLAUDE.md"
    echo "    $SCRIPT_DIR/global-claude/CLAUDE.md"
    echo "    ./global-claude/CLAUDE.md"
    echo ""
    echo "  Make sure global-claude/ is extracted next to claude-starter/,"
    echo "  or copy the file manually:"
    echo "    cp <path-to>/global-claude/CLAUDE.md $CLAUDE_DIR/CLAUDE.md"
    exit 1
  fi
else
  echo "$CLAUDE_DIR/CLAUDE.md already exists — leaving alone."
fi

# --- 5. PUA plugin (optional) ----------------------------------------------
# PUA is a third-party Claude Code plugin (tanweai/pua) that triggers when
# Claude is about to give up, gets stuck, or detects user frustration.
# It installs via Claude's own plugin marketplace, not by copying a SKILL.md
# into ~/.claude/skills/ — that older method is deprecated.
if ! have claude; then
  echo ""
  echo "Note: 'claude' CLI not detected — skipping PUA plugin install."
  echo "  Install Claude Code first, then run:"
  echo "    claude plugin marketplace add tanweai/pua"
  echo "    claude plugin install pua@pua-skills"
elif confirm "Install PUA plugin (tanweai/pua — corporate-pressure mode)?"; then
  echo "Adding PUA marketplace..."
  claude plugin marketplace add tanweai/pua || {
    echo "Warning: marketplace add failed — see https://github.com/tanweai/pua"
  }
  echo "Installing PUA plugin..."
  claude plugin install pua@pua-skills || {
    echo "Warning: plugin install failed — see https://github.com/tanweai/pua"
  }
  echo ""
  echo "PUA installed. Auto-triggers on stuck/frustration; manually: /pua"
fi

# --- Done -------------------------------------------------------------------
cat <<EOF

✓ Machine bootstrap complete.

Tools:    $(have git && echo git ✓) $(have gh && echo gh ✓) $(have bun && echo bun ✓) $(have uv && echo uv ✓) $(have claude && echo claude ✓)
Global:   $CLAUDE_DIR/CLAUDE.md
Skills:   $SKILLS_DIR (empty — drop your own SKILL.md folders here as needed)
Plugins:  managed by 'claude plugin' — see 'claude plugin list'

To create a new project:
  ./start_project.sh <project-name>

EOF
