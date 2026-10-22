// Walk the records of an NDJSON text and report the ones that are invalid.
//
// Run from the repository root: odin run examples/records -collection:stury=.
package main

import json "stury:json"
import "core:fmt"
import "core:os"

main :: proc() {
	src := transmute([]byte)string("{\"a\":1}\n{\"a\":tru}\n")

	refused := 0
	it := json.records(src, .NDJSON)
	for rec in json.next_record(&it) {
		if e, bad := json.validate(rec.bytes).?; bad {
			e.offset += rec.at
			fmt.println(json.render_error(src, e)) // 2:9: Bad_Literal
			refused += 1
		}
	}
	if e, bad := it.err.(json.Error); bad {
		fmt.eprintln(json.render_error(src, e))
		os.exit(1)
	}
	fmt.println(refused, "refused")
}
