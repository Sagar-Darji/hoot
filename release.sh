#!/bin/bash
# Ships a new version of Hoot:
#
#   ./release.sh            # 1.2.3 → 1.2.4   (fixes)
#   ./release.sh minor      # 1.2.3 → 1.3.0   (new features)
#   ./release.sh major      # 1.2.3 → 2.0.0
#   ./release.sh 1.4.0      # an exact version
#
# It bumps VERSION, adds a CHANGELOG entry from the commits since the last release, commits and tags,
# builds and signs the app, packages the .dmg, pushes, and publishes a GitHub release with the .dmg
# attached as "Hoot.dmg" — the file the website's Download button and Hoot's update check point at.
#
# Needs: a clean working tree, the GitHub CLI (`gh auth login`), and Homebrew's whisper-cpp
# (the speech engine bundled into the app).
set -euo pipefail
cd "$(dirname "$0")"

die() { echo "error: $*" >&2; exit 1; }

command -v gh >/dev/null || die "install the GitHub CLI first: brew install gh"
[[ -z "$(git status --porcelain)" ]] || die "commit or stash your changes first"
git rev-parse --abbrev-ref HEAD | grep -qx main || die "release from the main branch"

current=$(tr -d '[:space:]' < VERSION)
IFS=. read -r major minor patch <<< "$current"
case "${1:-patch}" in
  patch) next="$major.$minor.$((patch + 1))" ;;
  minor) next="$major.$((minor + 1)).0" ;;
  major) next="$((major + 1)).0.0" ;;
  *) [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "usage: ./release.sh [patch|minor|major|X.Y.Z]"; next="$1" ;;
esac
git rev-parse -q --verify "refs/tags/v$next" >/dev/null && die "v$next already exists"

previous=$(git describe --tags --abbrev=0 2>/dev/null || true)
notes=$(git log ${previous:+$previous..}HEAD --no-merges --pretty='- %s' | grep -v '^- Release v' || true)
[[ -n "$notes" ]] || notes="- Maintenance release"

echo "Releasing Hoot $next (was $current)"
echo "$next" > VERSION
{
  echo "## $next — $(date +%Y-%m-%d)"
  echo
  echo "$notes"
  echo
  [[ -f CHANGELOG.md ]] && cat CHANGELOG.md
} > CHANGELOG.md.new
mv CHANGELOG.md.new CHANGELOG.md
git add VERSION CHANGELOG.md
git commit -q -m "Release v$next"
git tag -a "v$next" -m "Hoot $next"

./package.sh
cp "dist/Hoot-$next.dmg" dist/Hoot.dmg

git push -q origin main
git push -q origin "v$next"
gh release create "v$next" "dist/Hoot-$next.dmg" dist/Hoot.dmg \
  --title "Hoot $next" \
  --notes "$notes

**Install:** download **Hoot.dmg**, open it and drag Hoot to Applications. Needs a Mac with Apple Silicon and macOS 26 or later."
echo "Published: $(gh release view "v$next" --json url --jq .url)"
