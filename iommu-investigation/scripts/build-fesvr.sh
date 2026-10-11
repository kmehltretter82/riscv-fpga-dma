#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORKSPACE=$(cd "$ROOT/.." && pwd)
SRC="$WORKSPACE/sources/riscv-isa-sim-fesvr"
BUILD="$ROOT/build/fesvr-35d"
PREFIX="$ROOT/tools/fesvr"
PATCH="$ROOT/patches/fesvr-modern-cstdint.patch"

expected=35d50bc40e59ea1d5566fbd3d9226023821b1bb6
actual=$(git -C "$SRC" rev-parse HEAD)
if [[ $actual != "$expected" ]]; then
    printf 'FESVR revision mismatch: expected %s, got %s\n' \
        "$expected" "$actual" >&2
    exit 2
fi
git -C "$SRC" diff --check
git -C "$SRC" apply --check --reverse "$PATCH"

rm -rf "$BUILD" "$PREFIX"
mkdir -p "$BUILD" "$PREFIX"
cd "$BUILD"
"$SRC/configure" --prefix="$PREFIX"
make -j"${BUILD_JOBS:-2}" libfesvr.a
make install-hdrs install-config-hdrs
mkdir -p "$PREFIX/lib"
install -m 0644 libfesvr.a "$PREFIX/lib/libfesvr.a"

test -s "$PREFIX/lib/libfesvr.a"
test -s "$PREFIX/include/fesvr/dtm.h"
sha256sum "$PREFIX/lib/libfesvr.a" >"$ROOT/logs/fesvr.sha256"
printf 'FESVR ready: %s\n' "$PREFIX/lib/libfesvr.a"
