// Walk the records of an NDJSON text and report the ones that are invalid, then read the same records from a
// stream.
//
// Run from the repository root: odin run examples/records -collection:stury=.
package main

import json "stury:json"
import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"

main :: proc() {
	src := transmute([]byte)string("{\"a\":1}\n{\"a\":tru}\n")

	refused := 0
	it := json.records(src, {framing = .NDJSON})
	for rec in json.next_record(&it) {
		if e, bad := json.validate(rec.bytes).?; bad {
			e.offset += rec.at
			fmt.println(json.render_error(src, e)) // 2:9: Invalid literal
			refused += 1
		}
	}
	if e, bad := it.err.(json.Error); bad {
		fmt.eprintln(json.render_error(src, e))
		os.exit(1)
	}
	fmt.println(refused, "refused")

	r: strings.Reader
	strings.reader_init(&r, string(src))
	rr := json.records_from(io.to_reader(strings.reader_to_stream(&r)), {framing = .NDJSON})
	defer json.destroy(&rr)
	for rec in json.next_record(&rr) {
		fmt.println(rec.at, string(rec.bytes)) // 0 {"a":1}, then 8 {"a":tru}
	}
}
