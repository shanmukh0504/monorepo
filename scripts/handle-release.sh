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

# Get changes against the main branch
AFFECTED_FILES=$(git diff --name-only origin/main)
AFFECTED_PACKAGES=()

# Identify affected packages based on changed files
for FILE in $AFFECTED_FILES; do
  if [[ "$FILE" =~ ^packages/(.*)/package.json ]]; then
    PACKAGE_NAME="${BASH_REMATCH[1]}"
    AFFECTED_PACKAGES+=("$PACKAGE_NAME")
  fi
done

# Build a dependency graph
declare -A DEPENDENCY_GRAPH
for PACKAGE in "${AFFECTED_PACKAGES[@]}"; do
  DEPENDENCIES=$(jq -r '.dependencies | keys | .[]' "packages/$PACKAGE/package.json")
  for DEP in $DEPENDENCIES; do
    DEPENDENCY_GRAPH["$DEP"]="$PACKAGE"
  done
done

# Topologically sort the affected packages to determine the publishing order
PUBLISH_ORDER=()
VISITED=()

function topological_sort() {
  local NODE=$1
  if [[ -z "${VISITED[$NODE]}" ]]; then
    VISITED[$NODE]=1
    DEPENDENCIES=$(jq -r '.dependencies | keys | .[]' "packages/$NODE/package.json")
    for DEP in $DEPENDENCIES; do
      topological_sort "$DEP"
    done
    PUBLISH_ORDER+=("$NODE")
  fi
}

# Perform DFS for each affected package
for PACKAGE in "${AFFECTED_PACKAGES[@]}"; do
  topological_sort "$PACKAGE"
done

# Loop through packages to bump versions and publish them
for PACKAGE in "${PUBLISH_ORDER[@]}"; do
  VERSION_BUMP="${VERSION_BUMP}"
  PACKAGE_NAME=$PACKAGE
  LATEST_STABLE_VERSION=$(npm view $PACKAGE_NAME version)

  if [[ -z "$LATEST_STABLE_VERSION" ]]; then
    echo "No previous stable tags found for $PACKAGE_NAME, using package.json version"
    LATEST_STABLE_VERSION=$(jq -r .version "packages/$PACKAGE_NAME/package.json")
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

  jq --arg new_version "$NEW_VERSION" ".version = \$new_version" "packages/$PACKAGE_NAME/package.json" > package.tmp.json && mv package.tmp.json "packages/$PACKAGE_NAME/package.json"

  if [[ $VERSION_BUMP == "prerelease" ]]; then
    yarn build --cwd "packages/$PACKAGE_NAME"
    npm publish --tag beta --access public --cwd "packages/$PACKAGE_NAME"
  else
    if [[ "$IS_PR" != "true" ]]; then
      git add "packages/$PACKAGE_NAME/package.json"
      git -c user.email="'"$COMMIT_EMAIL"'" \
          -c user.name="'"$COMMIT_NAME"'" \
          commit -m "V$NEW_VERSION"
      
      yarn build --cwd "packages/$PACKAGE_NAME"
      npm publish --access public --cwd "packages/$PACKAGE_NAME"
      git tag "$PACKAGE_NAME@$NEW_VERSION"
      git push https://x-access-token:${GH_PAT}@github.com/shanmukh0504/monorepo.git HEAD:main --tags
    else
      echo "Skipping commit since this is a pull request."
    fi
  fi
done

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
