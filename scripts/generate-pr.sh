#!/usr/bin/env sh
#
# Generates a pull-request description from the current branch's diff using the
# Claude CLI, then creates or updates the GitHub PR via `gh`.
#
# Invoked from .husky/pre-push. Designed to NEVER block a push: any failure
# prints a warning and exits 0.
#
# Output sections produced:
#   - "## Changes"            documenting the specific changes
#   - "## Testing Instructions" step-by-step for the PR reviewer

BASE_BRANCH="main"

# --- helpers ---------------------------------------------------------------
warn() { printf '\033[33m[pr-gen]\033[0m %s\n' "$1" >&2; }
info() { printf '\033[36m[pr-gen]\033[0m %s\n' "$1" >&2; }

# Resolve the Claude CLI (may not be on PATH inside a git hook shell).
find_claude() {
  if command -v claude >/dev/null 2>&1; then command -v claude; return 0; fi
  for p in "$HOME/.claude/local/claude" "$HOME/.local/bin/claude" \
           /opt/homebrew/bin/claude /usr/local/bin/claude; do
    [ -x "$p" ] && { echo "$p"; return 0; }
  done
  return 1
}

# --- guards ----------------------------------------------------------------
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
[ -z "$BRANCH" ] && { warn "not on a branch; skipping PR generation"; exit 0; }
if [ "$BRANCH" = "$BASE_BRANCH" ] || [ "$BRANCH" = "master" ] || [ "$BRANCH" = "HEAD" ]; then
  exit 0
fi

# Prefer origin/<base> as the comparison point; fall back to local base ref.
if git rev-parse --verify --quiet "origin/$BASE_BRANCH" >/dev/null; then
  BASE_REF="origin/$BASE_BRANCH"
elif git rev-parse --verify --quiet "$BASE_BRANCH" >/dev/null; then
  BASE_REF="$BASE_BRANCH"
else
  warn "no '$BASE_BRANCH' ref found; skipping PR generation"; exit 0
fi

# Anything to describe?
COMMIT_COUNT="$(git rev-list --count "$BASE_REF..HEAD" 2>/dev/null || echo 0)"
[ "$COMMIT_COUNT" = "0" ] && { info "no commits ahead of $BASE_REF; skipping"; exit 0; }

CLAUDE_BIN="$(find_claude)" || { warn "claude CLI not found; skipping PR generation"; exit 0; }

# --- gather context --------------------------------------------------------
COMMITS="$(git log --format='- %s' "$BASE_REF..HEAD")"
FILESTAT="$(git diff --stat "$BASE_REF...HEAD")"
# Cap the unified diff so the prompt stays a sane size.
DIFF="$(git diff "$BASE_REF...HEAD" | head -c 60000)"

PROMPT="$(cat <<EOF
You are writing a GitHub pull request description. Based on the git data below,
output GitHub-flavored markdown with EXACTLY these two H2 sections and nothing
else (no preamble, no title, no code fences around the whole thing):

## Changes
A bullet list documenting the specific, concrete changes in this PR. Group
related changes. Be specific about files/features touched; skip trivia.

## Testing Instructions
A numbered list of steps a reviewer should follow to verify these changes,
including any setup, the exact flows to exercise, and what correct behavior
looks like.

--- COMMITS ---
$COMMITS

--- FILES CHANGED ---
$FILESTAT

--- DIFF (may be truncated) ---
$DIFF
EOF
)"

info "generating PR description with Claude for '$BRANCH'..."
# `env -u CLAUDECODE` lets this run even if the push is triggered from inside a
# Claude Code session (which otherwise refuses to launch a nested CLI).
BODY="$(printf '%s' "$PROMPT" | env -u CLAUDECODE "$CLAUDE_BIN" -p 2>/dev/null)"

if [ -z "$BODY" ]; then
  warn "Claude returned no output; skipping PR update"; exit 0
fi

GITDIR="$(git rev-parse --git-dir)"
BODY_FILE="$GITDIR/PR_DESCRIPTION.md"
printf '%s\n' "$BODY" > "$BODY_FILE"
info "PR description written to $BODY_FILE"
printf '\n%s\n\n' "$BODY" >&2

# --- push to GitHub via gh (background: branch must land on remote first) ---
if ! command -v gh >/dev/null 2>&1; then
  warn "gh CLI not installed — PR body was NOT pushed to GitHub."
  warn "Install it (brew install gh && gh auth login), then re-push, or paste"
  warn "the description above into your PR manually."
  exit 0
fi

TITLE="$(git log -1 --format='%s' HEAD)"

# The remote branch does not exist yet at pre-push time; wait for the push to
# complete, then create or update the PR. Detach so the push isn't blocked.
(
  i=0
  while [ "$i" -lt 60 ]; do
    if git ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1; then
      break
    fi
    i=$((i + 1))
    sleep 1
  done

  if gh pr view "$BRANCH" >/dev/null 2>&1; then
    gh pr edit "$BRANCH" --body-file "$BODY_FILE" \
      && info "updated existing PR body for '$BRANCH'"
  else
    gh pr create --base "$BASE_BRANCH" --head "$BRANCH" \
      --title "$TITLE" --body-file "$BODY_FILE" \
      && info "opened PR for '$BRANCH'"
  fi
) >>"$GITDIR/pr-gen.log" 2>&1 &

info "PR create/update running in the background (see $GITDIR/pr-gen.log)."
exit 0
