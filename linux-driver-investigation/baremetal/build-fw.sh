#!/usr/bin/env bash
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cheshire=$(cd -- "$here/../../cheshire" && pwd)
cross=${RISCV_CROSS_PREFIX:-riscv64-linux-gnu-}
flags=(
  -march=rv64gc_zifencei -mabi=lp64d -mcmodel=medany
  -Os -g -ffreestanding -fno-builtin -ffunction-sections -fdata-sections
)

"${cross}gcc" "${flags[@]}" -c "$here/start.S" -o "$here/start.o"
"${cross}gcc" "${flags[@]}" -I"$cheshire/sw/include" -c \
  "$here/dma_irq_abort_test.c" -o "$here/dma_irq_abort_test.o"
"${cross}gcc" -march=rv64gc_zifencei -mabi=lp64d -mcmodel=medany \
  -nostdlib -nostartfiles -static -Wl,--gc-sections \
  -Wl,-Map,"$here/dma_irq_abort_test.map" -T "$here/link.ld" \
  "$here/start.o" "$here/dma_irq_abort_test.o" \
  -o "$here/dma_irq_abort_test.elf"
"${cross}objcopy" -O verilog "$here/dma_irq_abort_test.elf" \
  "$here/dma_irq_abort_test.memh"
"${cross}objdump" -d -S "$here/dma_irq_abort_test.elf" \
  > "$here/dma_irq_abort_test.dump"
