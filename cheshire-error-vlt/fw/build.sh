#!/usr/bin/env bash
set -euo pipefail

fw_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cheshire_dir=$(cd -- "$fw_dir/../../cheshire" && pwd)
cross_prefix=${RISCV_CROSS_PREFIX:-riscv64-linux-gnu-}
compile_flags=(
  -march=rv64gc_zifencei -mabi=lp64d -mcmodel=medany
  -Os -g -ffreestanding -fno-builtin -ffunction-sections -fdata-sections
)

"${cross_prefix}gcc" "${compile_flags[@]}" -c \
  "$fw_dir/start.S" -o "$fw_dir/start.o"
"${cross_prefix}gcc" "${compile_flags[@]}" -I"$cheshire_dir/sw/include" -c \
  "$fw_dir/dma_error_test.c" -o "$fw_dir/dma_error_test.o"

"${cross_prefix}gcc" \
  -march=rv64gc_zifencei -mabi=lp64d -mcmodel=medany \
  -nostdlib -nostartfiles -static \
  -Wl,--gc-sections -Wl,-Map,"$fw_dir/dma_error_test.map" \
  -T "$fw_dir/link.ld" \
  "$fw_dir/start.o" "$fw_dir/dma_error_test.o" \
  -o "$fw_dir/dma_error_test.elf"

"${cross_prefix}objcopy" -O verilog \
  "$fw_dir/dma_error_test.elf" "$fw_dir/dma_error_test.memh"
"${cross_prefix}objdump" -d -S \
  "$fw_dir/dma_error_test.elf" > "$fw_dir/dma_error_test.dump"
"${cross_prefix}readelf" -h -l -S \
  "$fw_dir/dma_error_test.elf" > "$fw_dir/dma_error_test.readelf"
