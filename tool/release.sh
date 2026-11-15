#!/usr/bin/env bash
#
# Cuts a release: bumps pubspec.yaml, prepends a CHANGELOG.md entry, commits
# and tags. It deliberately does NOT build — run tool/build_release.sh
# afterwards, then attach the artifacts and symbols/ to the GitHub release.
#
#   tool/release.sh patch "first note" ["second note" ...]
#   tool/release.sh minor "..."
#   tool/release.sh major "..."
#
# Why this exists:
#
#   1. Before this script, the version number lived in three places that had
#      to be kept in sync by hand: pubspec.yaml, the commit message, and the
#      git tag. Releases 3.4.1, 3.5.x, 3.8.0/3.8.1 and 3.10.1/3.10.2 shipped
#      without tags at all. This script makes the tagged commit the single
#      act of releasing.
#   2. It refuses to run on a dirty tree, so the release commit contains
#      exactly the version bump and changelog entry — nothing accidental.
#   3. The build number (the +N in x.y.z+N) is bumped automatically. Android
#      uses it as versionCode; forgetting it makes installs reject updates.
set -euo pipefail

cd "$(dirname "$0")/.."

usage() {
  echo "usage: tool/release.sh <patch|minor|major|X.Y.Z> \"note\" [\"note\" ...]" >&2
  exit 2
}

[ $# -ge 2 ] || usage
BUMP="$1"; shift
case "$BUMP" in
  patch|minor|major) ;;
  *) [[ "$BUMP" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || usage ;;
esac
NOTES=("$@")

# --- Preflight ---------------------------------------------------------------

if [ -n "$(git status --porcelain)" ]; then
  echo "error: working tree is dirty — commit or stash first, so the release" >&2
  echo "       commit contains only the version bump and changelog entry." >&2
  git status --short >&2
  exit 1
fi

BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$BRANCH" != "main" ] && [ "${ALLOW_BRANCH:-}" != "1" ]; then
  echo "error: on branch '$BRANCH' — releases are cut from main" >&2
  echo "       (set ALLOW_BRANCH=1 to release from here anyway)." >&2
  exit 1
fi

if ! git diff --quiet origin/main main 2>/dev/null; then
  echo "warning: local main differs from origin/main — did you forget to pull/push?" >&2
fi

# --- Version bump ------------------------------------------------------------

VERSION=$(grep '^version:' pubspec.yaml | awk '{print $2}')
SHORT="${VERSION%%+*}"
BUILD="${VERSION##*+}"
MAJOR="${SHORT%%.*}"
REST="${SHORT#*.}"
MINOR="${REST%%.*}"
PATCH="${REST##*.}"

case "$BUMP" in
  major)
    MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0
    NEW_SHORT="$MAJOR.$MINOR.$PATCH"
    NEW_BUILD=$((BUILD + 1))
    ;;
  minor)
    MINOR=$((MINOR + 1)); PATCH=0
    NEW_SHORT="$MAJOR.$MINOR.$PATCH"
    NEW_BUILD=$((BUILD + 1))
    ;;
  patch)
    PATCH=$((PATCH + 1))
    NEW_SHORT="$MAJOR.$MINOR.$PATCH"
    NEW_BUILD=$((BUILD + 1))
    ;;
  *)
    NEW_SHORT="$BUMP"
    # Android refuses an update whose versionCode is not higher than the
    # installed one, whatever the version name says.
    NEW_BUILD=$((BUILD + 1))
    ;;
esac
NEW_VERSION="$NEW_SHORT+$NEW_BUILD"

TAG="v$NEW_SHORT"
if git show-ref --verify --quiet "refs/tags/$TAG"; then
  echo "error: tag v$NEW_SHORT already exists" >&2
  exit 1
fi

ORIGINAL_HEAD=$(git rev-parse HEAD)
RELEASE_COMMIT=""
RELEASE_DIR=$(mktemp -d .release.XXXXXX)
cleanup() {
  local status=$?
  rm -rf -- "$RELEASE_DIR" || true
  if [ "$status" -ne 0 ]; then
    # Roll back our commit only while it is still the branch tip.
    if [ -n "$RELEASE_COMMIT" ]; then
      if ! git update-ref HEAD "$ORIGINAL_HEAD" "$RELEASE_COMMIT"; then
        echo "error: could not roll back release commit $RELEASE_COMMIT" >&2
        exit "$status"
      fi
    fi
    if [ "$(git rev-parse HEAD)" = "$ORIGINAL_HEAD" ]; then
      git restore --source="$ORIGINAL_HEAD" --staged --worktree -- pubspec.yaml CHANGELOG.md
      echo "error: release aborted; version files restored" >&2
    fi
  fi
  exit "$status"
}
trap cleanup EXIT

# sed -i needs a different invocation on macOS; the release machine may be
# either, so branch instead of assuming one platform.
if [ "$(uname)" = "Darwin" ]; then
  sed -i '' "s/^version: .*$/version: $NEW_VERSION/" pubspec.yaml
else
  sed -i "s/^version: .*$/version: $NEW_VERSION/" pubspec.yaml
fi
grep -Fqx "version: $NEW_VERSION" pubspec.yaml || {
  echo "error: failed to update pubspec.yaml" >&2; exit 1; }

# --- Changelog ---------------------------------------------------------------

TODAY=$(date +%F)
{
  printf '## [%s] - %s\n\n' "$NEW_SHORT" "$TODAY"
  for note in "${NOTES[@]}"; do
    printf -- '- %s\n' "$note"
  done
  printf '\n'
} > "$RELEASE_DIR/entry"

# Insert the entry right above the first existing version heading. A
# CHANGELOG.md with no heading is a broken repo state, not an empty one — the
# entry would silently vanish, so fail loudly instead.
awk '
  NR == FNR { entry[++count] = $0; next }
  !done && /^## \[/ {
    for (i = 1; i <= count; i++) print entry[i]
    done = 1
  }
  { print }
  END { if (!done) exit 1 }
' "$RELEASE_DIR/entry" CHANGELOG.md > "$RELEASE_DIR/changelog" || {
  echo "error: no version heading in CHANGELOG.md — cannot place the entry" >&2
  exit 1
}
mv "$RELEASE_DIR/changelog" CHANGELOG.md

# --- Commit + tag ------------------------------------------------------------

FIRST_NOTE="${NOTES[0]}"
git add pubspec.yaml CHANGELOG.md
git commit -m "feat(release): $NEW_SHORT - $FIRST_NOTE"
RELEASE_COMMIT=$(git rev-parse HEAD)
git tag "$TAG" "$RELEASE_COMMIT"
trap - EXIT
rm -rf -- "$RELEASE_DIR"

echo
echo "==> Released $NEW_VERSION (tag v$NEW_SHORT)"
echo
echo "Next steps:"
echo "  git push && git push --tags"
echo "  tool/build_release.sh all"
echo "  # then create the GitHub release for v$NEW_SHORT and attach the APK/IPA/DMG"
echo "  # plus the matching symbols/ directory contents"
