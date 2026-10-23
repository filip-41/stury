#!/usr/bin/env zsh
# The stury CLI against the CSV command lines (qsv, Miller) and jq's `-R` recipe, end to end: process start,
# file read, the query, every answer printed to /dev/null. Each case's spellings ask the same question, and
# before it is timed every tool's output is kept in OUT/answers; jq_report.py checks each against stury's and
# writes OUT/report.md (a case named `*_raw` is compared line by line). Needs zsh, hyperfine, python3, qsv and
# mlr, and jq for the cases it can answer (bench/README.md).
#
#   make build-cli
#   python3 bench/gen.py table.csv text.csv
#   zsh bench/cli/csv_compare.sh [out_dir]         # default build/bench/csv_compare
#
# The jq arm splits each line at the commas, so it answers only the case whose file has no quoting
# (table.csv). qsv's JSON conversion types its values (numbers and booleans) where stury and Miller's `-S` keep
# the cells as strings, so that case has no qsv arm.
set -e
setopt no_glob # the answers are captured with eval, where a filter's `[`...`]` would glob
HERE=${0:A:h} # resolved before the cd below makes a relative $0 point elsewhere
ROOT=${HERE:h:h}
S=$ROOT/build/stury
OUT=${1:-$ROOT/build/bench/csv_compare}
OUT=${OUT:A}
[[ -x $S ]] || { echo "no $S: run make build-cli" >&2; exit 1; }
for t in hyperfine python3 jq qsv mlr; do
	(( $+commands[$t] )) || { echo "no $t on PATH: the comparison needs every tool" >&2; exit 1; }
done
# Only the default directory or a previous run's output (it holds answers/) is cleared.
if [[ -e $OUT && $OUT != $ROOT/build/bench/csv_compare && ! -d $OUT/answers ]]; then
	echo "$OUT exists and is not a previous run's output: remove it or name another directory" >&2
	exit 1
fi
rm -rf "$OUT"
mkdir -p "$OUT/answers"
cd "$ROOT/bench/fixtures"
source "$HERE/bench_case.zsh"

# Two columns of every record. The jq arm keeps the header line and takes the fields by position.
bench_case cols_raw \
	-n stury "$S --csv '{id,qty}' table.csv" \
	-n mlr "mlr --csv cut -o -f id,qty table.csv" \
	-n qsv "qsv select id,qty table.csv" \
	-n jq "jq -R -r 'split(\",\") | [.[0], .[4]] | join(\",\")' table.csv"

# The records whose qty is 9000 or more (every qty is below 10000, so qsv's regex asks the same).
bench_case filter_raw \
	-n stury "$S --csv 'select(.qty | tonumber >= 9000)' table.csv" \
	-n mlr "mlr --csv filter '\$qty >= 9000' table.csv" \
	-n qsv "qsv search -s qty '^9[0-9]{3}\$' table.csv" \
	-n jq "jq -R -r 'select(startswith(\"id,\") or (split(\",\")[4] | tonumber >= 9000))' table.csv"

# Quoted cells (commas, doubled quotes, an LF inside a cell), two columns kept: the tools quote what they write.
bench_case cols_quoted_raw \
	-n stury "$S --csv '{id,quote}' text.csv" \
	-n mlr "mlr --csv cut -o -f id,quote text.csv" \
	-n qsv "qsv select id,quote text.csv"

# CSV to JSON lines, every cell a string.
bench_case to_json \
	-n stury "$S --csv --to json -c . table.csv" \
	-n mlr "mlr --icsv --ojsonl -S cat table.csv"

python3 "$HERE/jq_report.py" "$OUT"
