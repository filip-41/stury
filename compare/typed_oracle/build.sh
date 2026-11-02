#!/usr/bin/env bash
# build.sh <out-dir>: builds the oracle's two arms, old/ against the root tree and new/ against next/, each from a fresh
# copy of common.odin, so neither runs a stale probe. BORROW=false reads strings as copies.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
top=$(cd "$here/../.." && pwd)
ODIN=${ODIN:-odin}
out=$1
flags=(-o:${OPT:-speed} -define:SPEC=${SPEC:-0} -define:BORROW=${BORROW:-true})
mkdir -p "$out/src/old" "$out/src/new"
cp "$here/common.odin" "$here/old/read.odin" "$out/src/old/"
cp "$here/common.odin" "$here/new/read.odin" "$out/src/new/"
"$ODIN" build "$out/src/old" "${flags[@]}" -collection:stury="$top" -out:"$out/old" &
"$ODIN" build "$out/src/new" "${flags[@]}" -collection:next="$top/next" -out:"$out/new" &
wait %1
wait %2
