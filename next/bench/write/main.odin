// `write string <file> [iters]`: the JSON string writer over every string value of a JSON file, written as the elements of
// one array into a fresh buffer each pass, as the old tree's lane does. The strings are decoded once, outside the
// clock. It prints the best and the median GB/s of decoded string bytes, the output size, and an FNV-1a checksum of the
// output text.
//
// `write doc <file> [pretty]`: `core.write` of the file read into a document, and `write format <file> [pretty]`:
// `json.format` of its text. Each pass allocates its text with the default allocator and frees it outside the clock.
// GB/s counts the source's bytes.
//
// `write dsv <file>` and `write dsvdoc <file>`: `write.marshal` of a delimited file's rows, and `core.write` of its
// document, see dsv.odin.
//
// `write records logs.json`: `records.marshal` of the logs as NDJSON against `write.marshal` of the same list, see
// typed.odin.
//
// `write typed <file> [pretty]`: `json.marshal` of the file's struct type, chosen by its name, the fields the other
// libraries' lanes use. One buffer is reused, so a pass counts neither growth nor page faults. GB/s counts output bytes.
package write_bench

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:time"
import core "../../core"
import write "../../core/write"
import json "../../json"

CHECK_OFFSET :: u64(14695981039346656037)
CHECK_PRIME :: u64(1099511628211)

main :: proc() {
	if len(os.args) < 3 || (os.args[1] != "string" && os.args[1] != "typed" && os.args[1] != "doc" && os.args[1] != "format" && os.args[1] != "dsv" && os.args[1] != "dsvdoc" && os.args[1] != "records") {
		fmt.eprintln("usage: write string <file> [iters] | write typed|doc|format <file> [pretty] | write dsv|dsvdoc <file> | write records logs.json")
		os.exit(2)
	}
	src, err := os.read_entire_file(os.args[2], context.allocator)
	if err != nil {
		fmt.eprintln("cannot read", os.args[2])
		os.exit(1)
	}
	if os.args[1] == "dsv" || os.args[1] == "dsvdoc" {
		dsv_lane(src, filepath.stem(os.args[2]), os.args[1] == "dsvdoc")
		return
	}
	if os.args[1] == "records" {
		records_lane(src)
		return
	}
	if os.args[1] == "typed" {
		typed_lane(src, filepath.stem(os.args[2]), len(os.args) > 3 && os.args[3] == "pretty")
		return
	}
	if os.args[1] == "doc" || os.args[1] == "format" {
		doc_lane(src, os.args[1] == "format", len(os.args) > 3 && os.args[3] == "pretty")
		return
	}
	iters := 41
	if len(os.args) > 3 {
		iters, _ = strconv.parse_int(os.args[3])
	}
	strs, total := strings_of(src)
	times := make([]i64, iters)
	h := CHECK_OFFSET
	size := 0
	for i in 0 ..< iters + 2 {
		spill: [write.ROOM_MAX]u8 = ---
		out: write.Out
		write.init(&out, &spill)
		start := time.tick_now()
		kind := put_all(&out, strs)
		text, ferr := write.finish(&out)
		d := i64(time.tick_since(start))
		if kind != .None || ferr.kind != .None {
			fmt.eprintln("a string is not UTF-8")
			os.exit(1)
		}
		if i >= 2 {
			times[i - 2] = d
		}
		if i == 0 {
			size = len(text)
			for b in text {
				h = (h ~ u64(b)) * CHECK_PRIME
			}
		}
		delete(text)
	}
	slice.sort(times)
	fmt.printfln(
		"gb_per_s=%.3f best=%.3f ns=%d out=%d check=%d",
		f64(total) / f64(times[iters / 2]),
		f64(total) / f64(times[0]),
		times[iters / 2],
		size,
		h,
	)
}

put_all :: #force_no_inline proc(out: ^write.Out, strs: []string) -> core.Typed_Error_Kind {
	for s, i in strs {
		if i > 0 {
			write.room(out, 1)[0] = ','
			out.cursor += 1
		}
		if kind := json.put_string(out, s); kind != .None {
			return kind
		}
	}
	return .None
}

// The decoded value of every string in the file, in document order, and their total size.
strings_of :: proc(src: []u8) -> (strs: []string, total: int) {
	doc, derr := json.build(src, .Json, {}, false, context.allocator)
	if derr.kind != .None {
		fmt.eprintln("document error:", derr)
		os.exit(1)
	}
	// Decoded text is never longer than its source, so one buffer of the file's size holds every string.
	pool := make([]u8, len(src))
	used := 0
	list := make([dynamic]string)
	for n in doc.nodes {
		if n.role != .Value || n.kind != .String {
			continue
		}
		s, ok := json.text(&doc.view, n, pool[used:])
		if !ok {
			fmt.eprintln("string too long")
			os.exit(1)
		}
		used += len(s)
		total += len(s)
		append(&list, s)
	}
	_ = mem.copy
	return list[:], total
}
