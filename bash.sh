# 🧠 Step 4: Smart dependency-based publish filter
# Get changed packages
CHANGED=$(git diff --name-only origin/main...HEAD | grep '^packages/' | cut -d/ -f2 | sort -u)
echo "Changed packages: $CHANGED"

# Get topological order of all workspaces
TOPO_ORDER=$(yarn workspaces foreach --all --topological --no-private exec node -p "require('./package.json').name" 2>/dev/null | grep '^@' | sed 's/\[//;s/\]://')

# Build reverse dependency map: each dependency -> who depends on it
declare -A REVERSE_DEP_MAP

for PKG in $TOPO_ORDER; do
  PKG_DIR=$(echo "$PKG" | cut -d/ -f2)
  DEPS=$(jq -r '.dependencies // {} | keys[]' "packages/$PKG_DIR/package.json" 2>/dev/null | grep '^@shanmukh0504/' || true)
  for DEP in $DEPS; do
    REVERSE_DEP_MAP[$DEP]="${REVERSE_DEP_MAP[$DEP]} $PKG"
  done
done

# Start with changed packages, and traverse reverse-dependency graph
declare -A SHOULD_PUBLISH
queue=()

for CHG in $CHANGED; do
  CHG_PKG="@shanmukh0504/$CHG"
  SHOULD_PUBLISH[$CHG_PKG]=1
  queue+=("$CHG_PKG")
done

# Breadth-first traversal to find all dependents
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

# Print final publish list in topological order
echo ""
echo "🔼 Final publish order:"
for PKG in $TOPO_ORDER; do
  if [[ ${SHOULD_PUBLISH[$PKG]} == 1 ]]; then
    echo "$PKG"
  fi
done
