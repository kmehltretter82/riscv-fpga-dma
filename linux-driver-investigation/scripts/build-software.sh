#!/usr/bin/env bash
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
workspace=$(cd -- "$here/.." && pwd)
linux_src=${LINUX_SRC:-$here/sources/linux-cheshire-cache}
pulp_linux="$here/sources/pulp-linux"
opensbi="$pulp_linux/opensbi"
kernel_build="$here/build/linux-irq"
rootfs="$here/build/rootfs"
opensbi_build="$here/build/opensbi-irq"
jobs=${BUILD_JOBS:-4}
kernel_cmdline='console=ttyS0,1562500 quiet loglevel=4 rdinit=/init dma_debug_entries=1024'

check_revision() {
  local tree=$1 expected=$2 label=$3 actual
  actual=$(git -C "$tree" rev-parse HEAD)
  if [[ $actual != "$expected" ]]; then
    printf '%s revision mismatch: expected %s, got %s\n' \
      "$label" "$expected" "$actual" >&2
    exit 2
  fi
}

check_revision "$workspace/cheshire" \
  292d2c091ffed3e194b0f437b5b3460813905e26 Cheshire
check_revision "$linux_src" \
  388b607d107c07aaade04c7f22f344cab6bdccd3 Linux
check_revision "$pulp_linux" \
  2df607d83b38721c2fd419357c6bf6d1db12df32 pulp-linux
check_revision "$opensbi" \
  04c94d9c4014c570909036f893737e4af5e74744 OpenSBI

mkdir -p -- "$kernel_build" "$rootfs/lib/modules" "$rootfs/proc" \
  "$rootfs/sys" "$rootfs/dev" "$opensbi_build" "$here/out"

riscv64-linux-gnu-gcc -nostdlib -static -Os -Wall -Wextra -Werror \
  -ffreestanding -fno-stack-protector -fno-pie -no-pie \
  -fno-asynchronous-unwind-tables -fno-unwind-tables \
  -ffunction-sections -fdata-sections \
  -march=rv64imac_zicsr_zifencei -mabi=lp64 \
  -I"$workspace/linux-mininit" \
  -Wl,-e,_start,--gc-sections,--build-id=none \
  -o "$rootfs/init" \
  "$workspace/linux-mininit/start.S" "$here/init/init-tiny.c"
if (( $(stat -c %s "$rootfs/init") > 16384 )); then
  printf 'freestanding init exceeds 16 KiB: %s bytes\n' \
    "$(stat -c %s "$rootfs/init")" >&2
  exit 2
fi
riscv64-linux-gnu-readelf -h "$rootfs/init" | grep -Eq 'Type:[[:space:]]+EXEC'
riscv64-linux-gnu-readelf -h "$rootfs/init" | grep -Eq 'Machine:[[:space:]]+RISC-V'
if riscv64-linux-gnu-readelf -l "$rootfs/init" | grep -q INTERP; then
  printf 'freestanding init unexpectedly has an ELF interpreter\n' >&2
  exit 2
fi
if riscv64-linux-gnu-nm -u "$rootfs/init" | grep -q .; then
  printf 'freestanding init has undefined symbols\n' >&2
  riscv64-linux-gnu-nm -u "$rootfs/init" >&2
  exit 2
fi
"$workspace/linux-mininit/check-console-contract.sh" \
  "$rootfs/init" "$here/init/init-tiny.c"
dtc -I dts -O dtb -o "$here/out/cheshire-linux-dma-irq.dtb" \
  "$here/dts/cheshire-linux-dma-irq.dts"

# Start from the official pulp-linux Cheshire choices, then merge the bounded
# investigation config.  allnoconfig makes repeated invocations deterministic
# without requiring source-tree changes or removal of the output directory.
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
grep -Fx "CONFIG_CMDLINE=\"$kernel_cmdline\"" "$kernel_build/.config"
grep -Fx 'CONFIG_CMDLINE_FORCE=y' "$kernel_build/.config"

# vmlinux and Module.symvers must exist before the external DMAengine module's
# modpost pass.  The final Image is rebuilt after both modules enter rootfs.
make -C "$linux_src" O="$kernel_build" ARCH=riscv \
  CROSS_COMPILE=riscv64-linux-gnu- -j"$jobs" vmlinux modules
make -C "$linux_src" O="$kernel_build" ARCH=riscv \
  CROSS_COMPILE=riscv64-linux-gnu- M="$here/driver" -j"$jobs" modules
make -C "$linux_src" O="$kernel_build" ARCH=riscv \
  CROSS_COMPILE=riscv64-linux-gnu- M="$here/client" -j"$jobs" modules
cp "$here/driver/cheshire-idma.ko" "$rootfs/lib/modules/cheshire-idma.ko"
cp "$here/client/cheshire-idma-irq-test.ko" \
  "$rootfs/lib/modules/cheshire-idma-irq-test.ko"
touch "$rootfs"
make -C "$linux_src" O="$kernel_build" ARCH=riscv \
  CROSS_COMPILE=riscv64-linux-gnu- -j"$jobs" Image

# GCC 15 defaults to C23, where bool is a keyword.  This old pinned OpenSBI
# revision defines bool itself, so select GNU C17 without editing that repo.
make -C "$opensbi" O="$opensbi_build" PLATFORM=fpga/cheshire \
  CROSS_COMPILE=riscv64-linux-gnu- \
  FW_PAYLOAD_PATH="$kernel_build/arch/riscv/boot/Image" \
  FW_FDT_PATH="$here/out/cheshire-linux-dma-irq.dtb" \
  FW_OPTIONS=0x1 \
  'platform-cflags-y=-std=gnu17' -j"$jobs"

firmware="$opensbi_build/platform/fpga/cheshire/firmware"
cp "$firmware/fw_payload.elf" "$here/out/fw_payload.elf"
cp "$firmware/fw_payload.bin" "$here/out/fw_payload.bin"
riscv64-linux-gnu-objcopy -O verilog \
  "$firmware/fw_payload.elf" "$here/out/fw_payload.memh"

cpio -it < "$kernel_build/usr/initramfs_data.cpio" \
  > "$here/out/initramfs-contents.txt"
cpio -itv < "$kernel_build/usr/initramfs_data.cpio" \
  > "$here/out/initramfs-contents.verbose.txt"
grep -Eq '^crw-------[[:space:]].*[[:space:]]5,[[:space:]]+1[[:space:]].*dev/console$' \
  "$here/out/initramfs-contents.verbose.txt"
grep -qx 'lib/modules/cheshire-idma.ko' "$here/out/initramfs-contents.txt"
grep -qx 'lib/modules/cheshire-idma-irq-test.ko' \
  "$here/out/initramfs-contents.txt"

sha256sum \
  "$rootfs/init" \
  "$workspace/linux-mininit/start.S" \
  "$workspace/linux-mininit/mininit.h" \
  "$workspace/linux-mininit/check-console-contract.sh" \
  "$workspace/linux-mininit/initramfs-console.spec" \
  "$here/init/init-tiny.c" \
  "$kernel_build/arch/riscv/boot/Image" \
  "$here/driver/cheshire-idma.ko" \
  "$here/client/cheshire-idma-irq-test.ko" \
  "$here/out/cheshire-linux-dma-irq.dtb" \
  "$here/out/initramfs-contents.txt" \
  "$here/out/initramfs-contents.verbose.txt" \
  "$here/out/fw_payload.elf" \
  "$here/out/fw_payload.bin" \
  "$here/out/fw_payload.memh" \
  > "$here/out/SHA256SUMS.software"

printf 'IRQ software payload ready: %s\n' "$here/out/fw_payload.elf"
