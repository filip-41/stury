// Build a `Document` and collect the values a path reaches with `query`.
//
// Run from the repository root: odin run examples/roundtrip -collection:stury=.
package main

import "stury:core"
import "stury:json"
import "core:fmt"
import "core:os"

main :: proc() {
	src := transmute([]byte)string(`{"name":"ada","n":1,"skip":[1,2,3]}`)
	doc, berr := json.build(src, .Json)
	if berr.kind != .None {
		os.exit(1)
	}
	defer core.destroy(&doc)

	path, perr := core.parse_path(".skip[]")
	if perr.kind != .None {
		os.exit(1)
	}
	defer core.path_destroy(&path)
	answers, qerr := core.query(&doc, path)
	if qerr.kind != .None || len(answers) != 3 {
		fmt.eprintln("query")
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
