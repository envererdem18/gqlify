#!/usr/bin/env bash
# Downloads the Magento 2 GraphQL schema (all modules' etc/schema.graphqls)
# at a pinned commit into .dart_tool/gqlify_benchmark/magento/ for the
# benchmarks. The files are OSL-3.0/AFL-3.0 licensed and are therefore not
# committed to this repository.
set -euo pipefail
COMMIT=ef53290569f3959a2558d507e648ff93b850c6f7  # magento/magento2 2.4-develop
DEST="$(dirname "$0")/../.dart_tool/gqlify_benchmark/magento"
mkdir -p "$DEST"
MODULES=$(curl -fsSL "https://api.github.com/repos/magento/magento2/contents/app/code/Magento?ref=$COMMIT" \
  | grep '"name"' | sed -E 's/.*"name": "([^"]+)".*/\1/' | grep -E 'GraphQl$|^GraphQl')
count=0
for module in $MODULES; do
  url="https://raw.githubusercontent.com/magento/magento2/$COMMIT/app/code/Magento/$module/etc/schema.graphqls"
  if curl -fsSL "$url" -o "$DEST/$module.graphqls" 2>/dev/null; then
    count=$((count + 1))
  else
    rm -f "$DEST/$module.graphqls"
  fi
done
echo "Downloaded $count schema files to $DEST (commit $COMMIT)"
