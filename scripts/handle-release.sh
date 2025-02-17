#!/bin/bash

set -e

echo "//registry.npmjs.org/:_authToken=${NPM_TOKEN}" > ~/.npmrc

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

get_latest_npm_version() {
  PACKAGE_NAME=$1
  npm view $PACKAGE_NAME version 2>/dev/null || echo "none"
}

bump_version() {
  PACKAGE_NAME=$1
  PACKAGE_PATH=$2
  VERSION_BUMP=$3
  CURRENT_VERSION=$(get_latest_npm_version $PACKAGE_NAME)

  if [[ "$CURRENT_VERSION" == "none" ]]; then
    echo "No npm version found for $PACKAGE_NAME. Setting initial version to 1.0.0"
    jq '.version = "1.0.0"' $PACKAGE_PATH/package.json > tmp.json && mv tmp.json $PACKAGE_PATH/package.json
  else
    echo "Latest version on npm for $PACKAGE_NAME is $CURRENT_VERSION"
    yarn workspace $PACKAGE_NAME version --new-version $(npm --no-git-tag-version version $VERSION_BUMP) --deferred
  fi
}

SHARED_PACKAGE="@shanmukh0504/pack-a"
ADMIN_PACKAGE="@shanmukh0504/pack-b"

CHANGED_SHARED=$(git diff --name-only HEAD~1 HEAD | grep "packages/pack-a" || true)
CHANGED_ADMIN=$(git diff --name-only HEAD~1 HEAD | grep "packages/pack-b" || true)

echo "Checking for changes in pack-a and pack-b packages..."

SHARED_PUBLISHED=false

if [[ -n "$CHANGED_SHARED" ]]; then
  echo "Pack-a package has changed. Publishing pack-a."

  bump_version $SHARED_PACKAGE "packages/pack-a" $VERSION_BUMP
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

  bump_version $ADMIN_PACKAGE "packages/pack-b" $VERSION_BUMP
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
