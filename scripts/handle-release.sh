#!/bin/bash

set -e

echo "//registry.npmjs.org/:_authToken=${NPM_TOKEN}" > ~/.npmrc

LAST_COMMIT_MSG=$(git log -1 --pretty=%B)

if [[ $LAST_COMMIT_MSG == patch:* ]]; then
  VERSION_BUMP="patch"
elif [[ $LAST_COMMIT_MSG == fix:* ]]; then
  VERSION_BUMP="patch"
elif [[ $LAST_COMMIT_MSG == feat:* ]]; then
  VERSION_BUMP="minor"
elif [[ $LAST_COMMIT_MSG == major:* ]]; then
  VERSION_BUMP="major"
else
  echo "Commit message does not match patch, fix, feat, or major. Skipping publishing."
  exit 0
fi

echo "Version bump type detected: $VERSION_BUMP"

get_latest_tag() {
  PACKAGE=$1
  git fetch --tags
  LATEST_TAG=$(git tag -l "${PACKAGE}@*" | sed 's/.*@v//' | sed 's/.*@//' | sort -V | tail -n 1)
  echo "$LATEST_TAG"
}

increment_version() {
  VERSION=$1
  VERSION_TYPE=$2
  IFS='.' read -r -a VERSION_PARTS <<< "$VERSION"
  MAJOR=${VERSION_PARTS[0]}
  MINOR=${VERSION_PARTS[1]}
  PATCH=${VERSION_PARTS[2]}

  case $VERSION_TYPE in
    "major") MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
    "minor") MINOR=$((MINOR + 1)); PATCH=0 ;;
    "patch") PATCH=$((PATCH + 1)) ;;
    *) echo "Invalid version bump type: $VERSION_TYPE"; exit 1 ;;
  esac

  echo "${MAJOR}.${MINOR}.${PATCH}"
}

publish_package() {
  PACKAGE=$1
  PACKAGE_DIR=$2

  LATEST_TAG=$(get_latest_tag $PACKAGE)
  if [[ -z "$LATEST_TAG" ]]; then
    CURRENT_VERSION="0.0.0"
  else
    CURRENT_VERSION=${LATEST_TAG#*@}
  fi
  echo "Current version for $PACKAGE is $CURRENT_VERSION"

  NEW_VERSION=$(increment_version $CURRENT_VERSION $VERSION_BUMP)
  echo "New version for $PACKAGE is $NEW_VERSION"

  jq --arg new_version "$NEW_VERSION" '.version = $new_version' "$PACKAGE_DIR/package.json" > "$PACKAGE_DIR/package.tmp.json" && mv "$PACKAGE_DIR/package.tmp.json" "$PACKAGE_DIR/package.json"

  git add "$PACKAGE_DIR/package.json"
  git -c user.email="shanmukh0504@gmail.com" \
      -c user.name="shanmukh0504" \
      commit -m "chore: bump $PACKAGE to version $NEW_VERSION"

  yarn workspace $PACKAGE build
  npm publish --workspace $PACKAGE --access public

  NEW_TAG="${PACKAGE}@${NEW_VERSION}"
  git tag "$NEW_TAG"
  git push https://x-access-token:${GH_PAT}@github.com/shanmukh0504/monorepo.git HEAD:main
  git push https://x-access-token:${GH_PAT}@github.com/shanmukh0504/monorepo.git "$NEW_TAG"

  echo "Published $PACKAGE@$NEW_VERSION"
}

if [[ -n $(git diff --name-only HEAD~1 HEAD | grep "packages/pack-a") ]]; then
  publish_package "@shanmukh0504/pack-a" "packages/pack-a"
  publish_package "@shanmukh0504/pack-b" "packages/pack-b"
fi

if [[ -n $(git diff --name-only HEAD~1 HEAD | grep "packages/pack-b") ]]; then
  publish_package "@shanmukh0504/pack-b" "packages/pack-b"
fi

yarn config unset yarnPath

yarn config set enablePackageManagerField false

# Commit and push any remaining changes
if [[ -n $(git status --porcelain) ]]; then
  git add .
  git -c user.email="shanmukh0504@gmail.com" \
      -c user.name="shanmukh0504" \
      commit -m "chore: commit release script and config changes"
  git push https://x-access-token:${GH_PAT}@github.com/shanmukh0504/monorepo.git HEAD:main
fi

rm -f ~/.npmrc
