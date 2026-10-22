// Read one value by path with `scan`, without building a document.
//
// Run from the repository root: odin run examples/scan -collection:stury=.
package main

import json "stury:json"
import "core:fmt"
import "core:os"

main :: proc() {
	src := transmute([]byte)string(`{"name": "ada", "tags": ["math", "engines"]}`)

	// One walk answers the request; no document is built.
	req: json.Request({.Path})
	defer json.destroy(&req)
	if json.request_init(&req, ".tags[1]") != nil || json.scan(src, &req) != nil {
		os.exit(1)
	}
	found, _ := json.answers(&req, 0)
	if len(found) != 1 || found[0].outcome != .Found {
		os.exit(1)
	}
	fmt.println(string(src[found[0].lo:found[0].hi])) // "engines", quotes and all
}
