// Edit a value in place: `set` replaces the value at a path and keeps every other byte, spacing included. A document
// takes several edits and applies them in one commit.
//
// Run from the repository root: odin run examples/edit -collection:stury=.
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
	src := transmute([]byte)string(`{"name": "ada",  "tags": ["math"]}`)
	if err := run(src); err != nil {
		report(src, err)
		os.exit(1)
	}
}

run :: proc(src: []u8) -> json.Error {
	// The new value is JSON text, which the edit checks before it is spliced in.
	name := json.parse_path(".name") or_return
	defer json.destroy(&name)
	out := json.set(src, .Json, name, `"grace"`) or_return
	defer delete(out)
	fmt.println(string(out)) // {"name": "grace",  "tags": ["math"]}: every byte outside the edit kept

	// Several edits on one document: each is checked as it is recorded, and one commit applies them.
	doc := json.build(src, .Json) or_return
	defer json.destroy(&doc)
	list := json.edit_list_init(&doc, .Json)
	defer json.destroy(&list)
	tags, _ := json.member(&doc, json.ROOT, "tags")
	json.set_member(&list, json.ROOT, "n", "1") or_return
	json.remove(&list, tags) or_return
	committed, _ := json.commit(&list) or_return
	defer delete(committed)
	fmt.println(string(committed)) // {"name": "ada",  "n": 1}: `tags` removed, `n` added after the last member in the object's own spacing
	return nil
}
