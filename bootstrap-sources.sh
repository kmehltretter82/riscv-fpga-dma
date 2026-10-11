#!/usr/bin/env bash
# Restore the locked upstream source trees used by this investigation.
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
table="$root/SOURCES.tsv"

[[ -f $table ]] || {
	printf 'missing source lock: %s\n' "$table" >&2
	exit 2
}

while IFS=$'\t' read -r path url revision patch; do
	[[ $path == path ]] && continue
	destination="$root/$path"
	if [[ -d $destination ]] &&
	   [[ -z $(find "$destination" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
		rmdir -- "$destination"
	fi
	if [[ -e $destination || -L $destination ]]; then
		printf 'refusing to replace existing source path: %s\n' "$destination" >&2
		exit 2
	fi
	mkdir -p -- "$(dirname -- "$destination")"
	git clone --filter=blob:none --no-checkout "$url" "$destination"
	git -C "$destination" checkout --detach "$revision"
	if [[ $patch != - ]]; then
		patch_path="$root/upstream-patches/$patch"
		git -C "$destination" apply --check "$patch_path"
		git -C "$destination" apply "$patch_path"
	fi
done < "$table"

for phase in linux-mapping-investigation linux-cache-investigation \
	linux-coherent-investigation; do
	mkdir -p -- "$root/$phase/sources"
	ln -s ../../linux-driver-investigation/sources/cheshire-irq \
		"$root/$phase/sources/cheshire-irq"
	ln -s ../../linux-driver-investigation/sources/idma-abort \
		"$root/$phase/sources/idma-abort"
	ln -s ../../linux-fpga-investigation/sources/cva6-no-trace \
		"$root/$phase/sources/cva6-no-trace"
	ln -s ../../linux-fpga-investigation/sources/linux-cheshire-cache \
		"$root/$phase/sources/linux-cheshire-cache"
	ln -s ../../linux-fpga-investigation/sources/pulp-linux \
		"$root/$phase/sources/pulp-linux"
done

printf 'restored and patched %s locked source trees\n' \
	"$(($(wc -l < "$table") - 1))"
