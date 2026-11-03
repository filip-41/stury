package write_bench

import "core:fmt"
import "core:os"
import "core:slice"
import "core:time"
import core "../../core"
import write "../../core/write"
import dsv "../../dsv"

// The rows of table.csv and text.csv, the fields the old tree's lanes use.
Table_Row :: struct {
	id, ts:       i64,
	lat, lon:     f64,
	qty:          i64,
	price, score: f64,
	ok:           bool,
	code:         string,
}

Text_Row :: struct {
	id:                      i64,
	name, city, quote, note: string,
}

// Timed passes after two of warm-up. `-define:DSV_ITERS=1` against the default gives a pass's instructions from two runs.
ITERS :: #config(DSV_ITERS, 41)

// `write dsv <file>`: `write.marshal` of the file's rows through a plan, chosen by its name, as the old tree's
// `csv_marshal_<shape>` does: each pass allocates its text and frees it outside the clock. `write dsvdoc <file>`:
// `core.write` of the file read into a document. GB/s counts the source's bytes in both.
dsv_lane :: proc(src: []u8, name: string, document: bool) {
	if document {
		dsv_document_lane(src)
		return
	}
	switch name {
	case "table":
		dsv_rows_lane(Table_Row, src)
	case "text":
		dsv_rows_lane(Text_Row, src)
	case "wide":
		dsv_rows_lane(map[string]string, src)
	case:
		fmt.eprintln("no type for", name)
		os.exit(2)
	}
}

dsv_rows_lane :: proc($R: typeid, src: []u8) {
	rows: []R
	if err := dsv.unmarshal(src, .Csv, &rows, {borrow_strings = true}); err.kind != .None {
		fmt.eprintln("read:", err)
		os.exit(1)
	}
	plan, perr := dsv.plan_make([]R, .Csv)
	if perr.kind != .None {
		fmt.eprintln("plan:", perr)
		os.exit(1)
	}
	times: [ITERS]i64
	text: []u8
	for i in 0 ..< ITERS + 2 {
		start := time.tick_now()
		out, err := write.marshal(rows, &plan, {}, context.allocator)
		d := i64(time.tick_since(start))
		if err.kind != .None {
			fmt.eprintln("write:", err)
			os.exit(1)
		}
		if i >= 2 {
			times[i - 2] = d
		}
		if i < ITERS + 1 {
			delete(out)
		} else {
			text = out
		}
	}
	dsv_report(src, text, times[:])
}

dsv_document_lane :: proc(src: []u8) {
	doc, derr := dsv.build(src, .Csv, {}, false, context.allocator)
	if derr.kind != .None {
		fmt.eprintln("document error:", derr)
		os.exit(1)
	}
	times: [ITERS]i64
	text: []u8
	for i in 0 ..< ITERS + 2 {
		start := time.tick_now()
		out, _, err := core.write(&doc)
		d := i64(time.tick_since(start))
		if err.kind != .None {
			fmt.eprintln("write:", err)
			os.exit(1)
		}
		if i >= 2 {
			times[i - 2] = d
		}
		if i < ITERS + 1 {
			delete(out)
		} else {
			text = out
		}
	}
	dsv_report(src, text, times[:])
}

dsv_report :: proc(src, text: []u8, times: []i64) {
	h := CHECK_OFFSET
	for b in text {
		h = (h ~ u64(b)) * CHECK_PRIME
	}
	slice.sort(times)
	median := times[len(times) / 2]
	fmt.printfln("gb_per_s=%.3f best=%.3f ns=%d out=%d check=%d", f64(len(src)) / f64(median), f64(len(src)) / f64(times[0]), median, len(text), h)
}
