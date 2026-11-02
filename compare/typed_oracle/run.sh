#!/usr/bin/env bash
# run.sh <rounds> <seed>: every read mode over every shape, in strict JSON, JSONC and JSON5, then every delimited text
# option on each dsv spec, with strings borrowed and copied. Each spec's arms are built fresh in a temporary directory.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
rounds=${1:-20000}
seed=${2:-1}
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
export ORACLE_REF=old
fail=0
oracle() {
	echo "== $*"
	env "$@" python3 "$here/oracle.py" "$arms" "$rounds" "$seed" new || fail=1
}
for spec in 0 1 2; do
	arms=$out/spec$spec
	SPEC=$spec bash "$here/build.sh" "$arms" 2>/dev/null || exit 1
	oracle ORACLE_FORMS=$spec
	oracle ORACLE_FORMS=$spec ORACLE_PREFILL=1
	oracle ORACLE_FORMS=$spec ORACLE_DUPS=first
	oracle ORACLE_FORMS=$spec ORACLE_DUPS=first ORACLE_PREFILL=1
	oracle ORACLE_FORMS=$spec ORACLE_DUPS=refuse
	oracle ORACLE_FORMS=$spec ORACLE_UNKNOWN=1
done
cells() {
	echo "== cells $*"
	env "$@" python3 "$here/cells.py" "$arms" "$rounds" "$seed" | tail -1
	[ "${PIPESTATUS[0]}" = 0 ] || fail=1
}
arms=$out/spec0
for spec in csv tsv plain; do
	for mode in NONE=1 ORACLE_PREFILL=1 ORACLE_NO_HEADER=1 ORACLE_DUPS=first ORACLE_DUPS=refuse ORACLE_UNKNOWN=1 ORACLE_RAGGED=1 ORACLE_COMMENT=1 ORACLE_ENUMS=1; do
		cells ORACLE_SPEC=$spec $mode
	done
done
arms=$out/copy
BORROW=false bash "$here/build.sh" "$arms" 2>/dev/null || exit 1
oracle ORACLE_FORMS=0
for spec in csv tsv plain; do
	cells ORACLE_SPEC=$spec
done
exit $fail
