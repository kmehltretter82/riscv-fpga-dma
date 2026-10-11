#!/usr/bin/env bash
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
workspace=$(cd -- "$here/.." && pwd)
linux_src="$here/sources/linux-cheshire-cache"
pulp_linux="$here/sources/pulp-linux"
opensbi="$pulp_linux/opensbi"
kernel_build="$here/build/linux-cache"
rootfs="$here/build/rootfs"
jobs=${BUILD_JOBS:-4}

"$here/scripts/check-source-contracts.sh"
[[ $(git -C "$linux_src" rev-parse HEAD) == \
   388b607d107c07aaade04c7f22f344cab6bdccd3 ]]
[[ $(git -C "$pulp_linux" rev-parse HEAD) == \
   2df607d83b38721c2fd419357c6bf6d1db12df32 ]]
[[ $(git -C "$opensbi" rev-parse HEAD) == \
   04c94d9c4014c570909036f893737e4af5e74744 ]]

mkdir -p -- "$kernel_build" "$rootfs/lib/modules" "$rootfs/proc" \
  "$rootfs/sys" "$rootfs/dev" "$here/build/dts" "$here/out"
rm -f -- "$rootfs/lib/modules/cheshire-idma.ko" \
  "$rootfs/lib/modules/cheshire-idma-cache-test.ko"

riscv64-linux-gnu-gcc -nostdlib -static -Os -Wall -Wextra -Werror \
  -ffreestanding -fno-stack-protector -fno-pie -no-pie \
  -fno-asynchronous-unwind-tables -fno-unwind-tables \
  -ffunction-sections -fdata-sections \
  -march=rv64imac_zicsr_zifencei -mabi=lp64 \
  -I"$workspace/linux-mininit" \
  -Wl,-e,_start,--gc-sections,--build-id=none \
  -o "$rootfs/init" \
  "$workspace/linux-mininit/start.S" "$here/init/init-tiny.c"
(( $(stat -c %s "$rootfs/init") <= 16384 )) || {
  printf 'freestanding init exceeds 16 KiB\n' >&2
  exit 2
}
if riscv64-linux-gnu-readelf -l "$rootfs/init" | grep -q INTERP; then
  printf 'freestanding init unexpectedly has an ELF interpreter\n' >&2
  exit 2
fi
if riscv64-linux-gnu-nm -u "$rootfs/init" | grep -q .; then
  printf 'freestanding init has undefined symbols\n' >&2
  exit 2
fi
"$workspace/linux-mininit/check-console-contract.sh" \
  "$rootfs/init" "$here/init/init-tiny.c"

for cell in legacy hpd; do
  sed "s/@CELL@/$cell/g" "$here/dts/cheshire-linux-dma-cache.dts.in" \
    > "$here/build/dts/cheshire-linux-dma-cache-$cell.dts"
  dtc -I dts -O dtb \
    -o "$here/out/cheshire-linux-dma-cache-$cell.dtb" \
    "$here/build/dts/cheshire-linux-dma-cache-$cell.dts"
  [[ $(fdtget "$here/out/cheshire-linux-dma-cache-$cell.dtb" \
       /chosen bootargs) == *'dma_debug_entries=1024'* ]]
done

KCONFIG_ALLCONFIG="$pulp_linux/target/cheshire/linux64_defconfig" \
  make -C "$linux_src" O="$kernel_build" ARCH=riscv \
    CROSS_COMPILE=riscv64-linux-gnu- allnoconfig
"$linux_src/scripts/kconfig/merge_config.sh" -m -O "$kernel_build" \
  "$kernel_build/.config" "$here/config/linux.fragment"
"$linux_src/scripts/config" --file "$kernel_build/.config" \
  --set-str INITRAMFS_SOURCE \
  "$rootfs $workspace/linux-mininit/initramfs-console.spec"
make -C "$linux_src" O="$kernel_build" ARCH=riscv \
  CROSS_COMPILE=riscv64-linux-gnu- olddefconfig
grep -qx 'CONFIG_DMA_API_DEBUG=y' "$kernel_build/.config"
grep -qx 'CONFIG_RISCV_CHESHIRE_CACHE_OPS=y' "$kernel_build/.config"
grep -qx '# CONFIG_SMP is not set' "$kernel_build/.config"

make -C "$linux_src" O="$kernel_build" ARCH=riscv \
  CROSS_COMPILE=riscv64-linux-gnu- -j"$jobs" vmlinux modules
make -C "$linux_src" O="$kernel_build" ARCH=riscv \
  CROSS_COMPILE=riscv64-linux-gnu- M="$here/driver" -j"$jobs" modules
make -C "$linux_src" O="$kernel_build" ARCH=riscv \
  CROSS_COMPILE=riscv64-linux-gnu- M="$here/client" -j"$jobs" modules
cp "$here/driver/cheshire-idma.ko" "$rootfs/lib/modules/cheshire-idma.ko"
cp "$here/client/cheshire-idma-cache-test.ko" \
  "$rootfs/lib/modules/cheshire-idma-cache-test.ko"
touch "$rootfs"
make -C "$linux_src" O="$kernel_build" ARCH=riscv \
  CROSS_COMPILE=riscv64-linux-gnu- -j"$jobs" Image

for cell in legacy hpd; do
  opensbi_build="$here/build/opensbi-cache-$cell"
  make -C "$opensbi" O="$opensbi_build" PLATFORM=fpga/cheshire \
    CROSS_COMPILE=riscv64-linux-gnu- \
    FW_PAYLOAD_PATH="$kernel_build/arch/riscv/boot/Image" \
    FW_FDT_PATH="$here/out/cheshire-linux-dma-cache-$cell.dtb" \
    FW_OPTIONS=0x1 'platform-cflags-y=-std=gnu17' -j"$jobs"
  firmware="$opensbi_build/platform/fpga/cheshire/firmware"
  cp "$firmware/fw_payload.elf" "$here/out/fw_payload-$cell.elf"
  cp "$firmware/fw_payload.bin" "$here/out/fw_payload-$cell.bin"
  riscv64-linux-gnu-objcopy -O verilog "$firmware/fw_payload.elf" \
    "$here/out/fw_payload-$cell.memh"
done

cpio -it < "$kernel_build/usr/initramfs_data.cpio" \
  > "$here/out/initramfs-contents.txt"
cpio -itv < "$kernel_build/usr/initramfs_data.cpio" \
  > "$here/out/initramfs-contents.verbose.txt"
grep -Eq '^crw-------[[:space:]].*[[:space:]]5,[[:space:]]+1[[:space:]].*dev/console$' \
  "$here/out/initramfs-contents.verbose.txt"
grep -qx 'lib/modules/cheshire-idma.ko' "$here/out/initramfs-contents.txt"
grep -qx 'lib/modules/cheshire-idma-cache-test.ko' \
  "$here/out/initramfs-contents.txt"

sha256sum "$rootfs/init" "$workspace/linux-mininit/start.S" \
  "$workspace/linux-mininit/mininit.h" \
  "$workspace/linux-mininit/check-console-contract.sh" \
  "$workspace/linux-mininit/initramfs-console.spec" \
  "$here/init/init-tiny.c" \
  "$kernel_build/arch/riscv/boot/Image" \
  "$here/driver/cheshire-idma.ko" \
  "$here/client/cheshire-idma-cache-test.ko" \
  "$here/out/initramfs-contents.txt" \
  "$here/out/initramfs-contents.verbose.txt" \
  "$here/out/cheshire-linux-dma-cache-legacy.dtb" \
  "$here/out/cheshire-linux-dma-cache-hpd.dtb" \
  "$here/out/fw_payload-legacy.elf" "$here/out/fw_payload-legacy.bin" \
  "$here/out/fw_payload-legacy.memh" \
  "$here/out/fw_payload-hpd.elf" "$here/out/fw_payload-hpd.bin" \
  "$here/out/fw_payload-hpd.memh" \
  "$here/binding/pulp,cheshire-idma.yaml" \
  "$here/out/dtschema-validation.txt" > "$here/out/SHA256SUMS.software"
printf 'Phase 11 software payloads ready\n'


