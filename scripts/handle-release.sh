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

# Get the latest tag for a package
get_latest_tag() {
  PACKAGE=$1
  git tag -l "${PACKAGE}@*" | sort -V | tail -n 1
}

publish_package() {
  PACKAGE=$1
  PACKAGE_DIR=$2

  LATEST_TAG=$(get_latest_tag $PACKAGE)
  echo "Latest tag for $PACKAGE is $LATEST_TAG"

  yarn workspace $PACKAGE version $VERSION_BUMP --deferred
  yarn version apply
  yarn workspace $PACKAGE build
  npm publish --workspace $PACKAGE --access public --force

  NEW_VERSION=$(node -p "require('./$PACKAGE_DIR/package.json').version")
  NEW_TAG="${PACKAGE}@${NEW_VERSION}"

  git tag "$NEW_TAG"
  git push origin "$NEW_TAG"

  echo "Published $PACKAGE@$NEW_VERSION"
}

if [[ -n $(git diff --name-only HEAD~1 HEAD | grep "packages/pack-a") ]]; then
  publish_package "@shanmukh0504/pack-a" "packages/pack-a"
  publish_package "@shanmukh0504/pack-b" "packages/pack-b"
fi

if [[ -n $(git diff --name-only HEAD~1 HEAD | grep "packages/pack-b") ]]; then
  publish_package "@shanmukh0504/pack-b" "packages/pack-b"
fi

rm -f ~/.npmrc
