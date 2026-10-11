#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
workspace=$(cd -- "$here/.." && pwd)
mkdir -p -- "$here/out"

mapfile -d '' inputs < <(
  find "$here" -type f \
    \( -path "$here/binding/*" -o -path "$here/client/*" -o \
       -path "$here/config/*" -o -path "$here/driver/*" -o \
       -path "$here/dts/*" -o -path "$here/init/*" -o \
       -path "$here/patches/*" -o -path "$here/rtl/*" -o \
       -path "$here/rtl-overrides/*" -o -path "$here/scripts/*" -o \
       -path "$here/README.md" -o -path "$here/STATUS.md" -o \
       -path "$here/VALIDATION.md" \) \
    ! -name '*.o' ! -name '*.ko' ! -name '*.mod' ! -name '*.mod.c' \
    ! -name 'Module.symvers' ! -name 'modules.order' ! -name '.*.cmd' \
    -print0 | sort -z
)
sha256sum "${inputs[@]}" > "$here/out/SHA256SUMS.inputs"

{
  printf 'cheshire=%s\n' "$(git -C "$workspace/cheshire" rev-parse HEAD)"
  printf 'cheshire_irq=%s\n' "$(git -C "$here/sources/cheshire-irq" rev-parse HEAD)"
  printf 'idma_abort=%s\n' "$(git -C "$here/sources/idma-abort" rev-parse HEAD)"
  printf 'cva6=%s\n' "$(git -C "$here/sources/cva6-no-trace" rev-parse HEAD)"
  printf 'linux=%s\n' "$(git -C "$here/sources/linux-cheshire-cache" rev-parse HEAD)"
  printf 'pulp_linux=%s\n' "$(git -C "$here/sources/pulp-linux" rev-parse HEAD)"
} > "$here/out/INPUT-REVISIONS.txt"
sha256sum "$here/out/INPUT-REVISIONS.txt" \
  > "$here/out/SHA256SUMS.revisions"

count=${#inputs[@]}
printf 'sealed %s Phase 11 source/static-control inputs\n' "$count"
