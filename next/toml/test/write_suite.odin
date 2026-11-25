package toml_tests

import "core:strings"
import "core:testing"
import "stury:testkit"
import "stury:toml"

// The writer's law over the conformance suite: each valid text the writer can write reads back with its values,
// comments and styles.

@(test)
suite_texts_write_and_read_back_with_their_facts :: proc(t: ^testing.T) {
	testkit.deadline(t)
	written := 0
	for dir in SUITE {
		if !strings.has_prefix(dir.prefix, "valid/") {
			continue
		}
		for file in dir.files {
			if !strings.has_suffix(file.name, ".toml") {
				continue
			}
			doc, err := toml.build(file.data, .Toml_1_1)
			defer toml.destroy(&doc)
			if err != nil {
				continue
			}
			text, _, werr := toml.write(&doc, .Toml_1_1)
			defer delete(text)
			if werr != nil {
				// A TOML text holds no null, but a value past 64 bits or a key that is a container is refused too.
				continue
			}
			written += 1
			// Known gaps: a comment inside an inline table, and tables a header made under a table of dotted keys, are not
			// written as they were.
			back, berr := toml.build(text, .Toml_1_1)
			defer toml.destroy(&back)
			testing.expectf(t, berr == nil, "%s%s: %v\n%s", dir.prefix, file.name, berr, text)
			want, got := describe(&doc, true), describe(&back, true)
			defer delete(want)
			defer delete(got)
			testing.expectf(t, berr == nil && want == got, "%s%s: facts differ\n%s\nwant\n%s\ngot\n%s", dir.prefix, file.name, text, want, got)
		}
	}
	testing.expect(t, written > 100)
}
