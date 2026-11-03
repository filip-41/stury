// The old tree's document writer on the protocol of `next/bench/write`'s `doc` and `format` lanes: `write_probe doc|format
// FILE [pretty]` prints one line of `gb_per_s=`, `best=`, `ns=`, `out=` and `check=`. Each pass allocates its text and frees
// it outside the clock, and GB/s counts the source's bytes.
package write_probe

import "core:fmt"
import "core:os"
import "core:slice"
import "core:time"
import json "stury:json"

CHECK_OFFSET :: u64(14695981039346656037)
CHECK_PRIME :: u64(1099511628211)

main :: proc() {
	if len(os.args) < 3 || (os.args[1] != "doc" && os.args[1] != "format") {
		fmt.eprintln("usage: write_probe doc|format FILE [pretty]")
		os.exit(2)
	}
	src, err := os.read_entire_file(os.args[2], context.allocator)
	if err != nil {
		fmt.eprintln("cannot read", os.args[2])
		os.exit(1)
	}
	pretty := len(os.args) > 3 && os.args[3] == "pretty"
	opts := json.Document_Opts{pretty = pretty, indent = 2}
	doc, derr := json.build(src)
	if derr != nil {
		fmt.eprintln("document error:", derr)
		os.exit(1)
	}
	ITERS :: 41
	times: [ITERS]i64
	text: []u8
	for i in 0 ..< ITERS + 2 {
		start := time.tick_now()
		if os.args[1] == "format" {
			f, ferr := json.format(src, {}, opts)
			text = f
			assert(ferr == nil)
		} else {
			m, merr := json.marshal(&doc, opts)
			text = m
			assert(merr == nil)
		}
		d := i64(time.tick_since(start))
		if i >= 2 {
			times[i - 2] = d
		}
		if i < ITERS + 1 {
			delete(text)
		}
	}
	h := CHECK_OFFSET
	for b in text {
		h = (h ~ u64(b)) * CHECK_PRIME
	}
	slice.sort(times[:])
	median := times[ITERS / 2]
	fmt.printfln("gb_per_s=%.3f best=%.3f ns=%d out=%d check=%d", f64(len(src)) / f64(median), f64(len(src)) / f64(times[0]), median, len(text), h)
}
