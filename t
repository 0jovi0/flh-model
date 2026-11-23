#!/bin/bash
# Run cargo with the same caps as ./q: hard CPU quota, low priority, capped
# memory (see ./q for when the cgroup is used).
#
# Usage, from agave/ inside this repo:
#   ../t test -p agave-votor --features agave-unstable-api --lib quint_connect
#   Q_CPUS=<n> ../t ...   use n cores instead of the default 4
#
# connect/bin comes first on PATH: its `quint` adds --n-threads, because
# quint-connect starts the simulator with one thread per core.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/env.sh"
CPUS="${Q_CPUS:-4}"
export PATH="$HERE/connect/bin:$HOME/.cargo/bin:$PATH"
export Q_CPUS="$CPUS" CARGO_BUILD_JOBS="$CPUS"
if [ -z "${Q_NOCAP:-}" ] && [ "$(id -u)" -eq 0 ] && command -v systemd-run >/dev/null 2>&1; then
  exec systemd-run --scope --quiet --collect \
    -p CPUQuota="${CPUS}00%" -p CPUWeight=20 -p IOWeight=20 -p MemoryMax=32G \
    nice -n 19 cargo "$@"
fi
exec nice -n 19 cargo "$@"
