#!/bin/bash

set -e
set -x

COMMIT_EMAIL=$(git log -1 --pretty=format:'%ae')
COMMIT_NAME=$(git log -1 --pretty=format:'%an')

echo "Using committer details - Name: $COMMIT_NAME, Email: $COMMIT_EMAIL"

# Generate .npmrc file for NPM authentication
echo "//registry.npmjs.org/:_authToken=${NPM_TOKEN}" > ~/.npmrc

# Fetch tags from git
git fetch --tags

# Determine if the event is a pull request
IS_PR=false
if [[ "$GITHUB_EVENT_NAME" == "issue_comment" ]]; then
  IS_PR=true
fi

# Determine the version bump type based on the argument or commit message
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

# Function to increment version based on the bump type
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

# Identify affected packages based on the latest commit
AFFECTED_PACKAGES=$(yarn workspaces foreach --all --topological --no-private exec bash -c '
  PACKAGE_NAME=$(jq -r .name package.json)
  git diff --name-only HEAD~1 HEAD | grep "$PACKAGE_NAME" || true
')

# Identify the dependency tree of the affected packages
# This function generates a topological sort order based on dependencies
generate_dependency_order() {
  local affected_packages=($1)
  local dependency_order=()
  local visited=()

  while [[ ${#affected_packages[@]} -gt 0 ]]; do
    PACKAGE=${affected_packages[0]}
    if [[ " ${visited[@]} " =~ " ${PACKAGE} " ]]; then
      # Skip if already processed
      affected_packages=("${affected_packages[@]:1}")
      continue
    fi
    visited+=("$PACKAGE")

    # Find dependencies of the package
    DEPENDENCIES=$(jq -r '.dependencies | keys[]' "packages/$PACKAGE/package.json" || true)
    
    for DEP in $DEPENDENCIES; do
      if [[ ! " ${visited[@]} " =~ " ${DEP} " ]] && [[ ! " ${dependency_order[@]} " =~ " ${DEP} " ]]; then
        dependency_order+=("$DEP")
      fi
    done

    # Add package to the dependency order
    dependency_order+=("$PACKAGE")
    affected_packages=("${affected_packages[@]:1}")
  done
  echo "${dependency_order[@]}"
}

# Resolve dependency order for the affected packages
DEPENDENCY_ORDER=$(generate_dependency_order "$AFFECTED_PACKAGES")

# Publish affected packages in the correct order
for PACKAGE in $DEPENDENCY_ORDER; do
  echo "Publishing $PACKAGE"
  
  # Check if package exists
  PACKAGE_PATH="packages/$PACKAGE/package.json"
  if [[ ! -f "$PACKAGE_PATH" ]]; then
    echo "Error: package.json not found in $PACKAGE_PATH"
    exit 1
  fi
  
  PACKAGE_NAME=$(jq -r .name "$PACKAGE_PATH")
  LATEST_STABLE_VERSION=$(npm view "$PACKAGE_NAME" version)

  if [[ -z "$LATEST_STABLE_VERSION" ]]; then
    echo "No previous stable tags found for $PACKAGE_NAME, using package.json version"
    LATEST_STABLE_VERSION=$(jq -r .version "$PACKAGE_PATH")
  fi

  echo "Latest stable version for $PACKAGE_NAME: $LATEST_STABLE_VERSION"

  if [[ "$VERSION_BUMP" == "prerelease" ]]; then
    LATEST_BETA_VERSION=$(npm view "$PACKAGE_NAME" versions --json | jq -r '[.[] | select(contains("-beta"))] | max // empty')
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
  jq --arg new_version "$NEW_VERSION" ".version = \$new_version" "$PACKAGE_PATH" > "$PACKAGE_PATH.tmp" && mv "$PACKAGE_PATH.tmp" "$PACKAGE_PATH"

  if [[ $VERSION_BUMP == "prerelease" ]]; then
    yarn build --cwd "$PACKAGE_PATH"
    npm publish --tag beta --access public
  else
    if [[ "$IS_PR" != "true" ]]; then
      git add "$PACKAGE_PATH"
      git -c user.email="'"$COMMIT_EMAIL"'" \
          -c user.name="'"$COMMIT_NAME"'" \
          commit -m "V$NEW_VERSION"
      
      yarn build --cwd "$PACKAGE_PATH"
      npm publish --access public
      git tag "$PACKAGE_NAME@$NEW_VERSION"
      git push https://x-access-token:${GH_PAT}@github.com/shanmukh0504/monorepo.git HEAD:main --tags
    else
      echo "Skipping commit since this is a pull request."
    fi
  fi
done

# Clean up yarn configuration
yarn config unset yarnPath
jq 'del(.packageManager)' package.json > temp.json && mv temp.json package.json

# Commit and push any changes to package.json
if [[ "$IS_PR" != "true" && -n $(git status --porcelain) ]]; then
  git add .
  git -c user.email="$COMMIT_EMAIL" \
      -c user.name="$COMMIT_NAME" \
      commit -m "commit release script and config changes"
  git push https://x-access-token:${GH_PAT}@github.com/shanmukh0504/monorepo.git HEAD:main
fi

# Clean up .npmrc
rm -f ~/.npmrc
