#!/usr/bin/env bash
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
workspace=$(cd -- "$here/.." && pwd)
linux_src=${LINUX_SRC:-$here/sources/linux-cheshire-cache}
pulp_linux="$here/sources/pulp-linux"
opensbi="$pulp_linux/opensbi"
kernel_build="$here/build/linux-mapping"
rootfs="$here/build/rootfs"
jobs=${BUILD_JOBS:-4}

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

mkdir -p -- "$here/out"
python3 "$here/scripts/check-dma-api-negative.py" \
	> "$here/out/dma-api-negative-contract.json"

mkdir -p -- "$kernel_build" "$rootfs/lib/modules" "$rootfs/proc" \
	"$rootfs/sys" "$rootfs/dev" "$here/out"
rm -f -- "$rootfs/lib/modules/cheshire-idma.ko" \
	"$rootfs/lib/modules/cheshire-idma-mapping-test.ko" \
	"$rootfs/lib/modules/cheshire-idma-api-negative.ko"

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
riscv64-linux-gnu-readelf -h "$rootfs/init" | grep -Eq \
	'Type:[[:space:]]+EXEC'
riscv64-linux-gnu-readelf -h "$rootfs/init" | grep -Eq \
	'Machine:[[:space:]]+RISC-V'
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

dtc -I dts -O dtb -o "$here/out/cheshire-linux-dma-mapping-direct.dtb" \
	"$here/dts/cheshire-linux-dma-mapping.dts"
dtc -I dts -O dtb -o "$here/out/cheshire-linux-dma-mapping-swiotlb.dtb" \
	"$here/dts/cheshire-linux-dma-mapping-swiotlb.dts"
dtc -I dts -O dtb -o "$here/out/cheshire-linux-dma-api-negative.dtb" \
	"$here/dts/cheshire-linux-dma-api-negative.dts"
for dtb in "$here/out/cheshire-linux-dma-mapping-direct.dtb" \
	   "$here/out/cheshire-linux-dma-mapping-swiotlb.dtb" \
	   "$here/out/cheshire-linux-dma-api-negative.dtb"; do
	[[ $(fdtget "$dtb" /chosen bootargs) == *'dma_debug_entries=1024'* ]]
done
negative_bootargs=$(fdtget \
	"$here/out/cheshire-linux-dma-api-negative.dtb" /chosen bootargs)
[[ $negative_bootargs == *'dma_api_negative=1'* ]]
[[ $negative_bootargs == \
	*'dma_debug_driver=cheshire-idma-irq-investigation'* ]]

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
grep -qx 'CONFIG_DMA_DIRECT_REMAP=y' "$kernel_build/.config"
grep -qx 'CONFIG_SWIOTLB=y' "$kernel_build/.config"
grep -qx '# CONFIG_SWIOTLB_DYNAMIC is not set' "$kernel_build/.config"

make -C "$linux_src" O="$kernel_build" ARCH=riscv \
	CROSS_COMPILE=riscv64-linux-gnu- -j"$jobs" vmlinux modules
make -C "$linux_src" O="$kernel_build" ARCH=riscv \
	CROSS_COMPILE=riscv64-linux-gnu- M="$here/driver" -j"$jobs" modules
make -C "$linux_src" O="$kernel_build" ARCH=riscv \
	CROSS_COMPILE=riscv64-linux-gnu- M="$here/client" -j"$jobs" modules
cp "$here/driver/cheshire-idma.ko" "$rootfs/lib/modules/cheshire-idma.ko"
cp "$here/client/cheshire-idma-mapping-test.ko" \
	"$rootfs/lib/modules/cheshire-idma-mapping-test.ko"
cp "$here/client/cheshire-idma-api-negative.ko" \
	"$rootfs/lib/modules/cheshire-idma-api-negative.ko"
touch "$rootfs"
make -C "$linux_src" O="$kernel_build" ARCH=riscv \
	CROSS_COMPILE=riscv64-linux-gnu- -j"$jobs" Image

build_firmware() {
	local mode=$1 dtb=$2 opensbi_build firmware
	opensbi_build="$here/build/opensbi-mapping-$mode"
	mkdir -p -- "$opensbi_build"
	make -C "$opensbi" O="$opensbi_build" PLATFORM=fpga/cheshire \
		CROSS_COMPILE=riscv64-linux-gnu- \
		FW_PAYLOAD_PATH="$kernel_build/arch/riscv/boot/Image" \
		FW_FDT_PATH="$dtb" FW_OPTIONS=0x1 \
		'platform-cflags-y=-std=gnu17' -j"$jobs"
	firmware="$opensbi_build/platform/fpga/cheshire/firmware"
	cp "$firmware/fw_payload.elf" "$here/out/fw_payload-$mode.elf"
	cp "$firmware/fw_payload.bin" "$here/out/fw_payload-$mode.bin"
	riscv64-linux-gnu-objcopy -O verilog "$firmware/fw_payload.elf" \
		"$here/out/fw_payload-$mode.memh"
}

build_firmware direct "$here/out/cheshire-linux-dma-mapping-direct.dtb"
build_firmware swiotlb "$here/out/cheshire-linux-dma-mapping-swiotlb.dtb"
build_firmware negative "$here/out/cheshire-linux-dma-api-negative.dtb"

cpio -it < "$kernel_build/usr/initramfs_data.cpio" \
	> "$here/out/initramfs-contents.txt"
cpio -itv < "$kernel_build/usr/initramfs_data.cpio" \
	> "$here/out/initramfs-contents.verbose.txt"
grep -Eq '^crw-------[[:space:]].*[[:space:]]5,[[:space:]]+1[[:space:]].*dev/console$' \
	"$here/out/initramfs-contents.verbose.txt"
grep -qx 'lib/modules/cheshire-idma.ko' "$here/out/initramfs-contents.txt"
grep -qx 'lib/modules/cheshire-idma-mapping-test.ko' \
	"$here/out/initramfs-contents.txt"
grep -qx 'lib/modules/cheshire-idma-api-negative.ko' \
	"$here/out/initramfs-contents.txt"

sha256sum \
	"$rootfs/init" \
	"$workspace/linux-mininit/start.S" \
	"$workspace/linux-mininit/mininit.h" \
	"$workspace/linux-mininit/check-console-contract.sh" \
	"$workspace/linux-mininit/initramfs-console.spec" \
	"$here/init/init-tiny.c" \
	"$here/config/linux.fragment" \
	"$here/binding/pulp,cheshire-idma.yaml" \
	"$here/driver/Makefile" \
	"$here/driver/cheshire-idma.c" \
	"$here/client/Makefile" \
	"$here/client/cheshire-idma-mapping-test.c" \
	"$here/client/cheshire-idma-api-negative.c" \
	"$here/dts/cheshire-linux-dma-mapping.dts" \
	"$here/dts/cheshire-linux-dma-mapping-swiotlb.dts" \
	"$here/dts/cheshire-linux-dma-api-negative.dts" \
	"$here/scripts/build-software.sh" \
	"$here/scripts/check-dma-api-negative.py" \
	"$here/out/dma-api-negative-contract.json" \
	"$here/out/initramfs-contents.txt" \
	"$here/out/initramfs-contents.verbose.txt" \
	"$kernel_build/arch/riscv/boot/Image" \
	"$here/driver/cheshire-idma.ko" \
	"$here/client/cheshire-idma-mapping-test.ko" \
	"$here/client/cheshire-idma-api-negative.ko" \
	"$here/out/cheshire-linux-dma-mapping-direct.dtb" \
	"$here/out/cheshire-linux-dma-mapping-swiotlb.dtb" \
	"$here/out/cheshire-linux-dma-api-negative.dtb" \
	"$here/out/fw_payload-direct.elf" \
	"$here/out/fw_payload-direct.bin" \
	"$here/out/fw_payload-direct.memh" \
	"$here/out/fw_payload-swiotlb.elf" \
	"$here/out/fw_payload-swiotlb.bin" \
	"$here/out/fw_payload-swiotlb.memh" \
	"$here/out/fw_payload-negative.elf" \
	"$here/out/fw_payload-negative.bin" \
	"$here/out/fw_payload-negative.memh" \
	"$here/out/dtschema-validation.txt" \
	> "$here/out/SHA256SUMS.software"

printf 'Mapping payloads ready: %s, %s, and %s\n' \
	"$here/out/fw_payload-direct.elf" \
	"$here/out/fw_payload-swiotlb.elf" \
	"$here/out/fw_payload-negative.elf"
