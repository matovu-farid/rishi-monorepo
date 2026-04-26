#!/usr/bin/env bash
set -euo pipefail

PACKAGE_JSON="apps/rishi-electron/package.json"

usage() {
  cat <<EOF
Usage: ./scripts/release.sh <version> [release-notes]

  version        Semver version (e.g. 1.2.0). The "v" prefix is added automatically.
  release-notes  Optional release notes string. If omitted, opens \$EDITOR.

Examples:
  ./scripts/release.sh 1.2.0
  ./scripts/release.sh 1.3.0 "Added dark mode and fixed PDF rendering"
EOF
  exit 1
}

[[ $# -lt 1 ]] && usage

VERSION="$1"
NOTES="${2:-}"
TAG="v${VERSION}"

# Validate version format
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Error: Version must be semver (e.g. 1.2.0), got: $VERSION"
  exit 1
fi

# Must be on main
BRANCH=$(git branch --show-current)
if [[ "$BRANCH" != "main" ]]; then
  echo "Error: Must be on main branch (currently on $BRANCH)"
  exit 1
fi

# Working tree must be clean
if [[ -n "$(git diff --cached --name-only)" ]]; then
  echo "Error: Staged changes exist. Commit or stash them first."
  exit 1
fi

# Tag must not already exist
if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "Error: Tag $TAG already exists"
  exit 1
fi

# Pull latest
echo "Pulling latest main..."
git pull origin main --ff-only

# Read current version
OLD_PKG=$(grep '"version"' "$PACKAGE_JSON" | head -1 | sed 's/.*"\([0-9.]*\)".*/\1/')
echo "Current version: package.json=$OLD_PKG"
echo "Bumping to: $VERSION"

# Bump version
sed -i '' "s/\"version\": \"$OLD_PKG\"/\"version\": \"$VERSION\"/" "$PACKAGE_JSON"

# Verify bump worked
NEW_PKG=$(grep '"version"' "$PACKAGE_JSON" | head -1 | sed 's/.*"\([0-9.]*\)".*/\1/')
if [[ "$NEW_PKG" != "$VERSION" ]]; then
  echo "Error: Version bump failed (package=$NEW_PKG)"
  git checkout -- "$PACKAGE_JSON"
  exit 1
fi

# Commit and push
git add "$PACKAGE_JSON"
git commit -m "chore(release): bump version to $VERSION"
echo "Pushing to main..."
git push origin main

# Create release
if [[ -n "$NOTES" ]]; then
  gh release create "$TAG" --target main --title "$TAG" --notes "$NOTES"
else
  gh release create "$TAG" --target main --title "$TAG"
fi

echo ""
echo "Release $TAG created: https://github.com/$(gh repo view --json nameWithOwner -q .nameWithOwner)/releases/tag/$TAG"
