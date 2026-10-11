#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
workspace=$(cd -- "$here/.." && pwd)
cva6="$here/sources/cva6-no-trace"
cheshire="$here/sources/cheshire-irq"
idma="$here/sources/idma-abort"

die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

[[ $(git -C "$cva6" rev-parse HEAD) == \
   4c02b24fe7c04690f626776a92274da24f80d1da ]] ||
  die "unexpected CVA6 revision"
[[ $(git -C "$cheshire" rev-parse HEAD) == \
   292d2c091ffed3e194b0f437b5b3460813905e26 ]] ||
  die "unexpected Cheshire revision"
[[ $(git -C "$idma" rev-parse HEAD) == \
   ff5d56fffb3767814db88d6bf8f381974ea33aa5 ]] ||
  die "unexpected iDMA revision"
pass "locked campaign revisions match"

grep -Fq 'input logic [63:0] inval_addr_i' \
  "$cva6/core/cache_subsystem/wt_cache_subsystem.sv" ||
  die "WT cache lacks its upstream invalidation port"
grep -Fq 'dcache_rtrn_type_d    = wt_cache_pkg::DCACHE_INV_REQ;' \
  "$cva6/core/cache_subsystem/wt_axi_adapter.sv" ||
  die "WT AXI adapter lacks external invalidation handling"
grep -Fq 'dcache_rtrn_inv_d.idx = inval_addr_i' \
  "$cva6/core/cache_subsystem/wt_axi_adapter.sv" ||
  die "WT invalidation address is not routed into the cache"
grep -Fq 'CVA6ConfigDcacheType = config_pkg::WT;' \
  "$cva6/core/include/cv64a6_imafdchsclic_sv39_config_pkg.sv" ||
  die "selected CVA6 target is not WT"
pass "coherence uses the existing CVA6 WT invalidation implementation"

git -C "$cva6" apply --check "$here/patches/cva6-wt-idma-coherence.patch" ||
  die "CVA6 coherence patch no longer applies"
git -C "$cheshire" apply --check \
  "$here/patches/cheshire-idma-coherence.patch" ||
  die "Cheshire coherence patch no longer applies"
pass "both private integration patches apply to locked inputs"

grep -Fq '.stall_i           (stall_ctrl_cache | dma_cache_quiesce_req_i)' \
  "$here/rtl-overrides/cva6/core/cva6.sv" ||
  die "external quiesce does not stall the WT cache"
grep -Fq '!busy_cache_ctrl &&' \
  "$here/rtl-overrides/cva6/core/cva6.sv" ||
  die "quiesce acknowledgement ignores outstanding cache work"
grep -Fq 'dcache_commit_wbuffer_empty;' \
  "$here/rtl-overrides/cva6/core/cva6.sv" ||
  die "quiesce acknowledgement ignores the WT write buffer"
grep -Fq 'if (NumIntHarts != 1)' \
  "$here/rtl-overrides/cheshire/hw/cheshire_soc.sv" ||
  die "single-core scope gate absent"
grep -Fq 'if (Cva6Cfg.DCacheType != config_pkg::WT)' \
  "$here/rtl-overrides/cheshire/hw/cheshire_soc.sv" ||
  die "WT-only elaboration gate absent"
pass "quiesce and scope gates are present"

grep -Fq 'dma_cache_hold_wbuffer_i' \
  "$here/rtl-overrides/cva6/core/cva6.sv" ||
  die "real WT-buffer hold input absent"
grep -Fq 'wt_noc_req.aw.addr >> 4' \
  "$here/rtl-overrides/cva6/core/cva6.sv" ||
  die "WT-buffer hold is not scoped to the prearmed cache line"
grep -Fq 'noc_req_o.aw_valid = 1'"'"'b0;' \
  "$here/rtl-overrides/cva6/core/cva6.sv" ||
  die "WT-buffer hold does not backpressure AW"
grep -Fq '.dma_cache_hold_wbuffer_i( dma_coh_fault_hold_wbuffer_i )' \
  "$here/rtl-overrides/cheshire/hw/cheshire_soc.sv" ||
  die "Cheshire does not connect the WT-buffer hold"
grep -Fq '.dma_coh_fault_hold_wbuffer_i' \
  "$here/rtl/tb_cheshire_linux_dma_coherent.sv" ||
  die "Linux TB does not drive the WT-buffer hold"
grep -Fq 'i_dut.gen_dma.i_idma.dma_reg_req.addr[11:0] == 12'"'"'h0d8' \
  "$here/rtl/tb_cheshire_linux_dma_coherent.sv" ||
  die "Linux TB does not capture the accepted SRC_ADDR prearm"
grep -Fq 'held_wbuffer_cycles == 0' \
  "$here/rtl/tb_cheshire_linux_dma_coherent.sv" ||
  die "Linux acceptance gate does not require a real held WT write"
grep -Fq 'EXPORT_SYMBOL_GPL(cheshire_idma_test_prearm_source);' \
  "$here/driver/cheshire-idma.c" ||
  die "driver prearm hook is not exported"
grep -Fq '#define STALE_SOURCE_LEN      16' \
  "$here/client/cheshire-idma-cache-test.c" ||
  die "stale-source transfer is not bounded to one WT cache line"
grep -Fq 'cheshire_idma_test_prearm_source(channel,' \
  "$here/client/cheshire-idma-cache-test.c" ||
  die "client does not prearm the physical source line"
grep -Fq 'mb();' "$here/client/cheshire-idma-cache-test.c" ||
  die "client does not establish OLD_SRC in RAM before prearm"
pass "stale-source control retains one real CVA6 WT-buffer line"

grep -Fq '#define DROPPED_DST_LINE      8' \
  "$here/client/cheshire-idma-cache-test.c" ||
  die "client destination oracle does not name dropped line 8"
grep -Fq 'i / CACHE_LINE_BYTES == DROPPED_DST_LINE' \
  "$here/client/cheshire-idma-cache-test.c" ||
  die "client destination oracle does not isolate the dropped line"
grep -Fq 'OLD_DST : NEW_SRC' \
  "$here/client/cheshire-idma-cache-test.c" ||
  die "client destination oracle does not require all other lines new"
grep -Fq 'destination_cpu_pattern=old_dst_line8_other_new_src' \
  "$here/rtl/tb_cheshire_linux_dma_coherent.sv" ||
  die "TB record does not describe the exact mixed-line outcome"
pass "stale-destination oracle requires one old line and fifteen new lines"

grep -Fq 'dma_rsp_o.b_valid = mem_rsp_i.b_valid;' \
  "$here/rtl/phase11_wt_coherence_bridge.sv" ||
  die "bridge does not explicitly release B"
grep -Fq 'state_q != ReleaseResponse' \
  "$here/rtl/phase11_wt_coherence_bridge.sv" ||
  die "completion-before-invalidation assertion absent"
grep -Fq 'fault_skip_source_drain_i' \
  "$here/rtl/phase11_wt_coherence_bridge.sv" ||
  die "stale-source negative control absent"
grep -Fq 'fault_drop_inval_i' \
  "$here/rtl/phase11_wt_coherence_bridge.sv" ||
  die "stale-destination negative control absent"
pass "bridge completion ordering and negative controls are explicit"

grep -Fq 'dma-coherent;' "$here/dts/cheshire-linux-dma-cache.dts.in" ||
  die "coherent DT property absent"
grep -Fq 'positive_cache_delta != 0' \
  "$here/client/cheshire-idma-cache-test.c" ||
  die "Linux positive oracle does not require zero cache hooks"
grep -Fq 'stale_source_cache_delta != 0' \
  "$here/client/cheshire-idma-cache-test.c" ||
  die "Linux source negative oracle does not require zero cache hooks"
grep -Fq 'stale_destination_cache_delta != 0' \
  "$here/client/cheshire-idma-cache-test.c" ||
  die "Linux destination negative oracle does not require zero cache hooks"
pass "Linux contract is dma-coherent with zero software cache hooks"

for script in "$here"/scripts/*.sh; do bash -n "$script"; done
pass "all shell scripts parse"

[[ $(cat "$here/build/sim-coherent/build.exit") == 0 ]] ||
  die "full coherent simulator build did not pass"
(cd "$here/build/sim-coherent" && sha256sum -c SHA256SUMS.sim >/dev/null) ||
  die "simulator hashes fail"
(cd "$here/out" && sha256sum -c SHA256SUMS.bridge >/dev/null) ||
  die "bridge regression hashes fail"
(cd "$here/out" && sha256sum -c SHA256SUMS.bound >/dev/null) ||
  die "bounded-control hashes fail"
pass "simulator, bridge regression, and bounded-control hashes verify"

if [[ -f "$here/out/SHA256SUMS.software" ]]; then
  (cd "$here/out" && sha256sum -c SHA256SUMS.software >/dev/null) ||
    die "software hashes fail"
  fdtget "$here/out/cheshire-linux-dma-coherent.dtb" \
    /soc/dma-controller@1000000 dma-coherent >/dev/null ||
    die "compiled DTB lacks dma-coherent"
  python3 - "$here/binding/pulp,cheshire-idma.yaml" \
      "$here/out/cheshire-linux-dma-coherent.dtb" <<'PY'
import subprocess
import sys
import yaml

binding, dtb = sys.argv[1:]
with open(binding, encoding="utf-8") as stream:
    schema = yaml.safe_load(stream)
props = schema["properties"]
required = set(schema["required"])
assert props["compatible"]["const"] == "pulp,cheshire-idma-v0.6.4-test"
assert props["dma-channels"]["const"] == 1
assert props["#dma-cells"]["const"] == 1
assert props["dma-coherent"] is True
assert "dma-coherent" in required
node = "/soc/dma-controller@1000000"
def fdt(option, prop):
    return subprocess.check_output(
        ["fdtget", option, dtb, node, prop], text=True).strip()
assert fdt("-ts", "compatible") == props["compatible"]["const"]
assert fdt("-tu", "dma-channels") == "1"
assert fdt("-tu", "#dma-cells") == "1"
assert fdt("-ts", "reg-names") == "control bus-error"
assert fdt("-tu", "interrupts") == "2 3"
subprocess.run(["fdtget", dtb, node, "dma-coherent"], check=True,
               stdout=subprocess.DEVNULL)
bootargs = subprocess.check_output(
    ["fdtget", "-ts", dtb, "/chosen", "bootargs"], text=True).strip()
assert "dma_debug_entries=1024" in bootargs
assert "phase11.cell=coherent" in bootargs
PY
  dtc -I dtb -O dts -o "$here/out/cheshire-linux-dma-coherent.roundtrip.dts" \
    "$here/out/cheshire-linux-dma-coherent.dtb" 2> \
    "$here/out/dtc-roundtrip.stderr"
  [[ ! -s "$here/out/dtc-roundtrip.stderr" ]] ||
    die "compiled DTB emits dtc round-trip warnings"
  binding_sha=$(sha256sum "$here/binding/pulp,cheshire-idma.yaml")
  binding_sha=${binding_sha%% *}
  grep -Fxq "binding_sha256=$binding_sha" \
    "$here/out/dtschema-validation.txt" ||
    die "independent dtschema result is not for the final binding"
  grep -Fxq 'result=pass' "$here/out/dtschema-validation.txt" ||
    die "independent dtschema validation did not pass"
  {
    printf 'binding_yaml_and_semantic_check=pass\n'
    printf 'compiled_dtb_contract_check=pass\n'
    printf 'dtc_roundtrip_warnings=0\n'
    if command -v dt-validate >/dev/null 2>&1; then
      printf 'full_dtschema_tool=available\n'
    else
      printf 'full_dtschema_tool=unavailable\n'
    fi
  } > "$here/out/dt-schema-contract.txt"
  sha256sum "$here/binding/pulp,cheshire-idma.yaml" \
    "$here/dts/cheshire-linux-dma-cache.dts.in" \
    "$here/out/cheshire-linux-dma-coherent.dtb" \
    "$here/out/cheshire-linux-dma-coherent.roundtrip.dts" \
    "$here/out/dt-schema-contract.txt" \
    "$here/out/dtschema-validation.txt" \
    > "$here/out/SHA256SUMS.dt-contract"
  pass "Linux payload hashes, binding semantics, and compiled DT verify"
fi

printf 'PASS: Phase 11 coherent source contracts verified\n'
