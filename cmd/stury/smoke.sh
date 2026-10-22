#!/bin/sh
# The stury CLI end to end on what jq has not: its own options and subcommands, and the CPU and memory
# guards. jq's command line is pinned byte for byte by cli.tsv (jq_suite.py).
#   sh cmd/stury/smoke.sh build/stury
S=${1:-build/stury}
T=$(mktemp -d)
# A hung case stalls the gate: a watchdog ends the script, and any child still running, after a wall budget
# (a sanitized build is slower).
budget=240
[ -n "$STURY_SANITIZED" ] && budget=1800
exec 3>&2
( sleep "$budget" && { echo "FAIL smoke.sh: over its ${budget}s wall budget" >&3; pkill -P $$ -f "^$S"; kill $$; } ) >/dev/null 2>&1 &
watchdog=$!
trap 'pkill -P "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null; rm -rf "$T"' EXIT
fails=0

# check NAME WANT_EXIT WANT_STDOUT STURY_ARGS...   (stdin is the input when no file is named)
check() {
	name=$1 want_exit=$2 want=$3
	shift 3
	got=$("$S" "$@" 2>"$T/err")
	code=$?
	if [ "$code" != "$want_exit" ] || [ "$got" != "$want" ]; then
		printf 'FAIL %s: exit %s (want %s)\n got: %s\nwant: %s\n%s\n' "$name" "$code" "$want_exit" "$got" "$want" "$(cat "$T/err")"
		fails=$((fails + 1))
	fi
}

# check accepts what `stury .` accepts, the library's grammar, with nesting to 1024 and the digit and exponent
# caps lifted, which --strict-limits holds (the small cases are cli.tsv's; these files are too long for it).
"$S" -nr '"[" * 1024 + "]" * 1024' >"$T/deep1024.json"
"$S" -nr '"[" * 1100 + "]" * 1100' >"$T/deep1100.json"
"$S" -nr '"[" * 10000 + "]" * 10000' >"$T/deep10000.json"
"$S" -nr '"[" * 10001 + "]" * 10001' >"$T/deep10001.json"
"$S" -nr '"[1" + "0" * 300 + "]"' >"$T/digits300.json"
for f in deep1024 digits300; do
	check "check_$f" 0 '' check "$T/$f.json"
	check "dot_$f" 0 "$("$S" -c . "$T/$f.json")" -c . "$T/$f.json"
done
for f in deep1100 deep10000; do
	check "check_$f" 5 '' check "$T/$f.json"
	check "dot_$f" 5 '' -c . "$T/$f.json"
done
for f in deep1100 deep10000 deep10001 digits300; do
	check "check_strict_$f" 5 '' check --strict-limits "$T/$f.json"
done
check check_strict_deep1024 0 '' check --strict-limits "$T/deep1024.json"
# --jsonc validates against the same caps.
for f in deep1024 digits300; do
	check "check_jsonc_$f" 0 '' check --jsonc "$T/$f.json"
done
for f in deep1100 deep10001; do
	check "check_jsonc_$f" 5 '' check --jsonc "$T/$f.json"
done
check check_jsonc_strict_deep1100 5 '' check --jsonc --strict-limits "$T/deep1100.json"
check check_jsonc_strict_digits300 5 '' check --jsonc --strict-limits "$T/digits300.json"
check check_deep10001 5 '' check "$T/deep10001.json"
check dot_deep10001 5 '' -c . "$T/deep10001.json"
{ cat "$T/digits300.json"; echo '[1e5000]'; cat "$T/deep1024.json"; } >"$T/big.ndjson"
check check_ndjson_caps 0 '' check --ndjson "$T/big.ndjson"
check check_ndjson_strict 5 '' check --ndjson --strict-limits "$T/big.ndjson"
# One text of 300-digit numbers through a pipe, over more than one window: it is read on past each window's
# end, as a file is.
"$S" -nr '"[" + ("1" * 300 + ",\n") * 40000 + "1]"' >"$T/digits_lines.json"
got=$(cat "$T/digits_lines.json" | "$S" length 2>&1)
[ "$got" = 40001 ] || { echo "FAIL digits300_pipe: $got"; fails=$((fails + 1)); }
# Under --seq a record runs to the next separator, past a pipe's windows: NDJSON with none is one record, read
# as the file is, whatever windows the pipe came in.
"$S" -nc 'range(200000) | {a: .}' >"$T/seq_none.ndjson"
want=$("$S" --seq -c . "$T/seq_none.ndjson" 2>&1)
for i in 1 2 3; do
	got=$(cat "$T/seq_none.ndjson" | "$S" --seq -c . 2>&1)
	[ "$got" = "$want" ] || { echo "FAIL seq_pipe_windows: $got"; fails=$((fails + 1)); break; }
done

# Work that grows faster than the input: each case runs under a 2 s CPU limit, at a size where the
# quadratic reading it guards against took 10 s or more. Under a sanitizer (STURY_SANITIZED set, as
# `make test-asan` sets it) this cap and the memory cap below measure the sanitizer, so only answers count.
quick() {
	if [ -n "$STURY_SANITIZED" ]; then check "$@"; return; fi
	(fails=0; ulimit -t 2; check "$@"; exit $fails) || fails=$((fails + 1))
}
"$S" -nc 'range(400000) | {a: .}' >"$T/many.ndjson"
quick many_texts 0 '399999' -c 'select(.a > 399998) | .a' "$T/many.ndjson"
# A byte order mark past the first line ends the run there, on the record pool too.
{ head -n 200000 "$T/many.ndjson"; printf '\357\273\277'; tail -n 200000 "$T/many.ndjson"; } >"$T/bom.ndjson"
got=$("$S" -c .a "$T/bom.ndjson" 2>/dev/null | wc -l | tr -d ' ')
[ "$got" = 200000 ] || { echo "FAIL bom_record: $got answers, want the 200000 before the mark"; fails=$((fails + 1)); }
"$S" -nc '{u: [range(200000) | {a: .}]}' >"$T/wide.json"
quick slice_tail 0 '100000' -c '.u[100000:] | length' "$T/wide.json"
quick index_each 0 '199999' -c 'last(range(100000; 200000) as $i | .u[$i].a)' "$T/wide.json"

# Recursion jq runs in constant memory, a million levels deep: the answer, and a peak RSS under 32 MB.
# macOS caps no memory with ulimit, so the peak is read from time(1): BSD's -l in bytes, GNU's %M in KB; a
# 10 s CPU limit stops a runaway case. (Under a sanitizer, which runs the interpreter 10x slower, it stops none.)
cpu=10
[ -n "$STURY_SANITIZED" ] && cpu=unlimited
# peak_mb STURY_ARGS...: the peak resident MB of the run, its stdin as given, its stdout in $T/out; 0 under a sanitizer.
peak_mb() {
	if /usr/bin/time -l true 2>/dev/null; then
		mb=$( { ulimit -t "$cpu"; /usr/bin/time -l "$S" "$@" >"$T/out"; } 2>&1 | awk '/maximum resident/ { print int($1 / 1048576) }')
	else
		mb=$( { ulimit -t "$cpu"; /usr/bin/time -f %M "$S" "$@" >"$T/out"; } 2>&1 | awk 'END { print int($1 / 1024) }')
	fi
	[ -n "$STURY_SANITIZED" ] && mb=0
	echo "$mb"
}
# capped NAME CAP_MB WANT_STDOUT STURY_ARGS...
capped() {
	name=$1 cap=$2 want=$3
	shift 3
	got=$(peak_mb "$@")
	if [ "$(cat "$T/out")" != "$want" ] || [ "${got:-999}" -ge "$cap" ]; then
		printf 'FAIL %s: %s MB\n got: %s\nwant: %s\n' "$name" "$got" "$(cat "$T/out")" "$want"
		fails=$((fails + 1))
	fi
}
lean() {
	name=$1
	shift
	capped "$name" 32 "$@"
}
lean bind_tail 1000000 -n 'def f: . as $x | if $x < 1000000 then $x+1|f else $x end; 0|f'
lean def_tail 1000000 -n 'def f: def g: .+1; if . < 1000000 then g|f else . end; 0|f'
# A string or object built by repeated `+` or `*` grows in place; each add does not copy the whole.
lean add_strings 488890 -n '[range(100000) | tostring] | add | length'
lean reduce_string 100000 -n 'reduce range(100000) as $i (""; . + "x") | length'
lean reduce_path_string 100000 -n 'reduce range(100000) as $i ({a: ""}; .a += "x") | .a | length'
lean reduce_merge 20000 -n 'reduce range(20000) as $i ({}; . * {($i | tostring): $i}) | length'
# Idioms that build, take apart or loop over something big, each under about four times jq's own peak at
# the same size (a floor of 11 MB): any of them going quadratic again lands far past its cap.
capped reduce_array 14 8000 -n 'reduce range(8000) as $i ([]; . + [$i]) | length'
capped reduce_object 14 3000 -n 'reduce range(3000) as $i ({}; . + {($i|tostring): $i}) | length'
capped reduce_merge_nested 15 3000 -n 'reduce range(3000) as $i ({}; . * {a: {($i|tostring): $i}}) | .a | length'
capped reduce_count 12 100 -n 'reduce range(40000) as $i ({}; .[$i % 100 | tostring] += 1) | length'
capped reduce_nested_array 17 8000 -n 'reduce range(8000) as $i ({a: []}; .a += [$i]) | .a | length'
capped reduce_interpolate 14 228890 -n 'reduce range(40000) as $i (""; . + "\($i),") | length'
capped foreach_string 21 800020000 -n '[foreach range(40000) as $i (""; . + "x"; utf8bytelength)] | add'
capped foreach_array 17 8000 -n 'last(foreach range(8000) as $i ([]; . + [$i])) | length'
capped foreach_array_kept 16 8000 -n '[foreach range(8000) as $i ([]; . + [$i])] | length' # jq: 555 MB
capped foreach_object 14 3000 -n '[foreach range(3000) as $i ({}; . + {($i|tostring): $i}; length)] | max'
capped foreach_setpath 14 3000 -n 'last(foreach range(3000) as $i ({}; setpath([$i|tostring]; $i); length))'
capped add_arrays 15 8000 -n '[range(8000) | [.]] | add | length'
capped add_objects 20 3000 -n '[range(3000) | {(tostring): .}] | add | length'
capped join 32 228889 -n '[range(40000) | tostring] | join(",") | length'
capped tostring_add 33 188890 -n '[range(40000)] | [.[] | tostring] | add | length'
capped entries 32 3000 -n '[range(3000) | {(tostring): .}] | add | to_entries | from_entries | with_entries(.value += 1) | length'
capped group_by 60 100 -n '[range(20000) | {k: (. % 100), v: .}] | group_by(.k) | length'
capped unique_by 58 1000 -n '[range(20000) | {k: (. % 1000), v: .}] | unique_by(.k) | length'
capped paths 86 40000 -n '[range(20000) | {a: .}] | [paths] | length'
capped paths_streamed 51 40000 -n 'reduce ([range(20000) | {a: .}] | paths) as $p (0; . + 1)'
capped setpath_reduce 14 3000 -n 'reduce range(3000) as $i ({}; setpath([$i|tostring]; $i)) | length'
capped del_reduce 15 0 -n 'reduce range(3000) as $i ([range(3000)]; del(.[0])) | length'
capped del_wide 94 0 -n '[range(20000) | {(tostring): .}] | add | del(.[]) | length'
capped limit 11 5 -n '[limit(5; range(1e12))] | length'
capped first 11 11 -n 'first(range(1e12) | select(. > 10))'
capped splits 93 20001 -n '[("a," * 20000) | splits(",")] | length'
capped gsub 92 40000 -n '"ab" * 20000 | gsub("a"; "x") | length'
capped ascii_downcase 188 400000 -n '"AB" * 200000 | ascii_downcase | length'
capped tojson_roundtrip 59 20000 -n '[range(20000) | {a: .}] | tojson | fromjson | length'
capped tojson_loop 11 49995000 -n 'reduce range(10000) as $i (0; . + ({a: $i} | tojson | fromjson | .a))'
capped getpath_loop 16 199990000 -n '[range(20000)] as $a | reduce range(20000) as $i (0; . + ($a | getpath([$i])))'
capped env_loop 12 100000 -n 'reduce range(100000) as $i (0; . + ($ENV | length | if . > 0 then 1 else 0 end) * $__loc__.line + (env | type | length) - 6)'
capped range 11 2999999 -n 'last(range(3000000))'
capped range_collect 114 300000 -n '[range(300000)] | length'
capped recurse_deep 26 10000 -n 'reduce range(9999) as $_ ([]; [.]) | [recurse] | length'
# Values nested past jq's limit are refused by every comparison, as jq refuses them.
for f in 'max' 'min' 'max_by(.)' 'bsearch([$x])' 'index($x)' 'indices($x)' '. - [[$x]]'; do
	check "too_deep $f" 5 '' -n "reduce range(10002) as \$_ ([]; [.]) as \$x | [\$x, [\$x]] | $f"
done
capped walk_wide 93 20000 -n '[range(20000) | {a: [.]}] | walk(if type == "number" then . + 1 else . end) | length'
capped explode_implode 39 200000 -n '"aé" * 100000 | explode | implode | length'
capped base64d 17 300000 -n '"abc" * 100000 | @base64 | @base64d | length'
capped test_regex 44 true -n '"ab" * 100000 + "c" | test("(ab)*c$")'
capped tostream 29 4000 -n '[range(4000) | {a: .}] | [tostream] | fromstream(.[]) | length'

# What stury tells of itself where jq tells of jq: -V as jq's `jq-VERSION`, the build configuration as the
# Odin command it was built with, and the help, which lists stury's own options too.
"$S" -V | grep -Eqx 'stury-([0-9a-f]{7,}|dev|[0-9]+\.[0-9]+\.[0-9]+)' || { echo "FAIL -V: $("$S" -V)"; fails=$((fails + 1)); }
"$S" --build-configuration | grep -q '^odin .* -target:' || { echo "FAIL --build-configuration"; fails=$((fails + 1)); }
for opt in -V --version -h --help --build-configuration; do
	"$S" "$opt" >/dev/null 2>&1 </dev/null || { echo "FAIL $opt: exit $? (want 0)"; fails=$((fails + 1)); }
done
check build_configuration_var 0 '"string"' -n '$JQ_BUILD_CONFIGURATION | type'
"$S" --help | grep -q '^      --ndjson ' || { echo "FAIL --help lists --ndjson"; fails=$((fails + 1)); }
"$S" --help | grep -q '^stury.s own; stury(1) and docs/cli.md in stury.s source$' || { echo "FAIL --help points to docs/cli.md"; fails=$((fails + 1)); }
"$S" -h | head -1 | grep -q '^stury - commandline JSON processor \[version ' || { echo "FAIL -h"; fails=$((fails + 1)); }
"$S" -f </dev/null 2>"$T/err"
[ $? = 2 ] && tail -1 "$T/err" | grep -qx 'For listing the command options, use stury --help.' || { echo "FAIL -f with no file"; fails=$((fails + 1)); }

# A pipe is read as it comes. early NAME WANT FIRST REST ARGS...: FIRST is written, REST once the answer to FIRST
# is on disk, or after 2 s (10 s under a sanitizer, where TSan's start alone takes 0.4 s) when it is not; the
# answer to FIRST must be out by then; the whole answer is WANT.
polls=40
[ -n "$STURY_SANITIZED" ] && polls=200
early() {
	name=$1 want=$2 first=$3 rest=$4
	shift 4
	rm -f "$T/early"
	{ printf "$first"; i=0; while [ ! -s "$T/out" ] && [ $i -lt $polls ]; do sleep 0.05; i=$((i + 1)); done; [ -s "$T/out" ] && : >"$T/early"; printf "$rest"; } | "$S" "$@" >"$T/out" 2>&1
	if [ ! -e "$T/early" ] || [ "$(cat "$T/out")" != "$want" ]; then
		printf 'FAIL %s: first answer %s\n got: %s\nwant: %s\n' "$name" "$([ -e "$T/early" ] && echo in time || echo late)" "$(cat "$T/out")" "$want"
		fails=$((fails + 1))
	fi
}
early pipe_records "$(printf '1\n2')" '{"a":1}\n' '{"a":2}\n' -c .a
early pipe_interpreter "$(printf '2\n3')" '{"a":1}\n' '{"a":2}\n' -c '.a + 1'
early pipe_raw "$(printf '"a"\n"b"')" 'a\n' 'b\n' -R .
early pipe_stream "$(printf '[[0],1]\n[[0]]\n[[0],2]\n[[0]]')" '[1]\n' '[2]\n' --stream -c .
early pipe_input "$(printf '1\n2')" '1\n' '2\n3\n' -n -c 'input, input'
# paused NAME WANT_EXIT WANT FIRST REST ARGS...: a text cut where the pipe pauses reads as jq reads it whole.
paused() {
	name=$1 want_exit=$2 want=$3 first=$4 rest=$5
	shift 5
	got=$({ printf "$first"; sleep 0.1; printf "$rest"; } | "$S" "$@" 2>&1)
	code=$?
	if [ "$code" != "$want_exit" ] || [ "$got" != "$want" ]; then
		printf 'FAIL %s: exit %s (want %s)\n got: %s\nwant: %s\n' "$name" "$code" "$want_exit" "$got" "$want"
		fails=$((fails + 1))
	fi
}
paused cut_number 0 "$(printf '123\n4')" '12' '3 4\n' -c .
paused cut_string 0 '"abc"' '"ab' 'c"\n' -c .
paused cut_fault 5 "$(printf '{"a":1}\nstury: parse error: Unexpected character at line 3, column 3')" '{"a":1}\n{"b":\n' '2,,}\n' -c .
paused cut_raw 0 "$(printf '"abc"\n"d"')" 'ab' 'c\nd' -R .
paused cut_stream 0 "$(printf '[["a",0],1]\n[["a",1],2]\n[["a",1]]\n[["a"]]')" '{"a":[1,' '2]}\n' --stream -c .
# A byte order mark stays behind when a text on the stream's first line is read on.
paused cut_bom 0 '[1,2]' '\357\273\277[1,\n' '2]\n' -c .
paused cut_bom_seq 0 "$(printf '\0361')" '\357\273\277\0361\n' '' --seq -c .
# A pipe is held a window at a time: 100 MB of records through one peak under 64 MB.
"$S" -nc 'range(1400000) | {id: ., msg: "a line of text that makes each record seventy bytes"}' >"$T/big.ndjson"
got=$(cat "$T/big.ndjson" | peak_mb -c .id)
[ "$(tail -1 "$T/out")" = 1399999 ] && [ "${got:-999}" -lt 64 ] || { echo "FAIL pipe_rss: $got MB, last $(tail -1 "$T/out")"; fails=$((fails + 1)); }
# So is a regular file of records past 64 MB.
capped file_rss 64 1399999 -c 'select(.id == 1399999) | .id' "$T/big.ndjson"
rm -f "$T/big.ndjson"

# A long reduce frees each update's garbage as jq's reference counts do, its state copied with what it shares
# shared once; `[inputs]` under -n keeps a small text in about what it takes.
capped reduce_scoped 11 999999 -n 'reduce range(1000000) as $i ({}; .a = $i) | .a'
capped reduce_scoped_shared 40 2 -n 'reduce range(100000) as $i (null; [., .]) | length'
capped reduce_scoped_string 48 200000 -n '("x" * 100000) as $s | reduce range(200000) as $i ([]; . + [$s]) | length'
"$S" -n 'range(200000)' >"$T/nums"
capped inputs_small 128 200000 -n '[inputs] | length' "$T/nums"
rm -f "$T/nums"

# Under -n the outputs printed and the inputs read past are let go as the run goes, as jq's reference counts
# let them go: 35 MB of records each through a peak under 48 MB.
"$S" -nc 'range(400000) | {id: ., level: (if . % 10 == 0 then "error" else "info" end), msg: "a line of text that makes each record seventy bytes"}' >"$T/big.ndjson"
mkfifo "$T/fifo"
capped reduce_inputs 48 400000 -n 'reduce inputs as $x (0; . + 1)' "$T/big.ndjson"
cat "$T/big.ndjson" >"$T/fifo" &
capped reduce_inputs_pipe 48 400000 -n 'reduce inputs as $x (0; . + 1)' <"$T/fifo"
cat "$T/big.ndjson" >"$T/fifo" &
capped inputs_select_pipe 48 399990 -n 'inputs | select(.level == "error" and .id > 399980) | .id' <"$T/fifo"
capped foreach_inputs 48 400000 -n 'foreach inputs as $x (0; . + 1) | select(. == 400000)' "$T/big.ndjson"
capped foreach_inputs_extract 48 '[400000,399999]' -nc 'foreach inputs as $x (0; . + 1; select(. == 400000) | [., $x.id])' "$T/big.ndjson"
# `inputs` into what keeps none of them, or only its last output, or a reduce's state: each read past is let go.
capped first_inputs 48 399999 -n 'first(inputs | select(.id == 399999)) | .id' "$T/big.ndjson"
capped last_inputs 48 399999 -n 'last(inputs | select(.level == "info")) | .id' "$T/big.ndjson"
capped all_inputs 48 true -n 'all(inputs; .id >= 0)' "$T/big.ndjson"
capped reduce_inputs_select 48 400 -n 'reduce (inputs | select(.id % 1000 == 0)) as $x (0; . + 1)' "$T/big.ndjson"
capped outputs_scoped 20 '{"a":"1999999"}' -nc 'range(2000000) | tostring | {a: .} | select(.a == "1999999")'
# Each faulty --seq record is placed by line and column from the last, not from the start.
"$S" -nr 'range(200000) | "\u001e{\"a\":tru}"' >"$T/seq_errors.seq"
capped seq_error_records 25 '' --seq -c . "$T/seq_errors.seq"
# A text the path scan leaves to the interpreter (`.a` on a number) frees its document.
"$S" -nr 'range(300000)' >"$T/numbers.txt"
capped scan_fallback_free 80 '' .a "$T/numbers.txt"
rm -f "$T/big.ndjson" "$T/fifo"

# A coloured print of an array under an object runs on the batch pool, framed in the colours the single thread
# paints; -S (one thread, and these keys are sorted already) is the reference.
"$S" -nc '{a: 1, logs: [range(200000) | {id: ., msg: "a line of text that makes each record long"}], z: {}}' >"$T/framed.json"
for o in "-C" "-C -c" "-C --tab"; do
	"$S" $o . "$T/framed.json" >"$T/framed.pool"
	"$S" $o -S . "$T/framed.json" >"$T/framed.one"
	cmp -s "$T/framed.pool" "$T/framed.one" || { echo "FAIL framed_color $o: the pool's print differs from one thread's"; fails=$((fails + 1)); }
done
rm -f "$T/framed.json" "$T/framed.pool" "$T/framed.one"

[ "$fails" = 0 ] && echo "stury CLI smoke: ok" || { echo "stury CLI smoke: $fails failed"; exit 1; }
