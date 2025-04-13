#!/bin/bash

SCRIPT_DIR="$(cd -- "$(dirname "$0")" >/dev/null 2>&1; pwd -P)"
INSTALL_DIR="$SCRIPT_DIR/../../pginst"
source $SCRIPT_DIR/env.sh

cd "$SCRIPT_DIR/.."

if [ "$1" = "debugoptimized" ]; then
    export CFLAGS="-O2"
    export CXXFLAGS="-O2"
fi

./configure --enable-debug --enable-cassert --enable-tap-tests --enable-coverage --prefix=$INSTALL_DIR
make install-world -j
