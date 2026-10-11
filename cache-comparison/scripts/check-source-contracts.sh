#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
workspace=$(cd -- "$here/.." && pwd)

cheshire="$workspace/cheshire"
cva6="$workspace/linux-fpga-investigation/sources/cva6-no-trace"
linux="$workspace/linux-fpga-investigation/sources/linux-cheshire-cache"
dts="$workspace/linux-fpga-investigation/dts/cheshire-linux-dma.dts"
build_script="$workspace/linux-fpga-investigation/scripts/build-sim-no-trace.sh"

cheshire_rev=292d2c091ffed3e194b0f437b5b3460813905e26
cva6_rev=4c02b24fe7c04690f626776a92274da24f80d1da
linux_rev=388b607d107c07aaade04c7f22f344cab6bdccd3

checks=0

die() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

pass() {
  checks=$((checks + 1))
  printf 'PASS: %s\n' "$*"
}

require_file() {
  [[ -f $1 ]] || die "missing file: $1"
}

require_literal() {
  local file=$1 literal=$2 label=$3
  grep -Fq -- "$literal" "$file" || die "$label"
  pass "$label"
}

require_regex() {
  local file=$1 regex=$2 label=$3
  grep -Eq -- "$regex" "$file" || die "$label"
  pass "$label"
}

reject_regex() {
  local file=$1 regex=$2 label=$3
  if grep -Eq -- "$regex" "$file"; then
    die "$label"
  fi
  pass "$label"
}

require_hash() {
  local file=$1 expected=$2 label=$3 actual
  actual=$(sha256sum "$file")
  actual=${actual%% *}
  [[ $actual == "$expected" ]] ||
    die "$label (expected $expected, found $actual)"
  pass "$label"
}

for path in \
  "$cheshire/Bender.yml" \
  "$cheshire/hw/cheshire_pkg.sv" \
  "$cheshire/hw/cheshire_soc.sv" \
  "$cheshire/docs/um/arch.md" \
  "$cva6/Bender.yml" \
  "$cva6/core/include/config_pkg.sv" \
  "$cva6/core/include/ariane_pkg.sv" \
  "$cva6/core/include/cv64a6_imafdchsclic_sv39_wb_config_pkg.sv" \
  "$cva6/core/include/cv64a6_imafdchsclic_sv39_hpdcache_config_pkg.sv" \
  "$cva6/core/include/cv64a6_imafdchsclic_sv39_config_pkg.sv" \
  "$cva6/core/include/cv64a6_imafdc_sv39_hpdcache_wb_config_pkg.sv" \
  "$cva6/core/cache_subsystem/cva6_hpdcache_if_adapter.sv" \
  "$cva6/core/cache_subsystem/cva6_hpdcache_wrapper.sv" \
  "$cva6/core/cache_subsystem/miss_handler.sv" \
  "$cva6/core/cache_subsystem/wt_axi_adapter.sv" \
  "$cva6/core/cache_subsystem/wt_l15_adapter.sv" \
  "$cva6/core/commit_stage.sv" \
  "$linux/arch/riscv/mm/cache-ops.c" \
  "$linux/arch/riscv/include/asm/mmio.h" \
  "$dts" \
  "$build_script"
do
  require_file "$path"
done
pass "all source-contract inputs exist"

[[ $(git -C "$cheshire" rev-parse HEAD) == "$cheshire_rev" ]] ||
  die "unexpected Cheshire revision"
pass "Cheshire revision is pinned"

[[ $(git -C "$cva6" rev-parse HEAD) == "$cva6_rev" ]] ||
  die "unexpected CVA6 revision"
pass "CVA6 revision is pinned"

[[ $(git -C "$linux" rev-parse HEAD) == "$linux_rev" ]] ||
  die "unexpected Linux revision"
pass "Linux base revision is pinned"

git -C "$cheshire" diff --quiet HEAD -- \
  Bender.yml hw/cheshire_pkg.sv hw/cheshire_soc.sv docs/um/arch.md ||
  die "checked Cheshire sources differ from the pinned commit"
pass "checked Cheshire sources are unmodified"

git -C "$cva6" diff --quiet HEAD -- \
  Bender.yml \
  core/include/config_pkg.sv \
  core/include/ariane_pkg.sv \
  core/include/cv64a6_imafdchsclic_sv39_wb_config_pkg.sv \
  core/include/cv64a6_imafdchsclic_sv39_hpdcache_config_pkg.sv \
  core/include/cv64a6_imafdchsclic_sv39_config_pkg.sv \
  core/include/cv64a6_imafdc_sv39_hpdcache_wb_config_pkg.sv \
  core/cache_subsystem/cva6_hpdcache_if_adapter.sv \
  core/cache_subsystem/cva6_hpdcache_wrapper.sv \
  core/cache_subsystem/miss_handler.sv \
  core/cache_subsystem/wt_axi_adapter.sv \
  core/cache_subsystem/wt_l15_adapter.sv \
  core/commit_stage.sv ||
  die "checked CVA6 sources differ from the pinned commit"
pass "checked CVA6 sources are unmodified"

# Exact hashes make the audit reproducible even when a repository remains at
# the same commit while investigation patches are present elsewhere.
require_hash "$cheshire/Bender.yml" \
  b595dd5e700c395958f3d6bf4a78ba10a5f2ed5eb7514471dfde515399391138 \
  "Cheshire dependency declaration hash matches"
require_hash "$cheshire/hw/cheshire_pkg.sv" \
  022b71354215f89fac0bb9eb9b808caf6341e3551a2ca861c96c5776683274ba \
  "Cheshire CVA6 configuration glue hash matches"
require_hash "$cheshire/hw/cheshire_soc.sv" \
  d3edf42da795a5d9253519de44e1d7eebc5519207f7805e4b5cfb58c73a7c203 \
  "Cheshire SoC hash matches"
require_hash "$cva6/core/include/ariane_pkg.sv" \
  81ea34908a5440f3789616b72592cb128a4dffbdb5a580061463b7e551bcde92 \
  "legacy global invalidation policy hash matches"
require_hash "$cva6/core/include/cv64a6_imafdchsclic_sv39_wb_config_pkg.sv" \
  08f476082ffac589fee1f48c4a1abb8f51b965528a08f9c30a648201fc9193d1 \
  "legacy WB configuration hash matches"
require_hash "$cva6/core/include/cv64a6_imafdchsclic_sv39_hpdcache_config_pkg.sv" \
  ae5180d093d90277503f86c0f66cd80870900bb7d4252c1486147baee2011068 \
  "locked CLIC HPDcache configuration hash matches"
require_hash "$cva6/core/include/cv64a6_imafdc_sv39_hpdcache_wb_config_pkg.sv" \
  8c24a1d6aadab75b8e53a9ffebc9f7c5d6b2c0a7a2194443f389054d8e19d27f \
  "HPDcache WB reference configuration hash matches"
require_hash "$cva6/core/cache_subsystem/cva6_hpdcache_if_adapter.sv" \
  c5d38c8a779755e1693184ed35f887920ca3433653d22aeaddf57eedd4092cb9 \
  "HPDcache CMO adapter hash matches"
require_hash "$cva6/core/cache_subsystem/miss_handler.sv" \
  d7f107161a2ac8b63f4de18a51e0daf83b497c0a670ff4af29ce5586eff38449 \
  "legacy WB miss-handler hash matches"
require_hash "$cva6/core/cache_subsystem/wt_axi_adapter.sv" \
  8141dfb8af2f098529b421a1b281bb167a74f4e79bcf7881a795aad3c286d3dd \
  "WT invalidation adapter hash matches"
require_hash "$linux/arch/riscv/mm/cache-ops.c" \
  f3891e11058f3bb6ea92b7f5c10ed99ba104da296416912204d8ac0bf4d280c3 \
  "as-built Linux Cheshire cache-hook hash matches"
require_hash "$dts" \
  335aaef568863462e0b8c787d3c0b5b99ba2e270553ad953564414759bbc7036 \
  "noncoherent test DT hash matches"

wb_cfg="$cva6/core/include/cv64a6_imafdchsclic_sv39_wb_config_pkg.sv"
hpd_cfg="$cva6/core/include/cv64a6_imafdchsclic_sv39_hpdcache_config_pkg.sv"
hpd_wb_cfg="$cva6/core/include/cv64a6_imafdc_sv39_hpdcache_wb_config_pkg.sv"
wt_cfg="$cva6/core/include/cv64a6_imafdchsclic_sv39_config_pkg.sv"
config_pkg="$cva6/core/include/config_pkg.sv"
ariane_pkg="$cva6/core/include/ariane_pkg.sv"
hpd_adapter="$cva6/core/cache_subsystem/cva6_hpdcache_if_adapter.sv"
hpd_wrapper="$cva6/core/cache_subsystem/cva6_hpdcache_wrapper.sv"
miss_handler="$cva6/core/cache_subsystem/miss_handler.sv"
wt_adapter="$cva6/core/cache_subsystem/wt_axi_adapter.sv"
cva6_core="$cva6/core/cva6.sv"
cheshire_pkg="$cheshire/hw/cheshire_pkg.sv"
cheshire_soc="$cheshire/hw/cheshire_soc.sv"

# Legacy WB contract.
require_literal "$build_script" \
  '-t rtl -t cva6 -t cv64a6_imafdchsclic_sv39_wb' \
  "Linux simulator selects the legacy WB target"
require_literal "$wb_cfg" \
  'CVA6ConfigDcacheType = config_pkg::WB;' \
  "legacy target selects DCacheType WB"
require_literal "$wb_cfg" \
  'CVA6ConfigDcacheLineWidth = 128;' \
  "legacy target has 128-bit D-cache lines"
require_literal "$wb_cfg" \
  "CVA6ConfigDcacheFlushOnFence = 1'b1;" \
  "legacy target flushes D-cache on FENCE"
require_literal "$wb_cfg" \
  "CVA6ConfigDcacheInvalidateOnFlush = 1'b0;" \
  "legacy target retains the HPD-only invalidate field at zero"
require_literal "$ariane_pkg" \
  "localparam logic INVALIDATE_ON_FLUSH = 1'b1;" \
  "legacy cache global flush policy invalidates"
require_literal "$miss_handler" \
  "data_o.valid = INVALIDATE_ON_FLUSH ? 1'b0 : 1'b1;" \
  "legacy dirty-line flush clears validity"
require_literal "$miss_handler" \
  "be_o.vldrty = INVALIDATE_ON_FLUSH ? '1 : '0;" \
  "legacy clean-line flush clears validity"
require_literal "$linux/arch/riscv/mm/cache-ops.c" \
  'RISCV_FENCE(rw, rw);' \
  "Linux Cheshire hook issues the whole-cache FENCE"

# HPDcache is available, but the CLIC package needs the explicitly documented
# three-knob correction before it is a runnable WB comparison.
require_literal "$cva6/Bender.yml" \
  'target: cv64a6_imafdchsclic_sv39_hpdcache' \
  "CVA6 exports the CLIC HPDcache target"
require_literal "$hpd_cfg" \
  'CVA6ConfigDcacheType = config_pkg::HPDCACHE;' \
  "locked CLIC HPD target contains the obsolete HPDCACHE selector"
reject_regex "$config_pkg" \
  '^[[:space:]]*HPDCACHE[[:space:]]*=' \
  "the obsolete bare HPDCACHE enum is absent"
require_literal "$hpd_cfg" \
  "CVA6ConfigDcacheFlushOnFence = 1'b0;" \
  "locked CLIC HPD target currently disables flush on FENCE"
require_literal "$hpd_cfg" \
  "CVA6ConfigDcacheInvalidateOnFlush = 1'b0;" \
  "locked CLIC HPD target currently disables invalidate on flush"
require_literal "$hpd_cfg" \
  'CVA6ConfigDcacheLineWidth = 128;' \
  "locked CLIC HPD target has 128-bit D-cache lines"
require_literal "$hpd_wb_cfg" \
  'CVA6ConfigDcacheType = config_pkg::HPDCACHE_WB;' \
  "same-pin HPD WB package proves the intended selector"
require_literal "$hpd_adapter" \
  'hpdcache_pkg::HPDCACHE_REQ_CMO_FLUSH_INVAL_ALL' \
  "HPD adapter has full flush+invalidate CMO"
require_literal "$hpd_adapter" \
  'hpdcache_pkg::HPDCACHE_REQ_CMO_FLUSH_ALL' \
  "HPD adapter has distinct flush-only CMO"
require_literal "$hpd_wrapper" \
  'assign snoop_valid[0] = dcache_req_valid[1] & dcache_req_ready[1],' \
  "HPD snoop[0] is internally driven by a core load port"
require_literal "$hpd_wrapper" \
  'assign snoop_valid[1] = dcache_req_valid[NumPorts-1] & dcache_req_ready[NumPorts-1],' \
  "HPD snoop[1] is internally driven by the core store/AMO port"

# WT provides the bounded building block for a future hardware-coherent
# reference cell, but Cheshire does not connect iDMA to it today.
require_literal "$wt_cfg" \
  'CVA6ConfigDcacheType = config_pkg::WT;' \
  "CLIC WT target selects DCacheType WT"
require_literal "$wt_cfg" \
  'CVA6ConfigDcacheLineWidth = 128;' \
  "CLIC WT target has 128-bit D-cache lines"
require_literal "$wt_cfg" \
  "CVA6ConfigDcacheFlushOnFence = 1'b0;" \
  "CLIC WT target does not flush the cache on FENCE"
require_literal "$cva6_core" \
  'assign no_st_pending_commit = no_st_pending_ex & dcache_commit_wbuffer_empty;' \
  "FENCE commit ordering includes the WT write buffer"
require_literal "$wt_adapter" \
  'if (inval_valid_i) begin' \
  "WT AXI adapter accepts an external invalidation request"
require_literal "$wt_adapter" \
  'there are no other transactions when a coprocessor has pending stores.' \
  "WT invalidation source documents its transaction-serialization assumption"
require_literal "$wt_adapter" \
  'dcache_rtrn_type_d    = wt_cache_pkg::DCACHE_INV_REQ;' \
  "WT AXI adapter converts that request to a D-cache invalidation"

# Current Cheshire coherence audit.
require_literal "$cheshire_pkg" \
  'ret.NOCType               = config_pkg::NOC_TYPE_AXI4_ATOP;' \
  "Cheshire forces CVA6 onto ordinary AXI4+ATOP"
require_literal "$cheshire_pkg" \
  'ret.CvxifEn               = 0;' \
  "Cheshire disables the CVXIF route that could originate WT invalidations"
require_literal "$cheshire_soc" \
  'axi_xbar #(' \
  "Cheshire uses the ordinary AXI crossbar"
require_literal "$cheshire_soc" \
  'axi_in_req[AxiIn.dma]         = axi_dma_req;' \
  "iDMA joins Cheshire as an ordinary AXI manager"
reject_regex "$cheshire_soc" \
  '(^|[^[:alnum:]_])(ACE|CHI)([^[:alnum:]_]|$)|snoop_(valid|addr|ready)|dcache_inval_(valid|addr|ready)' \
  "Cheshire SoC exposes no ACE/CHI/snoop/D-cache-invalidation path"
reject_regex "$dts" \
  '^[[:space:]]*dma-coherent[[:space:]]*;' \
  "current iDMA DT does not claim dma-coherent"
require_literal "$dts" \
  'the iDMA has no hardware-coherent path into L1.' \
  "current DT documents the noncoherent hardware contract"

# OpenPiton source capability is deliberately separated from current Cheshire.
require_literal "$config_pkg" \
  'NOC_TYPE_L15_BIG_ENDIAN,' \
  "CVA6 defines an OpenPiton L15 NOC type"
require_literal "$cva6/core/cache_subsystem/wt_l15_adapter.sv" \
  'dcache_rtrn_o.inv.vld = rtrn_fifo_data.l15_inval_dcache_inval;' \
  "CVA6 L15 adapter can receive directory-driven D-cache invalidations"

printf 'SUMMARY: PASS checks=%d current_cheshire_dma_coherent=no hpdcache_patch_required=yes coherent_reference_bridge_required=yes\n' \
  "$checks"
