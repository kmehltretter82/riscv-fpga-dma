#!/usr/bin/env bash
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
workspace=$(cd -- "$here/.." && pwd)
linux_src="$here/sources/linux-cheshire-cache"
pulp_linux="$here/sources/pulp-linux"
opensbi="$pulp_linux/opensbi"
kernel_build="$here/build/linux-coherent"
seed_build="$workspace/linux-cache-investigation/build/linux-cache"
rootfs="$here/build/rootfs"
jobs=${BUILD_JOBS:-2}

mkdir -p -- "$rootfs/lib/modules" "$rootfs/proc" "$rootfs/sys" \
  "$rootfs/dev" "$here/build/dts" "$here/out"

# Reuse only compiled objects from the identical locked source/config build.
# The copied tree is private; olddefconfig, modules, initramfs, Image and
# OpenSBI are regenerated against this subtree's authored inputs.
if [[ ! -f "$kernel_build/.config" ]]; then
  cp -a -- "$seed_build" "$kernel_build"
fi

riscv64-linux-gnu-gcc -nostdlib -static -Os -Wall -Wextra -Werror \
  -ffreestanding -fno-stack-protector -fno-pie -no-pie \
  -fno-asynchronous-unwind-tables -fno-unwind-tables \
  -ffunction-sections -fdata-sections \
  -march=rv64imac_zicsr_zifencei -mabi=lp64 \
  -I"$workspace/linux-mininit" \
  -Wl,-e,_start,--gc-sections,--build-id=none \
  -o "$rootfs/init" \
  "$workspace/linux-mininit/start.S" "$here/init/init-tiny.c"
(( $(stat -c %s "$rootfs/init") <= 16384 ))
! riscv64-linux-gnu-readelf -l "$rootfs/init" | grep -q INTERP
! riscv64-linux-gnu-nm -u "$rootfs/init" | grep -q .
"$workspace/linux-mininit/check-console-contract.sh" \
  "$rootfs/init" "$here/init/init-tiny.c"

cp "$here/dts/cheshire-linux-dma-cache.dts.in" \
  "$here/build/dts/cheshire-linux-dma-coherent.dts"
dtc -I dts -O dtb -o "$here/out/cheshire-linux-dma-coherent.dtb" \
  "$here/build/dts/cheshire-linux-dma-coherent.dts"

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
grep -qx 'CONFIG_LOCALVERSION="-cheshire-idma-coherent-investigation"' \
  "$kernel_build/.config"

make -C "$linux_src" O="$kernel_build" ARCH=riscv \
  CROSS_COMPILE=riscv64-linux-gnu- -j"$jobs" vmlinux modules
make -C "$linux_src" O="$kernel_build" ARCH=riscv \
  CROSS_COMPILE=riscv64-linux-gnu- M="$here/driver" -j"$jobs" modules
make -C "$linux_src" O="$kernel_build" ARCH=riscv \
  CROSS_COMPILE=riscv64-linux-gnu- M="$here/client" -j"$jobs" \
  KBUILD_EXTRA_SYMBOLS="$here/driver/Module.symvers" modules
cp "$here/driver/cheshire-idma.ko" "$rootfs/lib/modules/cheshire-idma.ko"
cp "$here/client/cheshire-idma-cache-test.ko" \
  "$rootfs/lib/modules/cheshire-idma-cache-test.ko"
touch "$rootfs"
make -C "$linux_src" O="$kernel_build" ARCH=riscv \
  CROSS_COMPILE=riscv64-linux-gnu- -j"$jobs" Image

opensbi_build="$here/build/opensbi-coherent"
make -C "$opensbi" O="$opensbi_build" PLATFORM=fpga/cheshire \
  CROSS_COMPILE=riscv64-linux-gnu- \
  FW_PAYLOAD_PATH="$kernel_build/arch/riscv/boot/Image" \
  FW_FDT_PATH="$here/out/cheshire-linux-dma-coherent.dtb" \
  FW_OPTIONS=0x1 'platform-cflags-y=-std=gnu17' -j"$jobs"
firmware="$opensbi_build/platform/fpga/cheshire/firmware"
cp "$firmware/fw_payload.elf" "$here/out/fw_payload-coherent.elf"
cp "$firmware/fw_payload.bin" "$here/out/fw_payload-coherent.bin"
riscv64-linux-gnu-objcopy -O verilog "$firmware/fw_payload.elf" \
  "$here/out/fw_payload-coherent.memh"

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
  "$here/driver/cheshire-idma.c" \
  "$here/client/cheshire-idma-cache-test.c" \
  "$here/config/linux.fragment" \
  "$here/dts/cheshire-linux-dma-cache.dts.in" \
  "$here/binding/pulp,cheshire-idma.yaml" \
  "$kernel_build/.config" \
  "$kernel_build/arch/riscv/boot/Image" \
  "$here/driver/cheshire-idma.ko" \
  "$here/client/cheshire-idma-cache-test.ko" \
  "$here/out/cheshire-linux-dma-coherent.dtb" \
  "$here/out/initramfs-contents.txt" \
  "$here/out/initramfs-contents.verbose.txt" \
  "$here/out/fw_payload-coherent.elf" \
  "$here/out/fw_payload-coherent.bin" \
  "$here/out/fw_payload-coherent.memh" \
  > "$here/out/SHA256SUMS.software"
printf 'Phase 11 coherent Linux payload ready\n'
