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

get_latest_tag() {
  PACKAGE_NAME=$1
  LATEST_TAG=$(git tag -l "${PACKAGE_NAME}@*" | sort -V | tail -n 1)
  if [[ -z "$LATEST_TAG" ]]; then
    echo "none"
  else
    echo "$LATEST_TAG"
  fi
}

get_latest_npm_version() {
  PACKAGE_NAME=$1
  npm view $PACKAGE_NAME version 2>/dev/null || echo "none"
}

has_changes() {
  PACKAGE_PATH=$1
  LAST_TAG=$2
  if [[ "$LAST_TAG" == "none" ]]; then
    echo "changed"
  else
    git diff --name-only "$LAST_TAG" HEAD | grep "$PACKAGE_PATH" || true
  fi
}

bump_version() {
  PACKAGE_NAME=$1
  VERSION_BUMP=$2
  NPM_VERSION=$(get_latest_npm_version $PACKAGE_NAME)
  
  if [[ "$NPM_VERSION" == "none" ]]; then
    echo "1.0.0"
  else
    yarn version $VERSION_BUMP --deferred
  fi
}

SHARED_PACKAGE="@shanmukh0504/pack-a"
ADMIN_PACKAGE="@shanmukh0504/pack-b"

LAST_SHARED_TAG=$(get_latest_tag $SHARED_PACKAGE)
LAST_ADMIN_TAG=$(get_latest_tag $ADMIN_PACKAGE)

CHANGED_SHARED=$(has_changes "packages/pack-a" "$LAST_SHARED_TAG")
CHANGED_ADMIN=$(has_changes "packages/pack-b" "$LAST_ADMIN_TAG")

echo "Checking for changes in pack-a and pack-b packages..."

SHARED_PUBLISHED=false

if [[ -n "$CHANGED_SHARED" ]]; then
  echo "Pack-a package has changed. Publishing pack-a."

  bump_version $SHARED_PACKAGE $VERSION_BUMP
  yarn version apply
  yarn workspace $SHARED_PACKAGE build
  npm publish --workspace $SHARED_PACKAGE --access public
  
  NEW_SHARED_VERSION=$(node -p "require('./packages/pack-a/package.json').version")
  NEW_SHARED_TAG="${SHARED_PACKAGE}@${NEW_SHARED_VERSION}"
  git tag "$NEW_SHARED_TAG"
  git push origin "$NEW_SHARED_TAG"

  SHARED_PUBLISHED=true
fi

if [[ -n "$CHANGED_ADMIN" ]] || [[ "$SHARED_PUBLISHED" == true ]]; then
  echo "Pack-b package has changed or pack-a was published. Publishing pack-b."

  bump_version $ADMIN_PACKAGE $VERSION_BUMP
  yarn version apply
  yarn workspace $ADMIN_PACKAGE build
  npm publish --workspace $ADMIN_PACKAGE --access public

  NEW_ADMIN_VERSION=$(node -p "require('./packages/pack-b/package.json').version")
  NEW_ADMIN_TAG="${ADMIN_PACKAGE}@${NEW_ADMIN_VERSION}"
  git tag "$NEW_ADMIN_TAG"
  git push origin "$NEW_ADMIN_TAG"
fi

echo "Publishing process completed successfully."

rm -f ~/.npmrc
