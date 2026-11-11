// Read one value by path with `find`, and every value of a path with `scan`, without building a whole document.
//
// Run from the repository root: odin run examples/scan -collection:stury=.
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
	src := transmute([]byte)string(`{"name": "ada", "tags": ["math", "engines"]}`)
	if err := run(src); err != nil {
		report(src, err)
		os.exit(1)
	}
}

run :: proc(src: []u8) -> json.Error {
	// The path text is parsed once. The path owns its steps, and borrows the text.
	second_tag := json.parse_path(".tags[1]") or_return
	defer json.destroy(&second_tag)

	// One walk answers one path and stops at the answer. The document holds the nodes the answer needs and borrows `src`.
	doc, answer := json.find(src, .Json, second_tag) or_return
	defer json.destroy(&doc)
	if answer.outcome == .Found {
		fmt.println(string(json.span(&doc, answer.node))) // "engines", quotes and all
		buf: [32]u8
		text, _ := json.text(&doc, doc.nodes[answer.node], buf[:]) // decoded into the caller's buffer, never allocated
		fmt.println(text) // engines
	}

	// A path with `[]` gives one answer per value it reaches, in text order.
	every_tag := json.parse_path(".tags[]") or_return
	defer json.destroy(&every_tag)
	tags := json.scan(src, .Json, every_tag) or_return
	defer json.destroy(&tags)
	for a in tags.answers {
		fmt.println(string(json.span(&tags, a.node))) // "math", then "engines"
	}
	return nil
}
