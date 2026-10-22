// Build a `Document` and collect the values a path reaches with `query`.
//
// Run from the repository root: odin run examples/roundtrip -collection:stury=.
package main

import json "stury:json"
import "core:fmt"
import "core:os"

main :: proc() {
	src := transmute([]byte)string(`{"name":"ada","n":1,"skip":[1,2,3]}`)
	doc, berr := json.build(src)
	if berr != nil {
		os.exit(1)
	}
	defer json.destroy(&doc)
	nodes: [dynamic]json.Node
	defer delete(nodes)
	if json.query(&doc, json.ROOT, ".skip[]", &nodes) != nil || len(nodes) != 3 {
		fmt.eprintln("query")
		os.exit(1)
	}
	for n in nodes {
		if v, ok := json.get_int(&doc, n); ok {
			fmt.println(v)
		}
	}
}
