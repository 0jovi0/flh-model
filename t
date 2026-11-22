#!/bin/bash
# Run cargo with the same caps as ./q: hard CPU quota, low priority, capped
# memory.
#
# Usage (from the directory with the Cargo.toml, e.g. /opt/ag-model/agave):
#   /opt/ag-model/t test -p agave-votor --features agave-unstable-api --lib quint_connect
#   Q_CPUS=<n> /opt/ag-model/t ...   use n cores instead of the default 4
#
# connect/bin comes first on PATH: its `quint` adds --n-threads, because
# quint-connect starts the simulator with one thread per core.
AG_MODEL=/opt/ag-model
CPUS="${Q_CPUS:-4}"
export PATH="$AG_MODEL/connect/bin:/root/.cargo/bin:$PATH"
export Q_CPUS="$CPUS" CARGO_BUILD_JOBS="$CPUS"
exec systemd-run --scope --quiet --collect \
  -p CPUQuota="${CPUS}00%" -p CPUWeight=20 -p IOWeight=20 -p MemoryMax=32G \
  nice -n 19 cargo "$@"
