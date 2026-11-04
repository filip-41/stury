// Read JSONC: comments are accepted with `.Jsonc`, and strict JSON refuses them. An edit keeps the comments.
//
// Run from the repository root: odin run examples/jsonc -collection:stury=.
package main

import "stury:core"
import "stury:json"
import "core:fmt"
import "core:os"
import "core:strings"

main :: proc() {
	src := transmute([]byte)string("{\n\t\"a\": 1 // one\n}\n")

	if json.validate(src, .Jsonc) != nil {
		os.exit(1)
	}
	if fault, bad := json.validate(src, .Json).?; bad {
		b: strings.Builder
		defer strings.builder_destroy(&b)
		core.render(strings.to_writer(&b), src, fault)
		fmt.println(strings.to_string(b))
	}

	a, _ := core.parse_path(".a")
	defer core.path_destroy(&a)
	out, err := json.set(src, .Jsonc, a, "2")
	if err.kind != .None {
		os.exit(1)
	}
	defer delete(out)
	fmt.print(string(out))
}
