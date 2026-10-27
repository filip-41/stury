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
	answers: [dynamic]json.Answer
	defer delete(answers)
	if json.query(&doc, ".skip[]", &answers) != nil || len(answers) != 3 {
		fmt.eprintln("query")
		os.exit(1)
	}
	for a in answers {
		if v, ok := json.get_int(&doc, a.node); ok {
			fmt.println(v)
		}
	}
}
