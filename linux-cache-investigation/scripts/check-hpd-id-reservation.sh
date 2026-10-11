#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
failure="$here/out/failures/hpd-uc-unexpected-response-20261011"

die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

(cd "$here" && sha256sum -c \
  out/failures/hpd-uc-unexpected-response-20261011/SHA256SUMS >/dev/null) ||
  die "preserved failure evidence checksum mismatch"

grep -Fq 'hpdcache_uncached.sv:988' "$failure/original.log" ||
  die "original assertion signature missing"
grep -Fq '[HPD-DIAG] uc_write=1 uc_read=0 uc_state=0 flush_dir_valid=0xff' \
  "$failure/diagnostic-30k.log" || die "collision diagnostic missing"
[[ $(<"$failure/original.exit") == 1 ]] || die "unexpected original exit"
[[ $(<"$failure/diagnostic-30k.exit") == 1 ]] ||
  die "unexpected diagnostic exit"

for bound in 30k 250k; do
  log="$here/out/hpd-id-reservation-$bound.log"
  exit_file="$here/out/hpd-id-reservation-$bound.exit"
  [[ $(<"$exit_file") == 1 ]] || die "unexpected corrected $bound exit"
  grep -Fq "timeout after ${bound%k}000 cycles jobs=0/0" "$log" ||
    die "corrected $bound run did not reach its internal bound"
  if grep -Eq 'uc_handler: unexpected response|hpdcache_uncached\.sv:988' "$log"; then
    die "uncached-response assertion recurred in corrected $bound run"
  fi
done

(cd "$here" && sha256sum -c out/SHA256SUMS.hpd-id-reservation >/dev/null) ||
  die "corrected-run checksum mismatch"
"$here/scripts/check-source-contracts.sh" >/dev/null

printf 'PASS: HPDcache all-ones ID collision reproduced and corrected\n'
