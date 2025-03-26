#!/bin/bash

set -e
set -x

# Get committer's details
COMMIT_EMAIL=$(git log -1 --pretty=format:'%ae')
COMMIT_NAME=$(git log -1 --pretty=format:'%an')

echo "Using committer details - Name: $COMMIT_NAME, Email: $COMMIT_EMAIL"

echo "//registry.npmjs.org/:_authToken=${NPM_TOKEN}" > ~/.npmrc

git fetch --tags

IS_PR=false
if [[ "$GITHUB_EVENT_NAME" == "issue_comment" ]]; then
  IS_PR=true
fi

# Determine the version bump type based on commit message or flag
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

# Ensure changes are being captured in any file within the packages/
CHANGED_PACKAGES=$(git diff --name-only origin/main HEAD | grep -E 'packages/.+' | sed 's/\/.*//')

if [[ -z "$CHANGED_PACKAGES" ]]; then
  echo "No package changes detected."
  exit 0
fi

# Get the dependency graph using Yarn workspaces
DEPENDENCY_GRAPH=$(yarn workspaces info)

# Function to get dependencies of a package
get_dependencies() {
  PACKAGE=$1
  echo "$DEPENDENCY_GRAPH" | jq -r --arg package "$PACKAGE" '.[$package].dependencies // []'
}

# Initialize arrays for sorted packages and visited packages
sorted_packages=()
visited=()

# Toposort function to ensure dependencies are published first
toposort() {
  local package=$1
  # If already visited, return
  if [[ " ${visited[@]} " =~ " ${package} " ]]; then
    return
  fi

  # Mark the current package as visited
  visited+=("$package")

  # Get the dependencies of the current package
  dependencies=$(get_dependencies "$package")

  # Recurse on dependencies (publish dependencies first)
  for dep in $dependencies; do
    toposort "$dep"
  done

  # Add the current package to the sorted list
  sorted_packages+=("$package")
}

# Perform topological sorting for each changed package
for pkg in $CHANGED_PACKAGES; do
  toposort "$pkg"
done

echo "Sorted packages to publish: ${sorted_packages[@]}"

# Publish the packages in sorted order
for PACKAGE in "${sorted_packages[@]}"; do
  PACKAGE_NAME=$PACKAGE
  echo "Processing package: $PACKAGE_NAME"

  # Determine the latest stable version and increment it based on the bump type
  LATEST_STABLE_VERSION=$(npm view $PACKAGE_NAME version)

  if [[ -z "$LATEST_STABLE_VERSION" ]]; then
    echo "No previous stable version found for $PACKAGE_NAME, using package.json version."
    LATEST_STABLE_VERSION=$(jq -r .version package.json)
  fi

  echo "Latest stable version for $PACKAGE_NAME: $LATEST_STABLE_VERSION"

  if [[ "$VERSION_BUMP" == "prerelease" ]]; then
    LATEST_BETA_VERSION=$(npm view $PACKAGE_NAME versions --json | jq -r '[.[] | select(contains("-beta"))] | max // empty')

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

  if [[ "$VERSION_BUMP" == "prerelease" ]]; then
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
done

# Clean up after publishing
yarn config unset yarnPath
jq 'del(.packageManager)' package.json > temp.json && mv temp.json package.json

# Commit any changes (if not in a PR)
if [[ "$IS_PR" != "true" && -n $(git status --porcelain) ]]; then
  git add .
  git -c user.email="$COMMIT_EMAIL" \
      -c user.name="$COMMIT_NAME" \
      commit -m "commit release script and config changes"
  git push https://x-access-token:${GH_PAT}@github.com/shanmukh0504/monorepo.git HEAD:main
fi

# Remove npmrc file after publishing
rm -f ~/.npmrc
