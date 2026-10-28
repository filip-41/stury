// Read JSONC: comments are accepted with `dialect = .Jsonc`, and strict JSON refuses them.
//
// Run from the repository root: odin run examples/jsonc -collection:stury=.
package main

import json "stury:json"
import "core:fmt"
import "core:os"

main :: proc() {
	src := transmute([]byte)string("{\n\t\"a\": 1 // one\n}\n")

	if err, bad := json.validate(src, {dialect = .Jsonc}).?; bad {
		fmt.eprintln(json.render_error(src, err))
		os.exit(1)
	}
	if err, bad := json.validate(src).?; bad {
		fmt.println(json.render_error(src, err)) // 2:9: Unexpected character: strict JSON has no comments
	}
}
