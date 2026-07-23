#!/usr/bin/env bash
#
# start_project.sh — spawn a new project from the claude-starter template.
#
# Usage:
#   ./start_project.sh [options] <project-name>
#
# Options:
#   --public | --private     Repo visibility (default: private; env VISIBILITY)
#   --kind code|research|analysis
#                            Project kind — picks the CLAUDE.md template
#                            (default: code)
#   --template <owner/repo>  Template repo (env CLAUDE_STARTER_TEMPLATE;
#                            default: kouok415/claude-starter)
#   --local                  No GitHub: copy this checkout as the template
#                            and git init locally (offline / testing)
#   -h, --help               Show this help
#
# What it does:
#   1. Creates a new GitHub repo from the template and clones it
#      (or, with --local, copies this checkout's TRACKED content — git
#      archive HEAD — so gitignored local state never leaks into spawns)
#   2. Picks templates/CLAUDE.md.<kind> -> CLAUDE.md, README stub -> README.md
#   3. Fills {{PROJECT_NAME}} / {{DATE}} placeholders
#   4. Removes scaffold-infrastructure files (they belong to the template
#      repo, not to spawned projects)
#   5. Installs pre-commit hooks if available, initial commit (+ push)
#
# What it does NOT do (intentionally):
#   - Install language toolchains (run npm/uv/cargo init yourself after)
#   - Create src/ or any source layout
#
# Prerequisites: gh (authenticated) unless --local. See bootstrap-machine.sh.

set -euo pipefail

# Resolve symlinks first: invoked via a symlink (e.g. /code/start_project.sh),
# the symlink's directory must NOT be mistaken for the template — cp -R of
# that directory would copy everything living beside the link.
src="${BASH_SOURCE[0]}"
while [ -L "$src" ]; do
  dir="$(cd "$(dirname "$src")" && pwd)"
  src="$(readlink "$src")"
  case "$src" in /*) ;; *) src="$dir/$src" ;; esac
done
SCRIPT_DIR="$(cd "$(dirname "$src")" && pwd)"
unset src dir

have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<'EOF'
Usage: ./start_project.sh [options] <project-name>

Options:
  --public | --private     Repo visibility (default: private; env VISIBILITY)
  --kind code|research|analysis
                           Project kind — picks the CLAUDE.md template
                           (default: code)
  --template <owner/repo>  Template repo (env CLAUDE_STARTER_TEMPLATE)
  --local                  No GitHub: copy this checkout, git init only
  -h, --help               This help
EOF
}

# --- Parse args ---------------------------------------------------------------
TEMPLATE="${CLAUDE_STARTER_TEMPLATE:-kouok415/claude-starter}"
VIS="${VISIBILITY:-}"
KIND="code"
LOCAL=0
PROJECT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --public)   VIS="public" ;;
    --private)  VIS="private" ;;
    --kind)     KIND="${2:?--kind needs a value}"; shift ;;
    --template) TEMPLATE="${2:?--template needs a value}"; shift ;;
    --local)    LOCAL=1 ;;
    -h|--help)  usage; exit 0 ;;
    -*)         echo "Error: unknown option: $1"; usage; exit 1 ;;
    *)
      if [ -n "$PROJECT" ]; then
        echo "Error: multiple project names given ('$PROJECT', '$1')"; exit 1
      fi
      PROJECT="$1" ;;
  esac
  shift
done

[ -n "$PROJECT" ] || { usage; exit 1; }

case "$KIND" in
  code|research|analysis) ;;
  *) echo "Error: --kind must be code, research, or analysis"; exit 1 ;;
esac

# --- Validate name (also makes it safe to use in sed below) -------------------
if ! [[ "$PROJECT" =~ ^([A-Za-z0-9._-]+/)?[A-Za-z0-9._-]+$ ]]; then
  echo "Error: invalid project name '$PROJECT'"
  echo "  Allowed: letters, digits, '.', '_', '-', with an optional owner/ prefix."
  exit 1
fi
DIR="${PROJECT##*/}"   # clone directory is the repo basename

# --- Sanity checks -------------------------------------------------------------
if [ -e "$DIR" ]; then
  echo "Error: ./$DIR already exists"
  exit 1
fi

if [ "$LOCAL" = 0 ]; then
  if ! have gh; then
    echo "Error: gh CLI not found. Run bootstrap-machine.sh first (or use --local)."
    exit 1
  fi
  if ! gh auth status >/dev/null 2>&1; then
    echo "Error: gh CLI not authenticated. Run: gh auth login"
    exit 1
  fi
  if gh repo view "$PROJECT" >/dev/null 2>&1; then
    echo "Error: repo already exists on GitHub: $PROJECT"
    exit 1
  fi
else
  if [ "$PWD" = "$SCRIPT_DIR" ]; then
    echo "Error: with --local, run from the parent directory, not inside the template."
    exit 1
  fi
fi

# --- Visibility ----------------------------------------------------------------
if [ "$LOCAL" = 0 ]; then
  if [ -z "$VIS" ]; then
    if [ -t 0 ]; then
      read -rp "Visibility (public/private) [private]: " VIS
    fi
    VIS="${VIS:-private}"
  fi
  case "$VIS" in
    public|private) ;;
    *) echo "Error: visibility must be 'public' or 'private'"; exit 1 ;;
  esac
fi

# --- Failure recovery hint -----------------------------------------------------
CREATED_REMOTE=0
on_err() {
  echo "" >&2
  echo "start_project.sh failed partway." >&2
  if [ "$CREATED_REMOTE" = 1 ]; then
    echo "  The remote repo was already created: $PROJECT" >&2
    echo "  To retry from scratch:" >&2
    echo "    gh repo delete $PROJECT --yes && rm -rf $DIR" >&2
  fi
}
trap on_err ERR

# --- Create --------------------------------------------------------------------
if [ "$LOCAL" = 0 ]; then
  echo "Creating $PROJECT from $TEMPLATE ($VIS)..."
  gh repo create "$PROJECT" \
    --template "$TEMPLATE" \
    --"$VIS" \
    --clone
  CREATED_REMOTE=1
else
  echo "Creating $DIR locally from $SCRIPT_DIR..."
  mkdir "$DIR"
  # Tracked content only (F17): a lived-in checkout carries gitignored local
  # state — .secrets/ credentials (their designed runtime home, v3.8), local
  # settings overrides — which a raw cp -R would ship into the new project,
  # where the inherited ignore rules keep it invisible to git status. git
  # archive copies exactly what HEAD tracks (uncommitted template edits do
  # NOT ride along — commit them first); non-git sources fall back to
  # cp -R plus a purge of the known leak homes.
  if git -C "$SCRIPT_DIR" rev-parse HEAD >/dev/null 2>&1; then
    git -C "$SCRIPT_DIR" archive HEAD | tar -x -C "$DIR"
  else
    cp -R "$SCRIPT_DIR/." "$DIR/"
    rm -rf "$DIR/.git" "$DIR/.claude/settings.local.json" "$DIR/.secrets"
    mkdir -p "$DIR/.secrets" && : > "$DIR/.secrets/.gitkeep"
    find "$DIR/.ai_context/private" -type f ! -name '.gitkeep' -delete 2>/dev/null || true
  fi
  git -C "$DIR" init -q -b main 2>/dev/null || git -C "$DIR" init -q
fi

cd "$DIR"

# --- Personalize -----------------------------------------------------------------
TODAY="$(date +%F)"

# CLAUDE.md from the kind template (fallback: legacy single-template layout).
if [ -f "templates/CLAUDE.md.$KIND" ]; then
  mv "templates/CLAUDE.md.$KIND" CLAUDE.md
elif [ -f CLAUDE.md.template ]; then
  mv CLAUDE.md.template CLAUDE.md
fi

# The template repo's README describes the starter, not the project.
if [ -f templates/README.project.md ]; then
  mv templates/README.project.md README.md
fi

# Fill placeholders. $DIR is sed-safe (validated above); <DATE> kept for
# templates predating the {{DATE}} convention.
for f in CLAUDE.md README.md .ai_context/state.md; do
  [ -f "$f" ] || continue
  sed -i.bak \
    -e "s/{{PROJECT_NAME}}/$DIR/g" \
    -e "s/{{DATE}}/$TODAY/g" \
    -e "s/<DATE>/$TODAY/g" \
    "$f"
  rm -f "$f.bak"
done

# Remove scaffold infrastructure — these belong to the template repo, not to
# the spawned project (GitHub templates have no .templateignore mechanism).
rm -rf start_project.sh bootstrap-machine.sh sync-project.sh \
       MIGRATION.md README.zh-TW.md TUTORIAL.md TUTORIAL.zh-TW.md \
       global templates .github
[ "$KIND" = "analysis" ] || rm -f .mcp.json.example

chmod +x .claude/hooks/*.sh scripts/*.sh 2>/dev/null || true

# Provenance: record which template checkout spawned this project (debugging
# stale-spawner incidents; sync tooling can read the vintage).
STARTER_REF="$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
printf 'spawned-by: claude-starter@%s on %s\n' "$STARTER_REF" "$TODAY" > .claude/.starter-version

# --- pre-commit (mechanical H1/S7 enforcement) -----------------------------------
if have pre-commit && [ -f .pre-commit-config.yaml ]; then
  pre-commit install >/dev/null && echo "pre-commit hooks installed."
fi

# --- Initial commit ---------------------------------------------------------------
git add -A
git commit -q -m "chore: initialize $DIR from claude-starter ($KIND)"
if [ "$LOCAL" = 0 ]; then
  git push -q
fi

# --- Done -------------------------------------------------------------------------
REMOTE_LINE=""
if [ "$LOCAL" = 0 ]; then
  REMOTE_LINE="  Remote:  $(gh repo view --json url -q .url)"
else
  REMOTE_LINE="  Remote:  (none — later: gh repo create $DIR --private --source=. --push)"
fi

cat <<EOF

✓ Project created: $DIR ($KIND)
  Path:    $(pwd)
$REMOTE_LINE

Next steps:
  cd $DIR
  claude   # the first session runs /setup: it interviews you, scaffolds
           # the stack, and drafts CLAUDE.md/README/state.md for your
           # review. (Manual fallback: fill CLAUDE.md yourself; /init helps.)
  # Run /wrap when you stop; /task <description> for big jobs.

EOF
