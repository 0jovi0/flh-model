#!/bin/bash
# Run quint with the model toolchain: hard-capped CPU, low priority, capped
# memory.
#
# Usage: ./q <quint args...>
#   Q_CPUS=<n> ./q ...   use n cores instead of the default 4
#
# The CPU cap is a cgroup quota set with systemd-run.
. /opt/ag-model/env.sh
CPUS="${Q_CPUS:-4}"
ARGS=("$@")
# `quint run` starts one thread per core unless told otherwise.
if [ "${1:-}" = "run" ] && [[ " $* " != *" --n-threads"* ]]; then
  ARGS+=("--n-threads=$CPUS")
fi
exec systemd-run --scope --quiet --collect \
  -p CPUQuota="${CPUS}00%" -p CPUWeight=20 -p IOWeight=20 -p MemoryMax=32G \
  -E JAVA_HOME="$JAVA_HOME" -E PATH="$PATH" \
  nice -n 19 quint "${ARGS[@]}"
