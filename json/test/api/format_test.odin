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

	pretty, perr := json.format(raw(`{"a":[1]}`), write = {pretty = true, indent = 2})
	defer delete(pretty)
	testing.expect_value(t, perr, nil)
	testing.expect_value(t, string(pretty), "{\n  \"a\": [\n    1\n  ]\n}")

	// A document that does not validate is its fault, not a partial write.
	_, bad := json.format(raw(`{"a":`))
	testing.expect_value(t, bad, json.Path_Error{kind = .Bad_Source, syntax = .Truncated, offset = 5})
	// `read`'s duplicates are `build`'s.
	first, ferr := json.format(raw(`{"a":1,"a":2}`), {duplicates = .First})
	defer delete(first)
	testing.expectf(t, ferr == nil && string(first) == `{"a":1}`, "%s %v", first, ferr)
}

// `read`'s limits are the build's, so a text nested past MAX_DEPTH reads under a raised `max_depth` and writes
// compact; pretty output of it is refused.
@(test)
test_format_reads_under_raised_limits :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	DEEP :: 1500
	src := strings.concatenate({strings.repeat("[ ", DEEP, context.temp_allocator), strings.repeat("] ", DEEP, context.temp_allocator)}, context.temp_allocator)
	want := strings.concatenate({strings.repeat("[", DEEP, context.temp_allocator), strings.repeat("]", DEEP, context.temp_allocator)}, context.temp_allocator)
	_, refused := json.format(raw(src))
	r, deep := refused.?
	testing.expectf(t, deep && r.kind == .Bad_Source && r.syntax == .Too_Deep, "%v", refused)
	read := json.Read_Opts{limits = {max_depth = DEEP}}
	out, err := json.format(raw(src), read, {trailing_newline = true}, context.temp_allocator)
	testing.expectf(t, err == nil && string(out) == strings.concatenate({want, "\n"}, context.temp_allocator), "%v", err)
	_, perr := json.format(raw(src), read, {pretty = true})
	testing.expect_value(t, perr, json.Path_Error{kind = .Encode, encode = .Too_Deep})
	doc, berr := json.build(raw(src), read, context.temp_allocator)
	testing.expect_value(t, berr, nil)
	mout, merr := json.marshal(&doc, {}, context.temp_allocator)
	testing.expectf(t, merr == nil && string(mout) == want, "marshal: %v", merr)
}

@(test)
test_format_keeps_a_jsonc_documents_comments :: proc(t: ^testing.T) {
	out, err := json.format(raw("{\n  // why\n  \"a\": 1\n}\n"), {dialect = .Jsonc})
	defer delete(out)
	testing.expect_value(t, err, nil)
	testing.expect(t, string(out) != "", "a formatted JSONC document is written")
	testing.expect(t, strings.contains(string(out), "// why"), "the comment is kept")
}
