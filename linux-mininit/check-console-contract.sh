#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 2 ]]; then
	printf 'usage: %s INIT_BINARY CONTROLLER_SOURCE\n' "$0" >&2
	exit 2
fi

init_binary=$1
controller_source=$2

[[ -f $init_binary && ! -L $init_binary ]] || {
	printf 'invalid init binary: %s\n' "$init_binary" >&2
	exit 2
}
[[ -f $controller_source && ! -L $controller_source ]] || {
	printf 'invalid init controller: %s\n' "$controller_source" >&2
	exit 2
}

setup_line=$(grep -nFm1 'mi_setup_console(fail_prefix);' \
	"$controller_source" | cut -d: -f1)
marker_line=$(grep -nFm1 'init started");' "$controller_source" | cut -d: -f1)
[[ -n $setup_line && -n $marker_line && $setup_line -lt $marker_line ]] || {
	printf 'console setup must precede the first init marker: %s\n' \
		"$controller_source" >&2
	exit 2
}

for marker in devtmpfs /dev/console 'mknodat /dev/console' \
	'dup3 /dev/console'; do
	riscv64-linux-gnu-strings "$init_binary" | grep -Fxq -- "$marker" || {
		printf 'init binary lacks console marker %s: %s\n' \
			"$marker" "$init_binary" >&2
		exit 2
	}
done

printf 'PASS: early console contract: %s\n' "$controller_source"
