#!/usr/bin/env bash
set -euo pipefail

plan=/home/karl/linux-work/dmadebug2/riscv-fpga-dma/linux-error-plan
cheshire=/home/karl/linux-work/dmadebug2/riscv-fpga-dma/cheshire
linux=/home/karl/linux-work/dmadebug2/riscv-fpga-dma/linux-fpga-investigation/sources/linux-cheshire-cache

sha256sum -c "$plan/SOURCE-HASHES.txt" >/dev/null

check_rev() {
    local path=$1 expected=$2 actual
    actual=$(git -C "$path" rev-parse HEAD)
    [[ $actual == "$expected" ]] || {
        printf 'revision mismatch: %s: expected %s, got %s\n' \
            "$path" "$expected" "$actual" >&2
        exit 1
    }
}

check_rev "$cheshire" 292d2c091ffed3e194b0f437b5b3460813905e26
check_rev "$cheshire/.bender/git/checkouts/cva6-20c9d7cbe0dd6995" \
    4c02b24fe7c04690f626776a92274da24f80d1da
check_rev "$cheshire/.bender/git/checkouts/idma-77bf7fa56d324e6a" \
    ff5d56fffb3767814db88d6bf8f381974ea33aa5
check_rev "$cheshire/.bender/git/checkouts/unbent-a93c32aef5b319fd" \
    e9c9d5cfb635f2d4668c816ce9235798cfecb297
check_rev "$cheshire/.bender/git/checkouts/axi-ecdc900686449c15" \
    78831b6feba265d5ee2683bbf42b4150f8a35c43
check_rev "$cheshire/.bender/git/checkouts/common_cells-7f7ae0f5e6bf7fb5" \
    9afda9abb565971649c2aa0985639c096f351171
check_rev "$cheshire/.bender/git/checkouts/opentitan_peripherals-7b624fb57f78de9a" \
    cd3153de2783abd3d03d0595e6c4b32413c62f14
check_rev "$linux" 388b607d107c07aaade04c7f22f344cab6bdccd3

linux_diff_hash=$(git -C "$linux" diff --binary | sha256sum | cut -d' ' -f1)
[[ $linux_diff_hash == e95be8bdb907a64f7243971581e38dbbc19dfaa642a8c82c3cda30ba816281ac ]]

rg -q 'BUS_ERR_BASE_ADDR = 64.h3009000' "$cheshire/hw/cheshire_addrmap_pkg.sv"
rg -q 'RegBusErrDma[[:space:]]*= 1' "$cheshire/hw/cheshire_pkg.sv"
rg -q 'NumStoredErrors[[:space:]]*\([[:space:]]*4' "$cheshire/hw/cheshire_soc.sv"
rg -q 'DropOldest[[:space:]]*\([[:space:]]*1.b0' "$cheshire/hw/cheshire_soc.sv"
rg -q 'parameter int NumSrc = 32' \
    "$cheshire/.bender/git/checkouts/opentitan_peripherals-7b624fb57f78de9a/src/rv_plic/rtl/rv_plic_reg_pkg.sv"
rg -q 'opentitan_peripherals-.*/src/rv_plic/rtl/rv_plic_reg_pkg.sv' \
    /home/karl/linux-work/dmadebug2/riscv-fpga-dma/linux-fpga-investigation/build/sim/sources.f

(
    cd /home/karl/linux-work/dmadebug2/hwtest/riscv-cheshire-cva6-dma-errors-20261011
    python3 verify.py
) | grep -qx 'PASS: 399 evidence checks'

printf 'PASS: phase-7 design snapshot verified (53 source files, no build)\n'
