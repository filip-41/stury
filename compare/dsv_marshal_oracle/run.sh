#!/usr/bin/env bash
# run.sh <fixtures>: builds both arms from a fresh copy of common.odin, writes every value as delimited text, and compares
# the texts. The comparison is the marshal oracle's, which accepts a float's layout.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
top=$(cd "$here/../.." && pwd)
ODIN=${ODIN:-odin}
fixtures=${1:-$top/next/bench/fixtures}
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
mkdir -p "$out/src/old" "$out/src/new" "$out/text/old" "$out/text/new"
cp "$here/common.odin" "$here/old/write.odin" "$out/src/old/"
cp "$here/common.odin" "$here/new/write.odin" "$out/src/new/"
"$ODIN" build "$out/src/old" -o:${OPT:-speed} -collection:stury="$top" -out:"$out/old" 2>/dev/null
"$ODIN" build "$out/src/new" -o:${OPT:-speed} -collection:next="$top/next" -out:"$out/new" 2>/dev/null
[ -n "${BUILD_ONLY:-}" ] && exit 0
"$out/old" "$fixtures" "$out/text/old"
"$out/new" "$fixtures" "$out/text/new"
python3 "$here/../marshal_oracle/oracle.py" "$out/text/old" "$out/text/new"
