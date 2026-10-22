package json_tests

// `format`: a validated buffer written again, the path an edit's bytes take to pretty or compact output.

import json "../.."
import "core:strings"
import "core:testing"

@(test)
test_format_writes_a_buffer_again :: proc(t: ^testing.T) {
	// Compact by default, key order kept, the input's whitespace gone.
	compact, cerr := json.format(raw(` {"b":[2,3],"a":1} `))
	defer delete(compact)
	testing.expect_value(t, cerr, nil)
	testing.expect_value(t, string(compact), `{"b":[2,3],"a":1}`)

	pretty, perr := json.format(raw(`{"a":[1]}`), {pretty = true, indent = 2})
	defer delete(pretty)
	testing.expect_value(t, perr, nil)
	testing.expect_value(t, string(pretty), "{\n  \"a\": [\n    1\n  ]\n}")

	// A document that does not validate is its fault, not a partial write.
	_, bad := json.format(raw(`{"a":`))
	testing.expect(t, bad != nil, "a truncated text must be refused")
}

@(test)
test_format_keeps_a_jsonc_documents_comments :: proc(t: ^testing.T) {
	out, err := json.format(raw("{\n  // why\n  \"a\": 1\n}\n"), dialect = .Jsonc)
	defer delete(out)
	testing.expect_value(t, err, nil)
	testing.expect(t, string(out) != "", "a formatted JSONC document is written")
	testing.expect(t, strings.contains(string(out), "// why"), "the comment is kept")
}
