// Edit a value in place: `set` replaces the value at a path and keeps every other byte, spacing included. A document
// takes several edits and applies them in one commit.
//
// Run from the repository root: odin run examples/edit -collection:stury=.
package main

import "stury:core"
import "stury:json"
import "core:fmt"
import "core:os"
import "core:strings"

// A fault or an error renders as `line:col: message`, with the path when it has one.
report :: proc(src: []u8, e: core.Error) {
	b: strings.Builder
	defer strings.builder_destroy(&b)
	core.render(strings.to_writer(&b), src, e)
	fmt.eprintln(strings.to_string(b))
}

main :: proc() {
	src := transmute([]byte)string(`{"name": "ada",  "tags": ["math"]}`)

	// The new value is JSON text, which the edit checks before it is spliced in.
	name, perr := core.parse_path(".name")
	if perr != nil {
		report(nil, perr)
		os.exit(1)
	}
	defer core.path_destroy(&name)
	out, err := json.set(src, .Json, name, `"grace"`)
	if err != nil {
		report(src, err)
		os.exit(1)
	}
	defer delete(out)
	fmt.println(string(out)) // {"name": "grace",  "tags": ["math"]}: every byte outside the edit kept

	// Several edits on one document: each is checked as it is recorded, and one commit applies them.
	doc, berr := json.build(src, .Json)
	if berr != nil {
		report(src, berr)
		os.exit(1)
	}
	defer core.destroy(&doc)
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	tags, _ := core.member(&doc, core.ROOT, "tags")
	if serr := core.set_member(&list, core.ROOT, "n", "1"); serr != nil {
		report(src, serr)
		os.exit(1)
	}
	if rerr := core.remove(&list, tags); rerr != nil {
		report(src, rerr)
		os.exit(1)
	}
	committed, _, cerr := core.commit(&list)
	if cerr != nil {
		report(src, cerr)
		os.exit(1)
	}
	defer delete(committed)
	fmt.println(string(committed)) // {"name": "ada",  "n": 1}: `tags` removed, `n` added after the last member in the object's own spacing
}
