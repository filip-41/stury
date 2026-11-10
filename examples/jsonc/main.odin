// Read JSONC: comments are accepted with `.Jsonc`, and strict JSON refuses them. An edit keeps the comments.
//
// Run from the repository root: odin run examples/jsonc -collection:stury=.
package main

import "stury:json"
import "core:fmt"
import "core:os"
import "core:strings"

// A fault or an error renders as `line:col: message`. The example prints it to show the message.
report :: proc(src: []u8, e: json.Error) {
	b: strings.Builder
	defer strings.builder_destroy(&b)
	json.render(strings.to_writer(&b), src, e)
	fmt.println(strings.to_string(b))
}

main :: proc() {
	src := transmute([]byte)string("{\n\t\"a\": 1 // one\n}\n")
	if err := run(src); err != nil {
		report(src, err)
		os.exit(1)
	}
}

run :: proc(src: []u8) -> json.Error {
	json.validate(src, .Jsonc) or_return
	// Strict JSON refuses the comment, and the report says where.
	if fault := json.validate(src, .Json); fault != nil {
		report(src, fault)
	}

	a := json.parse_path(".a") or_return
	defer json.destroy(&a)
	out := json.set(src, .Jsonc, a, "2") or_return
	defer delete(out)
	fmt.print(string(out))
	return nil
}
