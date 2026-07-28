#!/usr/bin/env bash
#
# Safe one-way sync from official Nightscout/Trio into your private fork.
# Never pushes anything back to Nightscout.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "🔄  Trio Nightscout one-way sync"
echo "=================================="
echo "Repo:  $(git remote get-url origin)"
echo "Branch: $(git branch --show-current)"
echo

# 1. Fetch the latest from Nightscout
echo "📥  Fetching upstream (nightscout/Trio)..."
git fetch upstream

# 2. Show what would be merged
echo
echo "📋  Commits that will be merged from upstream:"
git log --oneline --graph --decorate --color=always \
    "$(git branch --show-current)..upstream/main" | head -20 || true

echo
read -r -p "Proceed with merge? [y/N] " reply
if [[ ! "$reply" =~ ^[Yy]$ ]]; then
    echo "❌  Aborted by user."
    exit 1
fi

# 3. Merge (never push to upstream)
echo
echo "🔀  Merging upstream/main into $(git branch --show-current)..."
git merge upstream/main --no-edit --no-ff || {
    echo "⚠️  Merge conflict detected. Resolve conflicts, then run:"
    echo "    git commit"
    exit 1
}

# 4. Push only to your private fork
echo
echo "🚀  Pushing to your fork (origin)..."
git push origin "$(git branch --show-current)"

echo
echo "✅  Sync complete. Your fork is now up-to-date with Nightscout."
echo "   Nothing was pushed to the public Nightscout repository."