#!/bin/bash

ENABLE_COVERAGE=

for arg do
    shift
    [ "$arg" = "--enable-coverage" ] && ENABLE_COVERAGE="-Db_coverage=true" && continue
    set -- "$@" "$arg"
done

SCRIPT_DIR="$(cd -- "$(dirname "$0")" >/dev/null 2>&1; pwd -P)"
INSTALL_DIR="$SCRIPT_DIR/../../pginst"
source "$SCRIPT_DIR/env.sh"

cd "$SCRIPT_DIR/.."

meson setup build --prefix "$INSTALL_DIR" --buildtype="$1" -Dcassert=true -Dtap_tests=enabled $ENABLE_COVERAGE
cd build && ninja && ninja install
