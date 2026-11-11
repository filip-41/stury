// Walk the records of an NDJSON text and report the ones that are invalid, read the same records from a stream,
// and count them on threads.
//
// Run from the repository root: odin run examples/records -collection:stury=.
package main

import "stury:json"
import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"
import "core:sync"

// A fault or an error renders as `line:col: message`. The example prints it to show the message.
report :: proc(src: []u8, e: json.Error) {
	b: strings.Builder
	defer strings.builder_destroy(&b)
	json.render(strings.to_writer(&b), src, e)
	fmt.println(strings.to_string(b))
}

main :: proc() {
	src := transmute([]byte)string("{\"a\":1}\n{\"a\":tru}\n")
	if err := run(src); err != nil {
		fmt.eprintln(err)
		os.exit(1)
	}
}

run :: proc(src: []u8) -> json.Error {
	// One fault per invalid record, with its position counted from the start of the text.
	faults := json.records_check(src, .Json, framing = .Lines) or_return
	defer delete(faults)
	for f in faults {
		report(src, f) // 2:9: Invalid literal
	}
	fmt.println(len(faults), "refused")

	// A stream is read through a window. Each record is the same bytes with the same offset, and `next` frames a
	// record without judging it.
	r: strings.Reader
	strings.reader_init(&r, string(src))
	it := json.records_open_stream(io.to_reader(strings.reader_to_stream(&r)), .Json)
	defer json.records_close(&it)
	for rec in json.records_next(&it) {
		fmt.println(rec.at, string(rec.text)) // 0 {"a":1}, then 8 {"a":tru}
	}
	if fault, bad := it.fault.?; bad {
		return fault
	}

	// A pool lends its threads to `each`, which hands every piece of the text to a task.
	pool: json.Pool
	json.pool_init(&pool) or_return
	defer json.destroy(&pool)
	lines := transmute([]byte)string("{\"a\":1}\n{\"a\":2}\n{\"a\":3}\n")
	total: int
	count := proc(n: ^int, piece: ^json.Record_Reader, _: int) -> bool {
		for _ in json.records_next(piece) {
			sync.atomic_add(n, 1)
		}
		return true
	}
	json.records_each(lines, .Json, .Lines, count, &total, &pool.runner) or_return
	fmt.println(total, "records")
	return nil
}
