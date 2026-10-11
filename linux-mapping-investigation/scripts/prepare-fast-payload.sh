#!/usr/bin/env bash
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mode=${1:-}
case "$mode" in
  direct) source_dts="$here/dts/cheshire-linux-dma-mapping.dts" ;;
  swiotlb) source_dts="$here/dts/cheshire-linux-dma-mapping-swiotlb.dts" ;;
  negative) source_dts="$here/dts/cheshire-linux-dma-api-negative.dts" ;;
  *) printf 'usage: %s direct|swiotlb|negative\n' "$0" >&2; exit 2 ;;
esac

opensbi="$here/sources/pulp-linux/opensbi"
kernel="$here/build/linux-mapping/arch/riscv/boot/Image"
stage="$here/build/mapping-$mode-fast-prep"
dts="$stage/cheshire-linux-dma-mapping-$mode.dts"
dtb="$stage/cheshire-linux-dma-mapping-$mode.dtb"
opensbi_build="$stage/opensbi"
firmware="$opensbi_build/platform/fpga/cheshire/firmware"

for input in "$kernel" "$source_dts"; do
  [[ -s $input ]] || { printf 'missing input: %s\n' "$input" >&2; exit 2; }
done
mkdir -p -- "$stage"

# CONFIG_DMA_API_DEBUG remains enabled.  This boot parameter reduces only its
# preallocated tracking table; the positive matrix has fewer than 530
# simultaneous mappings, so 1,024 entries retain nearly twofold headroom.
cp -- "$source_dts" "$dts"
[[ $(grep -Fc 'dma_debug_entries=1024' "$dts") -eq 1 ]]
if [[ $mode == swiotlb ]]; then
  [[ $(grep -Fc 'swiotlb=4096,force' "$dts") -eq 1 ]]
else
  ! grep -Fq 'swiotlb=4096,force' "$dts"
fi
if [[ $mode == negative ]]; then
  [[ $(grep -Fc 'dma_api_negative=1' "$dts") -eq 1 ]]
  [[ $(grep -Fc \
    'dma_debug_driver=cheshire-idma-irq-investigation' "$dts") -eq 1 ]]
fi
dtc -I dts -O dtb -o "$dtb" "$dts"
bootargs=$(fdtget "$dtb" /chosen bootargs)
[[ $bootargs == *'dma_debug_entries=1024'* ]]
if [[ $mode == swiotlb ]]; then
  [[ $bootargs == *'swiotlb=4096,force'* ]]
else
  [[ $bootargs != *'swiotlb=4096,force'* ]]
fi
if [[ $mode == negative ]]; then
  [[ $bootargs == *'dma_api_negative=1'* ]]
  [[ $bootargs == \
    *'dma_debug_driver=cheshire-idma-irq-investigation'* ]]
fi

make -C "$opensbi" O="$opensbi_build" PLATFORM=fpga/cheshire \
  CROSS_COMPILE=riscv64-linux-gnu- \
  FW_PAYLOAD_PATH="$kernel" FW_FDT_PATH="$dtb" \
  FW_OPTIONS=0x1 'platform-cflags-y=-std=gnu17' -j2

cp -- "$firmware/fw_payload.elf" "$stage/fw_payload-$mode.elf"
cp -- "$firmware/fw_payload.bin" "$stage/fw_payload-$mode.bin"
riscv64-linux-gnu-objcopy -O verilog "$firmware/fw_payload.elf" \
  "$stage/fw_payload-$mode.memh"

(
  cd -- "$stage"
  sha256sum \
    "cheshire-linux-dma-mapping-$mode.dts" \
    "cheshire-linux-dma-mapping-$mode.dtb" \
    "fw_payload-$mode.elf" \
    "fw_payload-$mode.bin" \
    "fw_payload-$mode.memh" > SHA256SUMS
  sha256sum -c SHA256SUMS
)

printf 'Prepared isolated %s mapping payload in %s\n' "$mode" "$stage"
