// Build a `Document` and collect the values a path reaches with `query`.
//
// Run from the repository root: odin run examples/roundtrip -collection:stury=.
package main

import "stury:core"
import "stury:json"
import "core:fmt"
import "core:os"
import "core:strings"

// A fault or an error renders as `line:col: message`, with the path when it has one.
report :: proc(src: []u8, e: $E) {
	b: strings.Builder
	defer strings.builder_destroy(&b)
	core.render(strings.to_writer(&b), src, e)
	fmt.eprintln(strings.to_string(b))
}

main :: proc() {
	src := transmute([]byte)string(`{"name":"ada","n":1,"skip":[1,2,3]}`)
	doc, berr := json.build(src, .Json)
	if berr.kind != .None {
		report(src, berr)
		os.exit(1)
	}
	defer core.destroy(&doc)

	path, perr := core.parse_path(".skip[]")
	if perr.kind != .None {
		report(nil, perr)
		os.exit(1)
	}
	defer core.path_destroy(&path)
	answers, qerr := core.query(&doc, path)
	if qerr.kind != .None {
		report(src, qerr)
		os.exit(1)
	}
	defer delete(answers)
	for a in answers {
		if v, ok := core.int_value(&doc, a.node); ok {
			fmt.println(v)
		}
	}

	// A member by name, without a path.
	if n, found := core.member(&doc, core.ROOT, "n"); found {
		fmt.println("n =", string(core.span(&doc, n)))
	}
}
