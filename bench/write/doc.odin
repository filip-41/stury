package write_bench

import "core:fmt"
import "core:os"
import "core:slice"
import "core:time"
import core "../../core"
import json "../../json"

// `core.write` of the document built from `src`, or with `direct` `json.format` of `src`.
doc_lane :: proc(src: []u8, direct: bool, pretty: bool) {
	doc, derr := json.build(src, .Json, {}, false, context.allocator)
	if derr.kind != .None {
		fmt.eprintln("document error:", derr)
		os.exit(1)
	}
	opts := core.Write_Options{pretty = pretty, indent = 2}
	ITERS :: 41
	times: [ITERS]i64
	text: []u8
	for i in 0 ..< ITERS + 2 {
		err: core.Typed_Error
		start := time.tick_now()
		if direct {
			text, err = json.format(src, .Json, opts)
		} else {
			text, _, err = core.write(&doc, opts)
		}
		d := i64(time.tick_since(start))
		if err.kind != .None {
			fmt.eprintln("write:", err)
			os.exit(1)
		}
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
