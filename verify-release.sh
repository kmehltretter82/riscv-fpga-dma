#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

sha256sum -c "$root/upstream-patches/SHA256SUMS"

if awk -F '\t' 'NR > 1 && $2 ~ /^\// { bad = 1 } END { exit bad }' \
	"$root/SOURCES.tsv"; then
	:
else
	printf 'SOURCES.tsv contains a host-local source URL\n' >&2
	exit 1
fi

while IFS= read -r script; do
	bash -n "$script"
done < <(find "$root" -type f -name '*.sh' -print | sort)

python3 - "$root" <<'PY'
import ast
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
for path in sorted(root.rglob("*.py")):
    ast.parse(path.read_text(), filename=str(path))
for path in sorted(root.rglob("*.json")):
    json.loads(path.read_text())
PY

while IFS= read -r bundle; do
	python3 "$root/regression/verify.py" "$bundle"
done < <(find "$root/evidence/regression-runs" -mindepth 1 -maxdepth 1 \
	-type d -print 2>/dev/null | sort)

while IFS= read -r bundle; do
	python3 "$root/regression/verify.py" --integrity-only "$bundle"
done < <(find "$root/evidence/diagnostic-runs" -mindepth 1 -maxdepth 1 \
	-type d -print 2>/dev/null | sort)

if [[ -f $root/RELEASE-SHA256SUMS ]]; then
	(cd "$root" && sha256sum -c RELEASE-SHA256SUMS)
fi

printf 'release verification passed\n'
