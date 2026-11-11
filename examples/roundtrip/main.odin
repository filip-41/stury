// Build a `Document` and collect the values a path reaches with `query`.
//
// Run from the repository root: odin run examples/roundtrip -collection:stury=.
package main

import "stury:json"
import "core:fmt"
import "core:os"
import "core:strings"

// A fault or an error renders as `line:col: message`, with the path when it has one.
report :: proc(src: []u8, e: json.Error) {
	b: strings.Builder
	defer strings.builder_destroy(&b)
	json.render(strings.to_writer(&b), src, e)
	fmt.eprintln(strings.to_string(b))
}

main :: proc() {
	src := transmute([]byte)string(`{"name":"ada","n":1,"skip":[1,2,3]}`)
	if err := run(src); err != nil {
		report(src, err)
		os.exit(1)
	}
}

run :: proc(src: []u8) -> json.Error {
	doc := json.build(src, .Json) or_return
	defer json.destroy(&doc)

	path := json.parse_path(".skip[]") or_return
	defer json.destroy(&path)
	answers := json.query(&doc, path) or_return
	defer delete(answers)
	for a in answers {
		if v, ok := json.int_value(&doc, a.node); ok {
			fmt.println(v)
		}
	}

	// A member by name, without a path.
	if n, found := json.member(&doc, json.ROOT, "n"); found {
		fmt.println("n =", string(json.span(&doc, n)))
	}
	return nil
}
