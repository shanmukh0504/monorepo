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

# Compare changes from the last tag
LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
if [[ -n "$LAST_TAG" ]]; then
  CHANGED_SHARED=$(git diff --name-only "$LAST_TAG" HEAD | grep "packages/pack-a" || true)
  CHANGED_ADMIN=$(git diff --name-only "$LAST_TAG" HEAD | grep "packages/pack-b" || true)
else
  # If no tag exists, assume all packages need publishing
  CHANGED_SHARED="changed"
  CHANGED_ADMIN="changed"
fi


# Function to get the latest published version of a package from npm
get_latest_version() {
  PACKAGE_NAME=$1
  npm view "$PACKAGE_NAME" version 2>/dev/null || echo "0.0.0"
}

# Function to increment the version based on the bump type
increment_version() {
  CURRENT_VERSION=$1
  BUMP_TYPE=$2
  npx semver "$CURRENT_VERSION" -i "$BUMP_TYPE"
}

echo "Checking for changes in pack-a and pack-b packages..."

SHARED_PUBLISHED=false

if [[ -n "$CHANGED_SHARED" ]]; then
  echo "pack-a package has changed. Publishing pack-a."

  CURRENT_VERSION=$(get_latest_version "@shanmukh0504/pack-a")
  NEW_VERSION=$(increment_version "$CURRENT_VERSION" "$VERSION_BUMP")

  yarn workspace @shanmukh0504/pack-a version --new-version "$NEW_VERSION"
  yarn workspace @shanmukh0504/pack-a build
  npm publish --workspace @shanmukh0504/pack-a --access public
  
  SHARED_PUBLISHED=true
fi

if [[ -n "$CHANGED_ADMIN" ]] || [[ "$SHARED_PUBLISHED" == true ]]; then
  echo "pack-b package has changed or pack-a was published. Publishing pack-b."

  CURRENT_VERSION=$(get_latest_version "@shanmukh0504/pack-b")
  NEW_VERSION=$(increment_version "$CURRENT_VERSION" "$VERSION_BUMP")

  yarn workspace @shanmukh0504/pack-b version --new-version "$NEW_VERSION"
  yarn workspace @shanmukh0504/pack-b build
  npm publish --workspace @shanmukh0504/pack-b --access public
fi

echo "Publishing process completed successfully."
