#!/bin/bash

set -e
set -x

COMMIT_EMAIL=$(git log -1 --pretty=format:'%ae')
COMMIT_NAME=$(git log -1 --pretty=format:'%an')

echo "Using committer details - Name: $COMMIT_NAME, Email: $COMMIT_EMAIL"

echo "//registry.npmjs.org/:_authToken=${NPM_TOKEN}" > ~/.npmrc

git fetch --tags

IS_PR=false
if [[ "$GITHUB_EVENT_NAME" == "issue_comment" ]]; then
  IS_PR=true
fi

if [[ $1 == "beta" ]]; then
  VERSION_BUMP="prerelease"
  PRERELEASE_SUFFIX="beta"
else
  LAST_COMMIT_MSG=$(git log -1 --pretty=%B)

  if [[ $LAST_COMMIT_MSG == patch:* ]]; then
    VERSION_BUMP="patch"
  elif [[ $LAST_COMMIT_MSG == chore:* ]]; then
    VERSION_BUMP="patch"
  elif [[ $LAST_COMMIT_MSG == fix:* ]]; then
    VERSION_BUMP="minor"
  elif [[ $LAST_COMMIT_MSG == feat:* ]]; then
    VERSION_BUMP="major"
  else
    echo "Commit message does not match patch, chore, fix, or feat. Skipping publishing."
    exit 0
  fi
fi

echo "Version bump type detected: $VERSION_BUMP"

increment_version() {
  VERSION=$1
  VERSION_TYPE=$2
  IFS='.' read -r -a VERSION_PARTS <<< "$VERSION"
  MAJOR=${VERSION_PARTS[0]}
  MINOR=${VERSION_PARTS[1]}
  PATCH=${VERSION_PARTS[2]}

  if [[ -z "$MAJOR" || -z "$MINOR" || -z "$PATCH" ]]; then
    echo "Invalid version number: $VERSION"
    exit 1
  fi

  case $VERSION_TYPE in
    "major") MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
    "minor") MINOR=$((MINOR + 1)); PATCH=0 ;;
    "patch") PATCH=$((PATCH + 1)) ;;
    "prerelease")
      if [[ $VERSION =~ -beta\.[0-9]+$ ]]; then
        PRERELEASE_NUM=$(( ${VERSION##*-beta.} + 1 ))
      else
        PRERELEASE_NUM=0
      fi
      PRERELEASE="beta.${PRERELEASE_NUM}"
      ;;
    *) echo "Invalid version bump type: $VERSION_TYPE"; exit 1 ;;
  esac

  if [[ $VERSION_TYPE == "prerelease" ]]; then
    echo "${MAJOR}.${MINOR}.${PATCH}-${PRERELEASE}"
  else
    echo "${MAJOR}.${MINOR}.${PATCH}"
  fi
}

export -f increment_version

# Logging each command involved in capturing changed packages
echo "Step 1: Running git diff --name-only main"
git diff --name-only main

echo "Step 2: Filtering changes in 'packages/' directory"
git diff --name-only main | grep "packages/"

echo "Step 3: Excluding 'package.json' files"
git diff --name-only main | grep "packages/" | grep -v "package.json"

echo "Step 4: Extracting package names using awk"
git diff --name-only main | grep "packages/" | grep -v "package.json" | awk -F/ '{print $2}'

echo "Step 5: Sorting and making unique package names"
CHANGED_PACKAGES=$(git diff --name-only main | grep "packages/" | grep -v "package.json" | awk -F/ '{print $2}' | sort | uniq)
echo "Changed packages: $CHANGED_PACKAGES"

# Now continue with the rest of the script as usual
yarn workspaces foreach --topological --all --no-private exec bash -c '
  VERSION_BUMP="'$VERSION_BUMP'"
  PACKAGE_NAME=$(jq -r .name package.json)

  if [[ ! -f "package.json" ]]; then
    echo "Error: package.json not found in $(pwd)"
    exit 1
  fi

  # Check if the package is changed
  if [[ ! " '$CHANGED_PACKAGES' " =~ " $PACKAGE_NAME " ]]; then
    echo "Skipping $PACKAGE_NAME as it is not changed."
    exit 0
  fi

  LATEST_STABLE_VERSION=$(npm view $PACKAGE_NAME version)

  if [[ -z "$LATEST_STABLE_VERSION" ]]; then
    echo "No previous stable tags found for $PACKAGE_NAME, using package.json version"
    LATEST_STABLE_VERSION=$(jq -r .version package.json)
  fi

  echo "Latest stable version for $PACKAGE_NAME: $LATEST_STABLE_VERSION"

  if [[ "$VERSION_BUMP" == "prerelease" ]]; then

    LATEST_BETA_VERSION=$(npm view $PACKAGE_NAME versions --json | jq -r '"'"'[.[] | select(contains("-beta"))] | max // empty'"'"')

    if [[ -n "$LATEST_BETA_VERSION" ]]; then
      BETA_NUMBER=$(echo "$LATEST_BETA_VERSION" | sed -E "s/.*-beta\.([0-9]+)/\1/")
      NEW_VERSION="${LATEST_STABLE_VERSION}-beta.$((BETA_NUMBER + 1))"
    else
      NEW_VERSION="${LATEST_STABLE_VERSION}-beta.0"
    fi

    echo "New beta version for $PACKAGE_NAME: $NEW_VERSION"
  else
    NEW_VERSION=$(increment_version "$LATEST_STABLE_VERSION" "$VERSION_BUMP")
  fi

  echo "Bumping $PACKAGE_NAME from $LATEST_STABLE_VERSION to $NEW_VERSION"

  jq --arg new_version "$NEW_VERSION" ".version = \$new_version" package.json > package.tmp.json && mv package.tmp.json package.json

  if [[ $VERSION_BUMP == "prerelease" ]]; then
    yarn build
    npm publish --tag beta --access public
  else
    if [[ "$IS_PR" != "true" ]]; then
      git add package.json
      git -c user.email="'"$COMMIT_EMAIL"'" \
          -c user.name="'"$COMMIT_NAME"'" \
          commit -m "V$NEW_VERSION"
      
      yarn build
      npm publish --access public
      git tag "$PACKAGE_NAME@$NEW_VERSION"
      git push https://x-access-token:${GH_PAT}@github.com/shanmukh0504/monorepo.git HEAD:main --tags
    else
      echo "Skipping commit since this is a pull request."
    fi
  fi
'

yarn config unset yarnPath
jq 'del(.packageManager)' package.json > temp.json && mv temp.json package.json

if [[ "$IS_PR" != "true" && -n $(git status --porcelain) ]]; then
  git add .
  git -c user.email="$COMMIT_EMAIL" \
      -c user.name="$COMMIT_NAME" \
      commit -m "commit release script and config changes"
  git push https://x-access-token:${GH_PAT}@github.com/shanmukh0504/monorepo.git HEAD:main
fi

rm -f ~/.npmrc
