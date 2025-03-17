#!/bin/bash

set -e

export TDE_MODE=1
export PERCONA_SERVER_VERSION=17.4.1

SCRIPT_DIR="$(cd -- "$(dirname "$0")" >/dev/null 2>&1; pwd -P)"
source $SCRIPT_DIR/configure-tde-server.sh

ADD_FLAGS=

if [ "$1" = "--continue" ]; then
    ADD_FLAGS="-k"
fi

cd $SCRIPT_DIR/../contrib/pg_tde
pwd
EXTRA_REGRESS_OPTS="--extra-setup=$SCRIPT_DIR/tde_setup.sql" make installcheck $ADD_FLAGS
