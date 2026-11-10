// `schema <verdict|errors> <schema> <file>`: the schema lane's stury arm, `gb_per_s`, `ns` and `check` (the instances
// accepted) from the median of ten timed calls after two warm-ups. FILE is judged one instance per line when it is a
// `.jsonl` or `.ndjson` text, else as one document. `BENCH_PASSES=N` makes N untimed passes and prints `check` alone, for
// the runner's instruction counts. `BENCH_VERDICTS=PATH` writes one 0 or 1 per instance, in order, to PATH.
//
// Until the schema check exists, both forms run `json.validate` on each instance, so a verdict is the instance's
// well-formedness, SCHEMA is not read, and the two forms are the same work.
package schema_bench

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "../timing"
import records "../../core/records"
import json "../../json"

lines: bool

// Judges every instance of `src`, writing one 0 or 1 per instance to `marks` when it is not nil, and returns the number
// of instances and the number refused.
pass :: proc(src: []u8, marks: ^strings.Builder = nil) -> (n, refused: int) {
	judge :: proc(text: []u8, marks: ^strings.Builder) -> int {
		bad := int(json.validate(text, json.Spec.Json) != nil)
		if marks != nil {
			strings.write_byte(marks, '0' if bad == 1 else '1')
		}
		return bad
	}
	if !lines {
		return 1, judge(src, marks)
	}
	it := records.open(src, json.as(.Json))
	defer records.close(&it)
	for rec in records.next(&it) {
		n += 1
		refused += judge(rec.text, marks)
	}
	return
}

main :: proc() {
	if len(os.args) != 4 || (os.args[1] != "verdict" && os.args[1] != "errors") {
		fmt.eprintln("usage: schema <verdict|errors> <schema> <file>")
		os.exit(2)
	}
	src, err := os.read_entire_file(os.args[3], runtime.default_allocator())
	if err != nil {
		fmt.eprintln(os.args[3], err)
		os.exit(1)
	}
	lines = strings.has_suffix(os.args[3], ".jsonl") || strings.has_suffix(os.args[3], ".ndjson")
	marks: strings.Builder
	n, refused := pass(src, &marks)
	accepted := n - refused
	if path := os.get_env("BENCH_VERDICTS", context.temp_allocator); path != "" {
		if werr := os.write_entire_file(path, transmute([]u8)strings.to_string(marks)); werr != nil {
			fmt.eprintln(path, werr)
			os.exit(1)
		}
	}
	if passes, ok := strconv.parse_int(os.get_env("BENCH_PASSES", context.temp_allocator)); ok && passes > 0 {
		for _ in 1 ..< passes {
			pass(src)
		}
		fmt.printf("check=%d\n", accepted)
		return
	}
	ts: [timing.TIMED]i64
	for i in 0 ..< timing.WARMUP + timing.TIMED {
		t0 := time.tick_now()
		pass(src)
		d := i64(time.tick_since(t0))
		if i >= timing.WARMUP {
			ts[i - timing.WARMUP] = d
		}
	}
	median := timing.median(&ts)
	fmt.printf("gb_per_s=%.4f ns=%d check=%d\n", f64(len(src)) / f64(median), median, accepted)
}
