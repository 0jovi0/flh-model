#!/bin/bash
# Create agave/ inside this repo: Agave at the pinned tag, plus the test-only
# hooks for the Quint Connect driver (agave-hooks.patch).
#
# Usage: connect/setup.sh
#   AGAVE_SRC=<url or dir>  where to clone Agave from (default: upstream on GitHub)
#   AGAVE_DEST=<dir>        where to put the copy (default: <repo>/agave)
#
# The driver finds the spec at ../../spec from agave/votor, so the copy has to
# sit at <repo>/agave for the tests to run.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLH_MODEL="$(cd "$HERE/.." && pwd)"
SRC="${AGAVE_SRC:-https://github.com/anza-xyz/agave.git}"
DEST="${AGAVE_DEST:-$FLH_MODEL/agave}"
TAG=v5.0.0-alpha.1
COMMIT=22d4b3a8d9bfd7b4dcda330ea17c777c09fc7209

if [ -e "$DEST" ]; then
  echo "$DEST already exists; move it away first" >&2
  exit 1
fi

git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$TAG" "$SRC" "$DEST"
cd "$DEST"

if [ "$(git rev-parse HEAD)" != "$COMMIT" ]; then
  echo "expected commit $COMMIT, got $(git rev-parse HEAD)" >&2
  exit 1
fi

git switch --quiet -c flh-model-hooks
git apply --index "$HERE/agave-hooks.patch"
echo "ok: $DEST is $TAG plus the hooks, staged on branch flh-model-hooks"
echo "run: cd $DEST && $FLH_MODEL/t test -p agave-votor --features agave-unstable-api --lib quint_connect"
