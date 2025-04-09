#!/bin/bash

export TDE_MODE=1
export PERCONA_SERVER_VERSION=17.4.1

SCRIPT_DIR="$(cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P)"
INSTALL_DIR="$SCRIPT_DIR/../../pginst"

cd "$SCRIPT_DIR/.."

make check-world
