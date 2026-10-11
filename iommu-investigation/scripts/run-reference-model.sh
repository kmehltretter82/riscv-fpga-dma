#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORKSPACE=$(cd "$ROOT/.." && pwd)
SRC="$WORKSPACE/sources/riscv-iommu-spec/iommu_ref_model"
PATCH="$ROOT/patches/iommu-ref-model-test-ub.patch"
REPEAT=${REPEAT:-1}
SANITIZE=${SANITIZE:-0}

expected=875e15459ef7ac99dfd313b2a8c0a19dba742e59
actual=$(git -C "$WORKSPACE/sources/riscv-iommu-spec" rev-parse HEAD)
if [[ $actual != "$expected" ]]; then
    printf 'IOMMU specification revision mismatch: expected %s, got %s\n' \
        "$expected" "$actual" >&2
    exit 2
fi
git -C "$WORKSPACE/sources/riscv-iommu-spec" diff --check
git -C "$WORKSPACE/sources/riscv-iommu-spec" apply --check --reverse "$PATCH"

if ! [[ $REPEAT =~ ^[1-9][0-9]*$ ]]; then
    printf 'REPEAT must be a positive integer, got %s\n' "$REPEAT" >&2
    exit 2
fi
if [[ $SANITIZE != 0 && $SANITIZE != 1 ]]; then
    printf 'SANITIZE must be 0 or 1, got %s\n' "$SANITIZE" >&2
    exit 2
fi

mkdir -p "$ROOT/build" "$ROOT/logs"
suffix=
make_args=(RVI_IOMMU_MAX_ITAGS=2)
if [[ $SANITIZE == 1 ]]; then
    suffix=-sanitized
    compiler="$ROOT/build/ref-model-sanitize-cc"
    cat >"$compiler" <<'EOF'
#!/bin/sh
exec gcc -fsanitize=address,undefined -fno-omit-frame-pointer "$@"
EOF
    chmod +x "$compiler"
    make_args+=("CC=$compiler")
    export ASAN_OPTIONS=detect_leaks=0:halt_on_error=1
    export UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1
fi

build_log="$ROOT/logs/ref-model-build$suffix.log"
run_log="$ROOT/logs/ref-model-run$suffix.log"
summary="$ROOT/logs/ref-model-repeat$suffix.log"
one="$ROOT/build/ref-model-one$suffix.log"
: >"$build_log"

for component in libiommu libtables test; do
    make -C "$SRC/$component" "${make_args[@]}" clean >>"$build_log" 2>&1
    make -C "$SRC/$component" "${make_args[@]}" >>"$build_log" 2>&1
done

# Keep normal and sanitized executables side by side.  The upstream build
# writes both variants to test/iommu, so whichever build ran last would
# otherwise silently change later regression inputs.
binary="$ROOT/build/iommu-reference$suffix"
install -m 0755 "$SRC/test/iommu" "$binary"

: >"$summary"
for ((run = 1; run <= REPEAT; run++)); do
    set +e
    "$binary" >"$one" 2>&1
    rc=$?
    set -e

    pass_count=$(grep -c 'PASS' "$one" || true)
    fail_count=$(grep -c 'FAIL' "$one" || true)
    test_count=$(grep -c '^Test [0-9][0-9] :' "$one" || true)
    printf 'run=%03d rc=%d tests=%d pass=%d fail=%d\n' \
        "$run" "$rc" "$test_count" "$pass_count" "$fail_count" >>"$summary"

    if [[ $rc -ne 0 || $test_count -ne 30 || $pass_count -ne 30 || $fail_count -ne 0 ]] || \
       ! grep -q '^Test 30 : Big endian model .*PASS' "$one"; then
        cat "$one" >>"$summary"
        printf 'Reference-model gate failed on run %d; see %s\n' \
            "$run" "$summary" >&2
        exit 1
    fi
done

sed -E $'s/\\x1B\\[[0-9;]*[mK]//g' "$one" >"$run_log"
sha256sum "$PATCH" "$binary" "$build_log" "$run_log" "$summary" \
    >"$ROOT/logs/ref-model$suffix.sha256"
printf 'Reference model PASS: %d/%d runs, 30/30 tests%s\n' \
    "$REPEAT" "$REPEAT" "$([[ $SANITIZE == 1 ]] && printf ' under ASan+UBSan' || true)"
