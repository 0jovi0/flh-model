#!/bin/bash
# Check that the comparison tests detect each patch in connect/mutants/.
# For every patch: apply it to agave/, run the comparison tests, reverse it.
# A mutant counts as detected when the tests fail with a state mismatch.
#
# Usage: connect/check-mutants.sh      (from anywhere, after connect/setup.sh)
#   QUINT_SEED=<seed> connect/check-mutants.sh    pin the traces
#
# Exit status: 0 every mutant detected, 1 a mutant was not detected,
#              2 a patch could not be applied or agave/ is missing.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
AGAVE="$ROOT/agave"
MISMATCH="Specification and implementation states diverge"

if [ ! -d "$AGAVE" ]; then
  echo "no agave/ in $ROOT: run connect/setup.sh first" >&2
  exit 2
fi
LOGS="$(mktemp -d)"
cd "$AGAVE"

applied=""
restore() {
  if [ -n "$applied" ]; then
    git apply -R "$applied"
    applied=""
  fi
}
trap restore EXIT
trap 'restore; exit 130' INT TERM

status=0
summary=""
for patch in "$HERE"/mutants/*.patch; do
  name="$(basename "$patch" .patch)"
  log="$LOGS/$name.log"
  echo
  echo "== $name"
  if ! git apply --check "$patch" 2>/dev/null; then
    echo "   the patch does not apply to agave/"
    summary+="$(printf '%-40s %s' "$name" "DOES NOT APPLY")"$'\n'
    status=2
    continue
  fi
  git apply "$patch"
  applied="$patch"
  "$ROOT/t" test -p agave-votor --features agave-unstable-api --lib quint_connect 2>&1 \
    | tee "$log" \
    | grep --line-buffered -E "^test .*quint_connect::|$MISMATCH|Reproduce this error|^test result|^error"
  code="${PIPESTATUS[0]}"
  restore
  failed="$(grep -cE '^test .*quint_connect::.* FAILED$' "$log")"
  if [ "$code" -ne 0 ] && grep -q "$MISMATCH" "$log"; then
    verdict="detected ($failed of 12 tests failed)"
  else
    verdict="NOT DETECTED (test exit status $code)"
    [ "$status" -eq 0 ] && status=1
  fi
  echo "   $verdict"
  summary+="$(printf '%-40s %s' "$name" "$verdict")"$'\n'
done

echo
echo "== summary"
printf '%s' "$summary"
echo "full test output: $LOGS"
exit "$status"
