#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
workspace=$(cd -- "$here/.." && pwd)
base_cva6="$workspace/linux-fpga-investigation/sources/cva6-no-trace"
cheshire_irq="$here/sources/cheshire-irq"
idma_abort="$here/sources/idma-abort"

die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

"$workspace/cache-comparison/scripts/check-source-contracts.sh" >/dev/null
pass "pinned Phase 11 source audit passes"

[[ $(git -C "$cheshire_irq" rev-parse HEAD) == \
   292d2c091ffed3e194b0f437b5b3460813905e26 ]] ||
  die "unexpected Cheshire IRQ variant revision"
[[ $(git -C "$idma_abort" rev-parse HEAD) == \
   ff5d56fffb3767814db88d6bf8f381974ea33aa5 ]] ||
  die "unexpected iDMA abort variant revision"
[[ $(git -C "$base_cva6" rev-parse HEAD) == \
   4c02b24fe7c04690f626776a92274da24f80d1da ]] ||
  die "unexpected CVA6 revision"
pass "all RTL revisions match the locked campaign"

git -C "$cheshire_irq" diff --quiet -- \
  ':!hw/cheshire_idma_wrap.sv' ':!hw/cheshire_pkg.sv' \
  ':!hw/cheshire_soc.sv' || die "unexpected Cheshire IRQ variant edits"
git -C "$idma_abort" diff --quiet -- \
  ':!src/backend/idma_error_handler.sv' \
  ':!src/backend/tpl/idma_backend.sv.tpl' \
  ':!target/rtl/idma_backend_rw_axi.sv' \
  ':!target/rtl/idma_generated.sv' || die "unexpected iDMA variant edits"
git -C "$base_cva6" diff --quiet -- ':!core/cva6.sv' ||
  die "unexpected CVA6 no-trace variant edits"
pass "variant worktrees contain only their retained campaign changes"

while read -r expected file; do
  actual=$(sha256sum "$file")
  actual=${actual%% *}
  [[ $actual == "$expected" ]] || die "hash mismatch: $file"
done <<EOF
8d1ca8369d70b2fd2476f57402d7c01730dab28ec76b5034b719d5f950de2ef3 $cheshire_irq/hw/cheshire_idma_wrap.sv
283d225cd38cd19641cee42ef8d2c00f2d29738ffa639765fcde19018b229e69 $cheshire_irq/hw/cheshire_pkg.sv
fbdd7a9a16d660c0f084c728f996e274981280864d8ed74b7cd6481d0b45a6f9 $cheshire_irq/hw/cheshire_soc.sv
902ab87076553dfd0e8205c23f279a55070a93b62b0163d45e7e7bda6020250b $idma_abort/src/backend/idma_error_handler.sv
3b53f4afc817406535e92a9a0dfcd8423e28832fee0003f6a8b8e09d199b9bb9 $idma_abort/target/rtl/idma_backend_rw_axi.sv
f8a5c14a0aed9f14b37813ff0390453c2035cacd7dd81a214b6cb99d81d53b42 $idma_abort/target/rtl/idma_generated.sv
9fe2230dc1d6d92e38a489b871af255c949cf31e1f2653bd7e6cb5f350d291a4 $base_cva6/core/cva6.sv
EOF
pass "retained IRQ/iDMA/no-trace source hashes match"

git -C "$base_cva6" apply --check \
  "$here/patches/cva6-hpdcache-wb-fence-invalidate.patch" ||
  die "HPDcache correction no longer applies to the locked source"
grep -Fq 'CVA6ConfigDcacheType = config_pkg::HPDCACHE_WB;' \
  "$here/rtl-overrides/cv64a6_imafdchsclic_sv39_hpdcache_config_pkg.sv" ||
  die "HPDcache override does not select HPDCACHE_WB"
grep -Fq "CVA6ConfigDcacheFlushOnFence = 1'b1;" \
  "$here/rtl-overrides/cv64a6_imafdchsclic_sv39_hpdcache_config_pkg.sv" ||
  die "HPDcache override does not flush on FENCE"
grep -Fq "CVA6ConfigDcacheInvalidateOnFlush = 1'b1;" \
  "$here/rtl-overrides/cv64a6_imafdchsclic_sv39_hpdcache_config_pkg.sv" ||
  die "HPDcache override does not invalidate on flush"
grep -Fq 'CVA6ConfigWtDcacheWbufDepth = 7;' \
  "$here/rtl-overrides/cv64a6_imafdchsclic_sv39_hpdcache_config_pkg.sv" ||
  die "HPDcache override does not reserve the all-ones uncached ID"
pass "HPDcache WB/FENCE/invalidate and memory-ID corrections are exact and applicable"

if grep -Eq '^[[:space:]]*(read|write)[bwlq]\(' \
     "$here/driver/cheshire-idma.c"; then
  die "focused provider contains ordered MMIO"
fi
for primitive in __raw_writeq __raw_writel __raw_readl; do
  grep -Fq "$primitive" "$here/driver/cheshire-idma.c" ||
    die "focused provider lacks $primitive"
done
pass "focused provider uses only raw controller/error MMIO"

grep -Fq '#define TEST_LEN              256' \
  "$here/client/cheshire-idma-cache-test.c" || die "test length changed"
grep -Fq '#define DST_REGION_OFFSET     0x800' \
  "$here/client/cheshire-idma-cache-test.c" || die "cache-set split changed"
grep -Fq 'positive_cache_delta != 3' \
  "$here/client/cheshire-idma-cache-test.c" || die "positive exact gate absent"
grep -Fq 'stale_source_critical_delta' \
  "$here/client/cheshire-idma-cache-test.c" || die "stale-source gate absent"
grep -Fq 'stale_destination_critical_delta' \
  "$here/client/cheshire-idma-cache-test.c" || die "stale-destination gate absent"
pass "Linux client retains all three focused cache oracles"

if grep -Eq '(^|[[:space:]])dma-coherent([;[:space:]]|$)' \
     "$here/dts/cheshire-linux-dma-cache.dts.in"; then
  die "noncoherent Phase 11 DT contains dma-coherent"
fi
grep -Fq 'CONFIG_DMA_API_DEBUG=y' "$here/config/linux.fragment" ||
  die "DMA API debug is not enabled"
grep -Fq 'CONFIG_RISCV_CHESHIRE_CACHE_OPS=y' \
  "$here/config/linux.fragment" || die "Cheshire cache hook is not enabled"
pass "DT and Linux config retain the noncoherent debug contract"

printf 'PASS: Phase 11 executable source contracts verified\n'

