#!/bin/bash
set -e

COMMIT_EMAIL=$(git log -1 --pretty=format:'%ae')
COMMIT_NAME=$(git log -1 --pretty=format:'%an')

echo "//registry.npmjs.org/:_authToken=${NPM_TOKEN}" > ~/.npmrc

git fetch --tags
git fetch origin main:refs/remotes/origin/main

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

if [[ "$IS_PR" == "true" && -n "$PR_BRANCH" ]]; then
  git fetch origin "$PR_BRANCH:$PR_BRANCH"
  CHANGED=$(git diff --name-only origin/main..."$PR_BRANCH" | grep '^packages/' | cut -d/ -f2 | sort -u)

elif [[ "$GITHUB_EVENT_NAME" == "push" ]]; then
  LATEST_TAG=$(git describe --tags --abbrev=0)
  echo "Latest tag found: $LATEST_TAG"

  CHANGED=$(git diff --name-only "$LATEST_TAG"...HEAD | grep '^packages/' | cut -d/ -f2 | sort -u)
fi

echo "Changed packages:"
echo "$CHANGED"

if [[ -z "$CHANGED" ]]; then
  echo "No packages changed. Skipping publish."
  exit 0
fi

echo "Changed packages:"
echo "$CHANGED"

if [[ -z "$CHANGED" ]]; then
  echo "No packages changed. Skipping publish."
  exit 0
fi

TOPO_ORDER=$(yarn workspaces foreach --all --topological --no-private exec node -p "require('./package.json').name" 2>/dev/null | grep '^@' | sed 's/\[//;s/\]://')

declare -A REVERSE_DEP_MAP
for PKG in $TOPO_ORDER; do
  PKG_DIR=$(echo "$PKG" | cut -d/ -f2)
  DEPS=$(jq -r '.dependencies // {} | keys[]' "packages/$PKG_DIR/package.json" 2>/dev/null | grep '^@shanmukh0504/' || true)
  for DEP in $DEPS; do
    REVERSE_DEP_MAP[$DEP]="${REVERSE_DEP_MAP[$DEP]} $PKG"
  done
done

declare -A SHOULD_PUBLISH
queue=()
for CHG in $CHANGED; do
  CHG_PKG="@shanmukh0504/$CHG"
  SHOULD_PUBLISH[$CHG_PKG]=1
  queue+=("$CHG_PKG")
done

while [ ${#queue[@]} -gt 0 ]; do
  CURRENT=${queue[0]}
  queue=("${queue[@]:1}")
  for DEP in ${REVERSE_DEP_MAP[$CURRENT]}; do
    if [[ -z "${SHOULD_PUBLISH[$DEP]}" ]]; then
      SHOULD_PUBLISH[$DEP]=1
      queue+=("$DEP")
    fi
  done
done

PUBLISH_ORDER=()
for PKG in $TOPO_ORDER; do
  if [[ ${SHOULD_PUBLISH[$PKG]} == 1 ]]; then
    PUBLISH_ORDER+=("$PKG")
  fi
done

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

for PKG in "${PUBLISH_ORDER[@]}"; do
  echo ""
  echo "📦 Processing $PKG..."
  PKG_DIR=$(echo "$PKG" | cut -d/ -f2)
  cd "packages/$PKG_DIR"

  PACKAGE_NAME=$(jq -r .name package.json)
  LATEST_STABLE_VERSION=$(npm view $PACKAGE_NAME version || jq -r .version package.json)

  echo "Latest version: $LATEST_STABLE_VERSION"

  if [[ "$VERSION_BUMP" == "prerelease" ]]; then
    LATEST_BETA_VERSION=$(npm view $PACKAGE_NAME versions --json | jq -r '[.[] | select(contains("-beta"))] | max // empty')
    if [[ -n "$LATEST_BETA_VERSION" ]]; then
      BETA_NUMBER=$(echo "$LATEST_BETA_VERSION" | sed -E "s/.*-beta\.([0-9]+)/\1/")
      NEW_VERSION="${LATEST_STABLE_VERSION}-beta.$((BETA_NUMBER + 1))"
    else
      NEW_VERSION="${LATEST_STABLE_VERSION}-beta.0"
    fi
  else
    NEW_VERSION=$(increment_version "$LATEST_STABLE_VERSION" "$VERSION_BUMP")
  fi

  echo "Bumping $PACKAGE_NAME to $NEW_VERSION"
  jq --arg new_version "$NEW_VERSION" '.version = $new_version' package.json > package.tmp.json && mv package.tmp.json package.json

  if [[ "$VERSION_BUMP" == "prerelease" ]]; then
    yarn build
    npm publish --tag beta --access public
  else
    if [[ "$IS_PR" != "true" ]]; then
      git add package.json
      git -c user.email="$COMMIT_EMAIL" \
          -c user.name="$COMMIT_NAME" \
          commit -m "V$NEW_VERSION"
      yarn build
      npm publish --access public
      git tag "$PACKAGE_NAME@$NEW_VERSION"
      git push https://x-access-token:${GH_PAT}@github.com/shanmukh0504/monorepo.git HEAD:main --tags
    else
      echo "Skipping commit for PR."
    fi
  fi

  cd - > /dev/null
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