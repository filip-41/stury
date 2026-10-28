// Read one value by path with `find`, and every value of a path with a `Request`, without building a document.
//
// Run from the repository root: odin run examples/scan -collection:stury=.
package main

import json "stury:json"
import "core:fmt"
import "core:os"

main :: proc() {
	src := transmute([]byte)string(`{"name": "ada", "tags": ["math", "engines"]}`)

	// One walk answers one path, and nothing is kept.
	a, err := json.find(src, ".tags[1]")
	if err != nil {
		os.exit(1)
	}
	if a.outcome == .Found {
		fmt.println(string(src[a.lo:a.hi])) // "engines", quotes and all
		text, _, _ := json.answer_text(src, a) // decoded, a slice of src unless it held an escape
		fmt.println(text) // engines
	}

	// A request holds every answer of its paths, and can be scanned again over other records.
	req: json.Request({.Path})
	defer json.destroy(&req)
	if json.request_init(&req, ".tags[]") != nil || json.scan(src, &req) != nil {
		os.exit(1)
	}
	tags, _ := json.answers(&req, 0) // one path: nothing to group, so no error
	for t in tags {
		fmt.println(string(src[t.lo:t.hi])) // "math", then "engines"
	}
}
