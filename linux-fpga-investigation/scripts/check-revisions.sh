#!/usr/bin/env bash
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
workspace=$(cd -- "$here/.." && pwd)
linux_src=${LINUX_SRC:-$here/sources/linux-cheshire-cache}

record() {
  local label=$1 tree=$2
  printf '%-16s %s  %s\n' "$label" "$(git -C "$tree" rev-parse HEAD)" "$tree"
}

record Cheshire "$workspace/cheshire"
record CVA6 "$workspace/cheshire/.bender/git/checkouts/cva6-20c9d7cbe0dd6995"
record iDMA "$workspace/cheshire/.bender/git/checkouts/idma-77bf7fa56d324e6a"
record Linux "$linux_src"
record pulp-linux "$here/sources/pulp-linux"
record OpenSBI "$here/sources/pulp-linux/opensbi"
record cva6-sdk "$here/sources/cva6-sdk"
printf '%-16s %s\n' 'Bender' "$("$workspace/.tools/bin/bender" --version)"
printf '%-16s %s\n' 'Verilator' "$("$workspace/.tools/verilator-5.052/bin/verilator" --version)"
printf '%-16s %s\n' 'RISC-V GCC' "$(riscv64-linux-gnu-gcc --version | sed -n '1p')"
printf '%-16s %s\n' 'dtc' "$(dtc --version)"
