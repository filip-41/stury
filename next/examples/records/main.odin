// Walk the records of an NDJSON text and report the ones that are invalid, read the same records from a stream,
// and count them on threads.
//
// Run from the repository root: odin run examples/records -collection:stury=.
package main

import "stury:core"
import "stury:core/records"
import "stury:host"
import "stury:json"
import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"
import "core:sync"

main :: proc() {
	src := transmute([]byte)string("{\"a\":1}\n{\"a\":tru}\n")
	as := json.as(.Json)

	// One fault per invalid record, with its position counted from the start of the text.
	faults, aerr := records.check(src, as, .Lines)
	if aerr != nil {
		os.exit(1)
	}
	defer delete(faults)
	for f in faults {
		b: strings.Builder
		defer strings.builder_destroy(&b)
		core.render(strings.to_writer(&b), src, f)
		fmt.println(strings.to_string(b)) // 2:9: Invalid literal
	}
	fmt.println(len(faults), "refused")

	// A stream is read through a window. Each record is the same bytes with the same offset, and `next` frames a
	// record without judging it.
	r: strings.Reader
	strings.reader_init(&r, string(src))
	it := records.open_stream(io.to_reader(strings.reader_to_stream(&r)), as)
	defer records.close(&it)
	for rec in records.next(&it) {
		fmt.println(rec.at, string(rec.text)) // 0 {"a":1}, then 8 {"a":tru}
	}
	if it.fault != nil {
		os.exit(1)
	}

	// A pool lends its threads to `each`, which hands every piece of the text to a task.
	pool: host.Pool
	if host.pool_init(&pool) != nil {
		os.exit(1)
	}
	defer host.pool_destroy(&pool)
	lines := transmute([]byte)string("{\"a\":1}\n{\"a\":2}\n{\"a\":3}\n")
	total: int
	count := proc(n: ^int, piece: ^records.Reader, _: int) -> bool {
		for _ in records.next(piece) {
			sync.atomic_add(n, 1)
		}
		return true
	}
	if _, bad := records.each(lines, as, .Lines, count, &total, &pool.runner).?; bad {
		os.exit(1)
	}
	fmt.println(total, "records")
}
