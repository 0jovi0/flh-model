#!/bin/bash
# Run quint with the model toolchain, capped in CPU and memory, at low priority.
#
# Usage: ./q <quint args...>
#   Q_CPUS=<n> ./q ...   use n cores instead of the default 4
#   Q_NOCAP=1 ./q ...    no cgroup, only low priority and the thread limit
#
# The cap is a cgroup quota set with systemd-run, which needs root. Without
# either, the run gets only --n-threads and nice.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/env.sh"
CPUS="${Q_CPUS:-4}"
ARGS=("$@")
# `quint run` starts one thread per core unless told otherwise.
if [ "${1:-}" = "run" ] && [[ " $* " != *" --n-threads"* ]]; then
  ARGS+=("--n-threads=$CPUS")
fi
if [ -z "${Q_NOCAP:-}" ] && [ "$(id -u)" -eq 0 ] && command -v systemd-run >/dev/null 2>&1; then
  exec systemd-run --scope --quiet --collect \
    -p CPUQuota="${CPUS}00%" -p CPUWeight=20 -p IOWeight=20 -p MemoryMax=32G \
    -E JAVA_HOME="$JAVA_HOME" -E PATH="$PATH" \
    nice -n 19 quint "${ARGS[@]}"
fi
exec nice -n 19 quint "${ARGS[@]}"
