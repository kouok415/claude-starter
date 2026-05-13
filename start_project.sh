#!/usr/bin/env bash
#
# start_project.sh — spawn a new project from claude-starter template.
#
# Prerequisites:
#   - gh (GitHub CLI), authenticated: `gh auth status`
#   - git configured: `git config --global user.{name,email}`
#   - Run `bootstrap-machine.sh` once per machine to install both.
#
# Usage:
#   ./start_project.sh <project-name>
#
# What it does:
#   1. Creates a new GitHub repo from the claude-starter template
#   2. Clones it locally
#   3. Renames CLAUDE.md.template -> CLAUDE.md, fills in project name
#   4. Initial commit + push
#
# What it does NOT do (intentionally):
#   - Install language toolchains (do that yourself, varies by project)
#   - Create src/ or any source layout (run npm/uv/cargo init after)
#   - Install PUA or other skills (those live in ~/.claude/skills/, global)

set -euo pipefail

# --- Config -----------------------------------------------------------------
TEMPLATE="${CLAUDE_STARTER_TEMPLATE:-kouok415/claude-starter}"

# --- Parse args -------------------------------------------------------------
if [ $# -lt 1 ] || [ -z "$1" ]; then
  echo "Usage: $0 <project-name>"
  echo ""
  echo "Set CLAUDE_STARTER_TEMPLATE env var to override the template repo"
  echo "(currently: $TEMPLATE)"
  exit 1
fi

PROJECT="$1"

# --- Sanity checks ----------------------------------------------------------
if ! command -v gh >/dev/null 2>&1; then
  echo "Error: gh CLI not found. Run bootstrap-machine.sh first."
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "Error: gh CLI not authenticated. Run: gh auth login"
  exit 1
fi

if [ -e "$PROJECT" ]; then
  echo "Error: ./$PROJECT already exists"
  exit 1
fi

# --- Visibility prompt ------------------------------------------------------
read -rp "Visibility (public/private) [private]: " VIS
VIS="${VIS:-private}"
case "$VIS" in
  public|private) ;;
  *) echo "Error: visibility must be 'public' or 'private'"; exit 1 ;;
esac

# --- Create repo from template ----------------------------------------------
echo "Creating $PROJECT from $TEMPLATE..."
gh repo create "$PROJECT" \
  --template "$TEMPLATE" \
  --"$VIS" \
  --clone

cd "$PROJECT"

# --- Personalize CLAUDE.md --------------------------------------------------
if [ -f CLAUDE.md.template ]; then
  mv CLAUDE.md.template CLAUDE.md
  # macOS/BSD sed needs '' after -i; GNU sed doesn't. Do it portably:
  sed -i.bak "s/{{PROJECT_NAME}}/$PROJECT/g" CLAUDE.md
  rm -f CLAUDE.md.bak
fi

# --- Initial commit ---------------------------------------------------------
git add CLAUDE.md
git commit -m "chore: initialize $PROJECT from claude-starter" --allow-empty
git push

# --- Done -------------------------------------------------------------------
cat <<EOF

✓ Project created: $PROJECT
  Path:    $(pwd)
  Remote:  $(gh repo view --json url -q .url)

Next steps:
  cd $PROJECT
  # 1. Run your language's init (npm init / uv init / cargo init / etc.)
  # 2. Edit CLAUDE.md to fill in stack and commands
  # 3. Open Claude and start working

EOF
