#!/bin/bash

set -e

# Set up .npmrc for publishing
echo "//registry.npmjs.org/:_authToken=${NPM_TOKEN}" > ~/.npmrc

# Determine the version bump based on the latest commit message
LAST_COMMIT_MSG=$(git log -1 --pretty=%B)

if [[ $LAST_COMMIT_MSG == patch:* ]]; then
  VERSION_BUMP="patch"
elif [[ $LAST_COMMIT_MSG == fix:* ]]; then
  VERSION_BUMP="minor"
elif [[ $LAST_COMMIT_MSG == feat:* ]]; then
  VERSION_BUMP="major"
else
  echo "Commit message does not match patch, fix, or feat. Skipping publishing."
  exit 0
fi

echo "Version bump type detected: $VERSION_BUMP"

# Get the latest tag for a specific package
get_latest_tag() {
  PACKAGE_NAME=$1
  git tag -l "${PACKAGE_NAME}@*" | sort -V | tail -n 1
}

# Compare changes from the last tag for a specific package
has_changes() {
  PACKAGE_PATH=$1
  LAST_TAG=$2
  if [[ -n "$LAST_TAG" ]]; then
    git diff --name-only "$LAST_TAG" HEAD | grep "$PACKAGE_PATH" || true
  else
    echo "changed"
  fi
}

SHARED_PACKAGE="@shanmukh0504/pack-a"
ADMIN_PACKAGE="@shanmukh0504/pack-b"

LAST_SHARED_TAG=$(get_latest_tag $SHARED_PACKAGE)
LAST_ADMIN_TAG=$(get_latest_tag $ADMIN_PACKAGE)

CHANGED_SHARED=$(has_changes "packages/pack-a" "$LAST_SHARED_TAG")
CHANGED_ADMIN=$(has_changes "packages/pack-b" "$LAST_ADMIN_TAG")

echo "Checking for changes in pack-a and admin packages..."

SHARED_PUBLISHED=false

# Publish shared package if changed
if [[ -n "$CHANGED_SHARED" ]]; then
  echo "Pack-a package has changed. Publishing pack-a."

  yarn workspace $SHARED_PACKAGE version $VERSION_BUMP
  yarn workspace $SHARED_PACKAGE build
  npm publish --workspace $SHARED_PACKAGE --access public
  
  # Tag the new shared version
  NEW_SHARED_VERSION=$(node -p "require('./packages/pack-a/package.json').version")
  NEW_SHARED_TAG="${SHARED_PACKAGE}@${NEW_SHARED_VERSION}"
  git tag "$NEW_SHARED_TAG"
  git push origin "$NEW_SHARED_TAG"

  SHARED_PUBLISHED=true
fi

# Publish pack-b package if changed or if pack-a was published
if [[ -n "$CHANGED_ADMIN" ]] || [[ "$SHARED_PUBLISHED" == true ]]; then
  echo "Pack-b package has changed or pack-a was published. Publishing pack-b."

  yarn workspace $ADMIN_PACKAGE version $VERSION_BUMP
  yarn workspace $ADMIN_PACKAGE build
  npm publish --workspace $ADMIN_PACKAGE --access public

  # Tag the new pack-b version
  NEW_ADMIN_VERSION=$(node -p "require('./packages/pack-b/package.json').version")
  NEW_ADMIN_TAG="${ADMIN_PACKAGE}@${NEW_ADMIN_VERSION}"
  git tag "$NEW_ADMIN_TAG"
  git push origin "$NEW_ADMIN_TAG"
fi

echo "Publishing process completed successfully."

# Clean up npmrc
rm -f ~/.npmrc
