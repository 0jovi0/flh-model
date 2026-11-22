# Source this to use the model toolchain: . /opt/ag-model/env.sh
export AG_MODEL=/opt/ag-model
export JAVA_HOME=$AG_MODEL/tools/jdk
export PATH=$AG_MODEL/tools/quint/node_modules/.bin:$AG_MODEL/tools/node/bin:$JAVA_HOME/bin:$PATH
