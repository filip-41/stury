// Read JSONC: comments are accepted with `.Jsonc`, and strict JSON refuses them. An edit keeps the comments.
//
// Run from the repository root: odin run examples/jsonc -collection:stury=.
package main

import "stury:core"
import "stury:json"
import "core:fmt"
import "core:os"
import "core:strings"

// A fault or an error renders as `line:col: message`. The example prints it to show the message.
report :: proc(src: []u8, e: $E) {
	b: strings.Builder
	defer strings.builder_destroy(&b)
	core.render(strings.to_writer(&b), src, e)
	fmt.println(strings.to_string(b))
}

main :: proc() {
	src := transmute([]byte)string("{\n\t\"a\": 1 // one\n}\n")

	if fault, bad := json.validate(src, .Jsonc).?; bad {
		report(src, fault)
		os.exit(1)
	}
	// Strict JSON refuses the comment, and the report says where.
	if fault, bad := json.validate(src, .Json).?; bad {
		report(src, fault)
	}

	a, perr := core.parse_path(".a")
	if perr.kind != .None {
		report(nil, perr)
		os.exit(1)
	}
	defer core.path_destroy(&a)
	out, err := json.set(src, .Jsonc, a, "2")
	if err.kind != .None {
		report(src, err)
		os.exit(1)
	}
	defer delete(out)
	fmt.print(string(out))
}
