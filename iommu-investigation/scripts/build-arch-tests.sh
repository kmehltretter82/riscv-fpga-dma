#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORKSPACE=$(cd "$ROOT/.." && pwd)
SRC="$WORKSPACE/sources/riscv-iommu-tests"
TOOLS="$WORKSPACE/.tools/riscv-baremetal/usr"
CC="$TOOLS/bin/riscv64-unknown-elf-gcc --specs=$TOOLS/lib/picolibc/riscv64-unknown-elf/picolibc-local.specs"
NM="$TOOLS/bin/riscv64-unknown-elf-nm"
OBJDUMP="$TOOLS/bin/riscv64-unknown-elf-objdump"
log_level=${LOG_LEVEL:-LOG_INFO}

make -C "$SRC" clean PLAT=cva6
PATH="$TOOLS/bin:$PATH" make -C "$SRC" -j4 PLAT=cva6 \
    LOG_LEVEL="$log_level" CC="$CC"

elf="$SRC/build/cva6/rv_iommu_test.elf"
test -s "$elf"
table_size=$($NM -n "$elf" | awk '$3 == "_test_table_size" { print $1 }')
if [[ $table_size != 000000000000000a ]]; then
    printf 'Expected 10 supported architectural tests, got symbol value %s\n' \
        "${table_size:-missing}" >&2
    exit 2
fi

if ! $NM -n "$elf" | awk '$3 == "tohost" { found = 1 } END { exit !found }'; then
    printf 'Missing HTIF tohost completion symbol\n' >&2
    exit 2
fi

exit_disassembly=$($OBJDUMP -dr "$elf" | sed -n '/<_exit>:/,/^$/p')
if ! grep -Eq 'sd[[:space:]].*<tohost>' <<<"$exit_disassembly"; then
    printf '_exit does not store its result to HTIF tohost\n' >&2
    exit 2
fi

sha256sum "$elf" "$SRC/build/cva6/rv_iommu_test.bin" \
    > "$ROOT/logs/arch-tests.sha256"
printf 'Architectural test payload ready: %s (10 supported tests)\n' "$elf"
