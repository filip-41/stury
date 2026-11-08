package write_bench

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:time"
import core "../../core"
import "../timing"
import json "../../json"

// `core.write` of the document built from `src` into the same output bytes on every pass, as `lane` writes, or with
// `direct` `core.format` of `src`, whose document and text come from an arena emptied after each pass.
doc_lane :: proc(src: []u8, direct: bool, pretty: bool) {
	doc, derr := json.build(src, .Json, {}, .Last, context.allocator)
	if derr.kind != .None {
		fmt.eprintln("document error:", derr)
		os.exit(1)
	}
	output := Fixed_Output{make([]u8, 16 * len(src) + 64 * mem.Kilobyte)}
	fixed := runtime.Allocator{fixed_output_proc, &output}
	opts := core.Write_Options{pretty = pretty, indent = 2}
	times: [timing.TIMED]i64
	size := 0
	h := CHECK_OFFSET
	scratch: virtual.Arena
	_ = virtual.arena_init_growing(&scratch)
	for i in 0 ..< timing.WARMUP + timing.TIMED {
		context.allocator = virtual.arena_allocator(&scratch)
		text: []u8
		err: core.Typed_Error
		start := time.tick_now()
		if direct {
			text, err = core.format(src, json.as(.Json), opts)
		} else {
			text, _, err = core.write(&doc, opts, allocator = fixed)
		}
		d := i64(time.tick_since(start))
		if err.kind != .None {
			fmt.eprintln("write:", err)
			os.exit(1)
		}
		if i == timing.WARMUP + timing.TIMED - 1 {
			for b in text {
				h = (h ~ u64(b)) * CHECK_PRIME
			}
		}
		size = len(text)
		virtual.arena_free_all(&scratch)
		if i >= timing.WARMUP {
			times[i - timing.WARMUP] = d
		}
	}
	median := timing.median(&times)
	fmt.printfln("gb_per_s=%.3f best=%.3f ns=%d out=%d check=%d", f64(len(src)) / f64(median), f64(len(src)) / f64(times[0]), median, size, h)
}
