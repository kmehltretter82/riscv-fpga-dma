#!/usr/bin/env bash
set -euo pipefail

mode=${1:-baseline}
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
base_tree="$script_dir/idma"
evidence_dir="$script_dir/../hwtest/riscv-idma-rtl-20261011"
tools_dir="$script_dir/.tools"
base_commit=a6b1d6657c03998b6df0baf905d7babd006ba614

case "$mode" in
    baseline|strobe-fault|data-fault) ;;
    *)
        echo "usage: $0 {baseline|strobe-fault|data-fault} [output-directory]" >&2
        exit 2
        ;;
esac

if [[ $# -ge 2 ]]; then
    mkdir -p -- "$2"
    output_dir=$(cd -- "$2" && pwd)
else
    output_dir="$PWD/idma-run-$mode"
    mkdir -p -- "$output_dir"
fi

worktree_parent="$script_dir/.tmp-worktrees"
mkdir -p -- "$worktree_parent"
worktree=$(mktemp -d "$worktree_parent/idma-$mode.XXXXXX")
rmdir -- "$worktree"
registered=0
cleanup() {
    if [[ ${KEEP_WORKTREE:-0} == 1 ]]; then
        echo "kept worktree: $worktree"
    elif [[ $registered == 1 ]]; then
        git -C "$base_tree" worktree remove --force "$worktree" >/dev/null 2>&1 || true
        rmdir -- "$worktree_parent" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

git -C "$base_tree" worktree add --detach "$worktree" "$base_commit"
registered=1
ln -s "$base_tree/.bender" "$worktree/.bender"
ln -s "$base_tree/.venv" "$worktree/.venv"

case "$mode" in
    strobe-fault)
        git -C "$worktree" apply "$evidence_dir/0001-test-inject-final-AXI-write-strobe-loss.patch"
        ;;
    data-fault)
        git -C "$worktree" apply "$evidence_dir/0002-test-corrupt-final-AXI-write-data-bit.patch"
        ;;
esac

export PATH="$tools_dir/bin:$tools_dir/verilator-5.052/bin:$PATH"
export BENDER_LOCAL=true
export UV_CACHE_DIR="${TMPDIR:-/tmp}/dmadebug2-uv-cache"
export UV_OFFLINE=1
verilator_bin="$tools_dir/verilator-5.052/bin/verilator"

{
    echo "mode=$mode"
    echo "base_commit=$(git -C "$worktree" rev-parse HEAD)"
    echo "source_diff=$(git -C "$worktree" diff --stat | tr '\n' ';')"
    bender --version
    uv --version
    "$verilator_bin" --version
} > "$output_dir/environment.txt"

make -C "$worktree" idma_hw_all > "$output_dir/generate.log" 2>&1

run_mx() {
    set +e
    /usr/bin/time -v uv run --locked make -C "$worktree" \
        idma_verify_sim_mxroundtrip IDMA_VLT_MAKEFLAGS=-j6 \
        > "$output_dir/mxroundtrip.log" 2>&1
    local rc=$?
    set -e
    printf '%s\n' "$rc" > "$output_dir/mxroundtrip.exit"
    return "$rc"
}

build_inst64() {
    local variant=$1
    local param=()
    local build_dir="$worktree/target/campaign/inst64-axi-copy/$variant"
    if [[ $variant == axi-only ]]; then
        param=(-GEnableTcdmObi=0)
    fi
    mkdir -p -- "$build_dir"
    (
        cd -- "$worktree"
        bender script verilator \
            -t rtl -t synth -t idma_test -t simulation -t sim -t test \
            -t snitch_cluster --top tb_idma_inst64_axi_copy \
            > "$build_dir/sources.f"
        "$verilator_bin" --binary --assert --timing --timescale 1ns/1ps \
            -Wno-fatal --error-limit 1000 -f "$build_dir/sources.f" \
            --top-module tb_idma_inst64_axi_copy "${param[@]}" \
            --Mdir "$build_dir/obj_dir" -o "$build_dir/simv" --build-jobs 6
    ) > "$output_dir/inst64-$variant-build.log" 2>&1
}

run_inst64() {
    local variant=$1
    set +e
    /usr/bin/time -v \
        "$worktree/target/campaign/inst64-axi-copy/$variant/simv" \
        > "$output_dir/inst64-$variant.log" 2>&1
    local rc=$?
    set -e
    printf '%s\n' "$rc" > "$output_dir/inst64-$variant.exit"
    return "$rc"
}

case "$mode" in
    baseline)
        run_mx
        grep -q 'mxroundtrip: ran 4 leg(s), 0 failed' "$output_dir/mxroundtrip.log"

        build_inst64 default
        run_inst64 default
        grep -q 'TEST PASSED: 4096 B copied' "$output_dir/inst64-default.log"

        build_inst64 axi-only
        run_inst64 axi-only
        grep -q 'TEST PASSED: 4096 B copied' "$output_dir/inst64-axi-only.log"
        grep -q 'DMINIT rejected with an error response' "$output_dir/inst64-axi-only.log"

        make -C "$worktree" -j3 idma_sim_vlt_tb_idma_reg_frontend \
            VERILATOR="$verilator_bin" > "$output_dir/reg-frontend.log" 2>&1
        test "$(grep -c 'RESULT     : PASS' "$output_dir/reg-frontend.log")" -eq 3
        ;;
    strobe-fault)
        if run_mx; then
            echo 'strobe fault unexpectedly passed' >&2
            exit 1
        fi
        if grep -q 'verilator build failed' "$output_dir/mxroundtrip.log"; then
            echo 'strobe-fault detector run did not build cleanly' >&2
            exit 1
        fi
        test "$(grep -c 'AXIMON.*strobe' "$output_dir/mxroundtrip.log")" -eq 4
        grep -q 'mxroundtrip: ran 4 leg(s), 4 failed' "$output_dir/mxroundtrip.log"
        ;;
    data-fault)
        if run_mx; then
            echo 'data fault unexpectedly passed the MX matrix' >&2
            exit 1
        fi
        if grep -q 'verilator build failed' "$output_dir/mxroundtrip.log"; then
            echo 'data-fault detector run did not build cleanly' >&2
            exit 1
        fi
        grep -q 'mxroundtrip: ran 4 leg(s), 4 failed' "$output_dir/mxroundtrip.log"
        grep -q '\[MXRT\] FAIL:' "$output_dir/mxroundtrip.log"

        build_inst64 default
        if run_inst64 default; then
            echo 'data fault unexpectedly passed the inst64 copy' >&2
            exit 1
        fi
        grep -q 'payload mismatch at offset 4032' "$output_dir/inst64-default.log"
        ;;
esac

rm -f -- "$output_dir/SHA256SUMS"
sha256sum "$output_dir"/* > "$output_dir/SHA256SUMS"
echo "PASS: $mode evidence in $output_dir"
