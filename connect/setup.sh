#!/bin/bash
# Recreate the Agave copy: Agave at the pinned commit plus the test-only hooks
# for the Quint Connect driver (agave-hooks.patch).
#
# Usage: connect/setup.sh
#   AGAVE_SRC=<dir>   git tree to clone from (default: /home/builder/src/agave-ag)
#   AGAVE_DEST=<dir>  where to put the copy (default: /opt/ag-model/agave)
set -euo pipefail

AG_MODEL=/opt/ag-model
SRC="${AGAVE_SRC:-/home/builder/src/agave-ag}"
DEST="${AGAVE_DEST:-$AG_MODEL/agave}"
TAG=v4.5.0-beta.0
COMMIT=ef54b258ef640c2b643d482e0deefd54863bc885

if [ -e "$DEST" ]; then
  echo "$DEST already exists; move it away first" >&2
  exit 1
fi

# The source tree belongs to another user, so upload-pack is given
# safe.directory for it.
git clone --quiet --depth 1 --branch "$TAG" \
  -u "git -c safe.directory=$SRC/.git upload-pack" "file://$SRC" "$DEST"
cd "$DEST"

if [ "$(git rev-parse HEAD)" != "$COMMIT" ]; then
  echo "expected commit $COMMIT, got $(git rev-parse HEAD)" >&2
  exit 1
fi

git switch --quiet -c ag-model-hooks
git apply --index "$AG_MODEL/connect/agave-hooks.patch"
echo "ok: $DEST is $TAG plus the hooks, staged on branch ag-model-hooks"
echo "run: cd $DEST && $AG_MODEL/t test -p agave-votor --features agave-unstable-api --lib quint_connect"
