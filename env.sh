# Source this to use the model toolchain: . <repo>/env.sh
# The toolchain lives in tools/ next to this file (see install-tools.sh).
FLH_MODEL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export FLH_MODEL
export JAVA_HOME="$FLH_MODEL/tools/jdk"
export PATH="$FLH_MODEL/tools/quint/node_modules/.bin:$FLH_MODEL/tools/node/bin:$JAVA_HOME/bin:$PATH"
