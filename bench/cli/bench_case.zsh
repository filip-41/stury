# Sourced by jq_compare.sh and csv_compare.sh, which set OUT first.
#
# bench_case NAME -n TOOL CMD ...: keep each tool's answer, then time them all, round by round. A case is ROUNDS
# hyperfine runs (default 5) of RUNS timings per tool each (default 3), the tools' order rotated every round, so
# a drift in machine load reaches every tool alike; jq_report.py takes each tool's median over all its timings.
bench_case() {
	local name=$1 i r k
	shift
	local tools=() cmds=()
	for ((i = 1; i < $#; i += 3)); do
		tools+=(${@[i+1]})
		cmds+=(${@[i+2]})
		eval "${@[i+2]}" >"$OUT/answers/$name.${@[i+1]}.txt"
	done
	for ((r = 0; r < ${ROUNDS:-5}; r++)); do
		local args=()
		for ((i = 0; i < ${#tools}; i++)); do
			k=$(( (i + r) % ${#tools} + 1 ))
			args+=(-n ${tools[k]} ${cmds[k]})
		done
		hyperfine -N -w 1 -r ${RUNS:-3} --style none --export-json "$OUT/$name.round$r.json" "${args[@]}" >/dev/null
	done
	echo "$name: timed" >&2
}
