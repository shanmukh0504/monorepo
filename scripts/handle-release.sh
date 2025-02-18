#!/bin/bash

set -e

corepack enable
corepack install

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

yarn workspaces foreach --topological --no-private exec bash -c '
  PACKAGE_NAME=$(jq -r .name package.json)
  CURRENT_VERSION=$(jq -r .version package.json)
  NEW_VERSION=$(increment_version $CURRENT_VERSION '$VERSION_BUMP')

  echo "Bumping $PACKAGE_NAME from $CURRENT_VERSION to $NEW_VERSION"

  jq --arg new_version "$NEW_VERSION" ".version = \$new_version" package.json > package.tmp.json && mv package.tmp.json package.json

  git add package.json
  git -c user.email="shanmukh0504@gmail.com" \
      -c user.name="shanmukh0504" \
      commit -m "chore: bump $PACKAGE_NAME to version $NEW_VERSION"

  yarn build
  npm publish --access public

  git tag "$PACKAGE_NAME@$NEW_VERSION"
'

git push https://x-access-token:${GH_PAT}@github.com/shanmukh0504/monorepo.git HEAD:main --tags

yarn config unset yarnPath
jq 'del(.packageManager)' package.json > temp.json && mv temp.json package.json

if [[ -n $(git status --porcelain) ]]; then
  git add .
  git -c user.email="shanmukh0504@gmail.com" \
      -c user.name="shanmukh0504" \
      commit -m "chore: commit release script and config changes"
  git push https://x-access-token:${GH_PAT}@github.com/shanmukh0504/monorepo.git HEAD:main
fi

rm -f ~/.npmrc
