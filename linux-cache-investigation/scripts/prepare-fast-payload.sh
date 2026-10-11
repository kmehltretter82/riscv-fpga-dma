#!/usr/bin/env bash
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cell=${1:-}
case "$cell" in
  legacy|hpd) ;;
  *) printf 'usage: %s legacy|hpd\n' "$0" >&2; exit 2 ;;
esac

opensbi="$here/sources/pulp-linux/opensbi"
kernel="$here/build/linux-cache/arch/riscv/boot/Image"
template="$here/dts/cheshire-linux-dma-cache.dts.in"
stage="$here/build/phase11-$cell-fast-prep"
dts="$stage/cheshire-linux-dma-cache-$cell.dts"
dtb="$stage/cheshire-linux-dma-cache-$cell.dtb"
opensbi_build="$stage/opensbi"
firmware="$opensbi_build/platform/fpga/cheshire/firmware"

for input in "$kernel" "$template"; do
  [[ -s $input ]] || { printf 'missing input: %s\n' "$input" >&2; exit 2; }
done
mkdir -p -- "$stage"

# Keep DMA API debugging enabled, but avoid spending most simulated boot time
# preallocating the default 65,536 tracking entries.  The mapping matrix peaks
# below 530 simultaneously live mappings, so 1,024 preserves headroom.
sed "s/@CELL@/$cell/g" "$template" > "$dts"
[[ $(grep -Fc 'dma_debug_entries=1024' "$dts") -eq 1 ]]
[[ $(grep -Fc "phase11.cell=$cell" "$dts") -eq 1 ]]
dtc -I dts -O dtb -o "$dtb" "$dts"
[[ $(fdtget "$dtb" /chosen bootargs) == *'dma_debug_entries=1024'* ]]
[[ $(fdtget "$dtb" /chosen bootargs) == *"phase11.cell=$cell"* ]]

make -C "$opensbi" O="$opensbi_build" PLATFORM=fpga/cheshire \
  CROSS_COMPILE=riscv64-linux-gnu- \
  FW_PAYLOAD_PATH="$kernel" FW_FDT_PATH="$dtb" \
  FW_OPTIONS=0x1 'platform-cflags-y=-std=gnu17' -j2

cp -- "$firmware/fw_payload.elf" "$stage/fw_payload-$cell.elf"
cp -- "$firmware/fw_payload.bin" "$stage/fw_payload-$cell.bin"
riscv64-linux-gnu-objcopy -O verilog "$firmware/fw_payload.elf" \
  "$stage/fw_payload-$cell.memh"

(
  cd -- "$stage"
  sha256sum \
    "cheshire-linux-dma-cache-$cell.dts" \
    "cheshire-linux-dma-cache-$cell.dtb" \
    "fw_payload-$cell.elf" \
    "fw_payload-$cell.bin" \
    "fw_payload-$cell.memh" > SHA256SUMS
  sha256sum -c SHA256SUMS
)

printf 'Prepared isolated %s payload in %s\n' "$cell" "$stage"
