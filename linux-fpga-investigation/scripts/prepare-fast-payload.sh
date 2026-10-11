#!/usr/bin/env bash
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
opensbi="$here/sources/pulp-linux/opensbi"
kernel="$here/build/linux-small/arch/riscv/boot/Image"
kernel_config="$here/build/linux-small/.config"
source_dts="$here/dts/cheshire-linux-dma.dts"
stage="$here/build/baseline-fast-prep"
dts="$stage/cheshire-linux-dma.dts"
dtb="$stage/cheshire-linux-dma.dtb"
opensbi_build="$stage/opensbi"
firmware="$opensbi_build/platform/fpga/cheshire/firmware"

for input in "$kernel" "$kernel_config" "$source_dts"; do
  [[ -s $input ]] || { printf 'missing input: %s\n' "$input" >&2; exit 2; }
done
mkdir -p -- "$stage"

kernel_cmdline='console=ttyS0,1562500 quiet loglevel=4 rdinit=/init dma_debug_entries=1024'
grep -Fx "CONFIG_CMDLINE=\"$kernel_cmdline\"" "$kernel_config"
grep -Fx 'CONFIG_CMDLINE_FORCE=y' "$kernel_config"

# Keep the DT copy consistent with the forced compiled command line.  The
# baseline has only a handful of live maps, well below 1,024 entries.
sed 's/rdinit=\/init/rdinit=\/init dma_debug_entries=1024/' \
  "$source_dts" > "$dts"
[[ $(grep -Fc 'dma_debug_entries=1024' "$dts") -eq 1 ]]
dtc -I dts -O dtb -o "$dtb" "$dts"
[[ $(fdtget "$dtb" /chosen bootargs) == *'dma_debug_entries=1024'* ]]

make -C "$opensbi" O="$opensbi_build" PLATFORM=fpga/cheshire \
  CROSS_COMPILE=riscv64-linux-gnu- \
  FW_PAYLOAD_PATH="$kernel" FW_FDT_PATH="$dtb" \
  FW_OPTIONS=0x1 'platform-cflags-y=-std=gnu17' -j2

cp -- "$firmware/fw_payload.elf" "$stage/fw_payload.elf"
cp -- "$firmware/fw_payload.bin" "$stage/fw_payload.bin"
riscv64-linux-gnu-objcopy -O verilog "$firmware/fw_payload.elf" \
  "$stage/fw_payload.memh"

(
  cd -- "$stage"
  sha256sum cheshire-linux-dma.dts cheshire-linux-dma.dtb \
    fw_payload.elf fw_payload.bin fw_payload.memh > SHA256SUMS
  sha256sum -c SHA256SUMS
)

printf 'Prepared isolated baseline payload in %s\n' "$stage"
