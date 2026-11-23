#!/bin/bash
# Install the model toolchain under tools/ in this repo: Node, a JDK, and Quint.
# Anything already installed there is skipped.
#
#   Node   runs Quint
#   JDK    only needed for `quint verify` (the exhaustive checkers)
#   Quint  downloads its simulator and Apalache into ~/.quint on first use
#
# The comparison with the Rust also needs a Rust toolchain (rustup; Agave pins
# its own version) and Agave's build dependencies.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODE_VERSION=v24.22.3
QUINT_VERSION=0.33.1
JDK_FEATURE=21

mkdir -p "$HERE/tools"
cd "$HERE/tools"

if [ ! -x node/bin/node ]; then
  f="node-$NODE_VERSION-linux-x64.tar.xz"
  curl -fsSLO "https://nodejs.org/dist/$NODE_VERSION/$f"
  curl -fsSL "https://nodejs.org/dist/$NODE_VERSION/SHASUMS256.txt" | grep " $f\$" | sha256sum -c -
  tar -xJf "$f" && mv "node-$NODE_VERSION-linux-x64" node && rm "$f"
fi

if [ ! -x jdk/bin/java ]; then
  mkdir -p jdk
  curl -fsSL "https://api.adoptium.net/v3/binary/latest/$JDK_FEATURE/ga/linux/x64/jdk/hotspot/normal/eclipse" \
    | tar -xz -C jdk --strip-components=1
fi

if [ ! -x quint/node_modules/.bin/quint ]; then
  mkdir -p quint
  (cd quint && PATH="$HERE/tools/node/bin:$PATH" npm install --no-fund --no-audit "@informalsystems/quint@$QUINT_VERSION")
fi

. "$HERE/env.sh"
echo "node $(node --version), quint $(quint --version), $(java -version 2>&1 | head -1)"
