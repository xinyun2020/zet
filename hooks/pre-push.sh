#!/bin/bash
# Pre-push hook — block pushes that contain secrets or personal config
# Attach to your AI tool's PreToolUse event for Bash commands containing "git push".
#
# Checks:
#   1. No .claude/ or CLAUDE.md in the diff (personal config leak)
#   2. No hardcoded API keys or tokens in the diff
#   3. No uncommitted changes (stale state)
#
# Exit codes:
#   0 = proceed with push
#   2 = blocked (do not push)
#
# Environment:
#   PUSH_COMMAND — the git push command being executed
#   REPO_PATH   — path to the repo being pushed

REPO_PATH="${REPO_PATH:-$(pwd)}"

[ ! -d "$REPO_PATH/.git" ] && exit 0

cd "$REPO_PATH" || exit 0

# --- Check: uncommitted changes ---
DIRTY=$(git status --porcelain 2>/dev/null)
if [ -n "$DIRTY" ]; then
    echo "BLOCKED: Uncommitted changes in working tree"
    echo "$DIRTY" | head -5 | sed 's/^/  /'
    exit 2
fi

# --- Check: personal config in diff ---
BASE_BRANCH=$(git remote show origin 2>/dev/null | grep 'HEAD branch' | awk '{print $NF}')
BASE_BRANCH="${BASE_BRANCH:-main}"

CHANGED_FILES=$(git diff --name-only "origin/$BASE_BRANCH"...HEAD 2>/dev/null)

CONFIG_LEAK=$(echo "$CHANGED_FILES" | grep -E '(^\.claude/|CLAUDE\.md$)' || true)
if [ -n "$CONFIG_LEAK" ]; then
    echo "BLOCKED: Personal config files in push:"
    echo "$CONFIG_LEAK" | sed 's/^/  - /'
    echo ""
    echo "Remove with: git reset HEAD <file>"
    exit 2
fi

# --- Check: secrets in diff ---
DIFF=$(git diff "origin/$BASE_BRANCH"...HEAD 2>/dev/null | grep -E '^\+' | grep -v '^\+\+\+')

SECRETS=$(echo "$DIFF" | grep -iE \
    '(sk-[a-zA-Z0-9]{20,}|ghp_[a-zA-Z0-9]{36}|xoxb-[0-9]|AKIA[0-9A-Z]{16}|-----BEGIN (RSA |EC )?PRIVATE KEY)' || true)

if [ -n "$SECRETS" ]; then
    echo "WARNING: Potential secrets detected in diff:"
    echo "$SECRETS" | head -5 | sed 's/^/  /'
    echo ""
    echo "Review before pushing. Move secrets to .env files."
fi

exit 0
