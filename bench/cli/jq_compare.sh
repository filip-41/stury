#!/usr/bin/env zsh
# Times the stury CLI against the jq-like CLIs (jq, jaq, gojq, yq), end to end: process start, file read, the
# query, and every answer printed to /dev/null. Each case asks every tool the same question. Before timing,
# each tool's output is saved in OUT/answers; jq_report.py compares it with stury's and writes OUT/report.md.
# Needs zsh, hyperfine, python3, perl and the compared tools (bench/README.md).
#
#   make build-cli
#   python3 bench/gen.py && python3 bench/fetch.py corpus
#   zsh bench/cli/jq_compare.sh [out_dir]         # default build/bench/jq_compare
#
# ROUNDS and RUNS set a case's hyperfine rounds and timings per tool (bench_case.zsh).
set -e
setopt no_glob # the answers are captured with eval, where `.logs[]` would glob
HERE=${0:A:h} # resolved before the cd below makes a relative $0 point elsewhere
ROOT=${HERE:h:h}
S=$ROOT/build/stury
OUT=${1:-$ROOT/build/bench/jq_compare}
OUT=${OUT:A}
[[ -x $S ]] || { echo "no $S: run make build-cli" >&2; exit 1; }
for t in hyperfine perl python3 jq jaq gojq yq; do
	(( $+commands[$t] )) || { echo "no $t on PATH: the comparison needs every tool" >&2; exit 1; }
done
# Clears OUT only when it is the default directory or a previous run's output (one holding answers/).
if [[ -e $OUT && $OUT != $ROOT/build/bench/jq_compare && ! -d $OUT/answers ]]; then
	echo "$OUT exists and is not a previous run's output: remove it or name another directory" >&2
	exit 1
fi
rm -rf "$OUT"
mkdir -p "$OUT/answers"
cd "$ROOT/bench/fixtures"

# Writes logs.json as JSONC: pretty-printed, with a line comment after every opening bracket and a trailing
# comma before every closing one. jq cannot read JSONC, so the other tools' arms strip it first with
# strip_jsonc.sh, which removes only those two forms.
J=$OUT/logs.jsonc
python3 - logs.json "$J" <<'EOF'
import json, sys
lines = json.dumps(json.load(open(sys.argv[1])), indent=2).split("\n")
out = []
for i, line in enumerate(lines):
    nxt = lines[i + 1].strip() if i + 1 < len(lines) else ""
    if nxt[:1] in ("}", "]") and line.rstrip()[-1:] not in ("{", "["):
        line += ","
    out.append(line)
    if line.rstrip()[-1:] in ("{", "["):
        out.append("// note")
open(sys.argv[2], "w").write("\n".join(out) + "\n")
EOF
STRIP=$OUT/strip_jsonc.sh
cat >"$STRIP" <<'EOF'
#!/bin/sh
exec perl -0777 -pe 's{^//[^\n]*\n}{}mg; s/,(\s*[\]}])/$1/g' "$1"
EOF
chmod +x "$STRIP"

source "$HERE/bench_case.zsh"

# ask NAME FLAGS FILTER FILE [YQ_FLAGS]
# Runs one case on stury, jq, jaq and gojq, and on yq when YQ_FLAGS gives yq's spelling of FLAGS ("-" for
# none). STURY_FLAGS are added to stury's command only.
ask() {
	local name=$1 flags=$2 f=$3 file=$4 yqf=$5 t
	local args=(-n stury "$S $STURY_FLAGS $flags '$f' $file")
	for t in jq jaq gojq; do args+=(-n $t "$t $flags '$f' $file"); done
	[[ $yqf == - ]] && yqf=
	[[ -n ${5:-} ]] && args+=(-n yq "yq -p json -o json $yqf '$f' $file")
	bench_case $name "${args[@]}"
}

# Synthetic inputs (bench/gen.py) are large and compact, one shape each, so the query's cost dominates.

# One member of every record.
ask logs_id -c '.logs[].id' logs.json -I0

# Every member value of every record.
ask logs_all -c '.logs[][]' logs.json -I0

# A column over a root array.
ask batch_s -c '.[].s' batch_131072.json -I0

# A negative index under a wildcard, on array values only (yq selects them with a tag test).
bench_case neg_index \
	-n stury "$S -c '.[].msg | arrays | .[-1]' documents.json" \
	-n jq "jq -c '.[].msg | arrays | .[-1]' documents.json" \
	-n jaq "jaq -c '.[].msg | arrays | .[-1]' documents.json" \
	-n gojq "gojq -c '.[].msg | arrays | .[-1]' documents.json" \
	-n yq "yq -p json -o json -I0 '.[].msg | select(tag == \"!!seq\") | .[-1]' documents.json"

# Pretty output: every record indented with two spaces, each tool's default.
ask logs_pretty '' '.logs[]' logs.json -

# Raw strings: every record's message, unquoted.
ask logs_msg_raw -r '.logs[].msg' logs.json -r

# NDJSON: one member of every record, and every record re-emitted compact.
STURY_FLAGS=--ndjson ask ndjson_v -c .v records.ndjson -I0
STURY_FLAGS=--ndjson ask ndjson_all -c . records.ndjson -I0

# JSONC: stury reads it; the others read it after strip_jsonc.sh.
bench_case jsonc_id \
	-n stury "$S --jsonc -c .logs[].id $J" \
	-n jq "sh -c '$STRIP $J | jq -c .logs[].id'" \
	-n jaq "sh -c '$STRIP $J | jaq -c .logs[].id'" \
	-n gojq "sh -c '$STRIP $J | gojq -c .logs[].id'" \
	-n yq "sh -c '$STRIP $J | yq -p json -o json -I0 .logs[].id'"

# Validation alone: `empty` reads the whole input and prints nothing.
bench_case validate \
	-n stury "$S check logs.json" \
	-n jq "jq empty logs.json" \
	-n jaq "jaq empty logs.json" \
	-n gojq "gojq empty logs.json"

# Filters beyond paths, which run on stury's interpreter. yq's language differs, so yq has no arm here.
ask filter_select -c '.logs[] | select(.status >= 450) | .id' logs.json
ask filter_map -c '.logs | map({id, ms: .duration_ms})' logs.json
ask filter_group -c '.logs | group_by(.service) | map([.[0].service, length])' logs.json
ask filter_reduce -c 'reduce .logs[] as $l (0; . + $l.bytes)' logs.json
ask filter_string_raw -r '.logs[] | "\(.level): \(.msg | ascii_upcase)"' logs.json

# The real documents (bench/fetch.py corpus) are small and mixed, so process start and setup take a larger
# share of the time. twitter is string-heavy with non-ASCII text, citm has wide objects, canada float arrays.
ask twitter_names -c '.statuses[].user.screen_name' corpus/twitter.json -I0
ask twitter_select -c '.statuses[] | select(.retweet_count > 0) | {id, n: .retweet_count}' corpus/twitter.json
ask twitter_pretty '' '.' corpus/twitter.json
ask citm_prices -c '[.performances[].prices[].amount] | add' corpus/citm_catalog.json
ask citm_names -c '.events | to_entries | map(.value.name)' corpus/citm_catalog.json
ask canada_ring -c '.features[0].geometry.coordinates[0][-1]' corpus/canada.json -I0
ask canada_count -c '[.features[].geometry.coordinates[][]] | length' corpus/canada.json
bench_case validate_twitter \
	-n stury "$S check corpus/twitter.json" \
	-n jq "jq empty corpus/twitter.json" \
	-n jaq "jaq empty corpus/twitter.json" \
	-n gojq "gojq empty corpus/twitter.json"
bench_case validate_canada \
	-n stury "$S check corpus/canada.json" \
	-n jq "jq empty corpus/canada.json" \
	-n jaq "jaq empty corpus/canada.json" \
	-n gojq "gojq empty corpus/canada.json"

python3 "$HERE/jq_report.py" "$OUT"
