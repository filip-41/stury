// Edit a value in place: `set` replaces the value at a path and keeps every other byte, spacing included.
//
// Run from the repository root: odin run examples/edit -collection:stury=.
package main

import json "stury:json"
import "core:fmt"
import "core:os"

main :: proc() {
	src := transmute([]byte)string(`{"name": "ada",  "tags": ["math"]}`)

	out, err := json.set(src, ".name", "grace")
	if e, bad := err.?; bad {
		fmt.eprintln(json.render_error(src, e))
		os.exit(1)
	}
	defer delete(out)
	fmt.println(string(out)) // {"name": "grace",  "tags": ["math"]}: every byte outside the edit kept
}
