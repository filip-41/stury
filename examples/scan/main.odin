// Read one value by path with `find`, and every value of a path with `scan`, without building a whole document.
//
// Run from the repository root: odin run examples/scan -collection:stury=.
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
	src := transmute([]byte)string(`{"name": "ada", "tags": ["math", "engines"]}`)

	// The path text is parsed once. The path owns its steps, and borrows the text.
	second_tag, perr := core.parse_path(".tags[1]")
	if perr.kind != .None {
		report(nil, perr)
		os.exit(1)
	}
	defer core.path_destroy(&second_tag)

	// One walk answers one path and stops at the answer. The document holds the nodes the answer needs and borrows `src`.
	doc, answer, err := json.find(src, .Json, second_tag)
	if err.kind != .None {
		report(src, err)
		os.exit(1)
	}
	defer core.destroy(&doc)
	if answer.outcome == .Found {
		fmt.println(string(core.span(&doc, answer.node))) // "engines", quotes and all
		buf: [32]u8
		text, _ := core.text(&doc, answer.node, buf[:]) // decoded into the caller's buffer, never allocated
		fmt.println(text) // engines
	}

	// A path with `[]` gives one answer per value it reaches, in text order.
	every_tag, eerr := core.parse_path(".tags[]")
	if eerr.kind != .None {
		report(nil, eerr)
		os.exit(1)
	}
	defer core.path_destroy(&every_tag)
	tags, serr := json.scan(src, .Json, every_tag)
	if serr.kind != .None {
		report(src, serr)
		os.exit(1)
	}
	defer core.destroy(&tags)
	for a in tags.answers {
		fmt.println(string(core.span(&tags, a.node))) // "math", then "engines"
	}
}
