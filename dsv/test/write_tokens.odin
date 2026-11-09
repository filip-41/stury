package dsv_tests

import "base:runtime"
import "core:bytes"
import "core:io"
import "core:math"
import "core:testing"
import core "../../core"
import write "../../core/write"
import dsv ".."
import walktest "../../walktest"

// The token write against `marshal`: a header and rows written cell by cell are the bytes of the same rows.

Token_Row :: struct {
	id:    i64,
	name:  string,
	ok:    bool,
	score: f64,
	small: u64,
}

TOKEN_ROWS := [?]Token_Row {
	{1, "plain", true, 0.5, 0},
	{-2, "a,b", false, -1e300, 18446744073709551615},
	{3, "say \"hi\"", true, 3, 7},
	{4, "#comment", false, 0.25, 1},
	{5, "tab\there\nline", true, 1e-7, 9},
	{6, "café 日本", false, 12345.678, 3},
	{7, "", true, 2, 4},
	{8, "\\back;slash", false, 6, 5},
}

token_rows :: proc(rows: []Token_Row, spec: dsv.Spec, layout: dsv.Options, stream := io.Stream{}, allocator := context.allocator) -> ([]u8, core.Typed_Error) {
	tw: write.Tokens
	write.tokens_init(&tw, dsv.as(spec, layout), {}, allocator, stream)
	if !layout.no_header {
		for name in ([?]string{"id", "name", "ok", "score", "small"}) {
			write.value_string(&tw, name)
		}
		write.end_record(&tw)
	}
	for r in rows {
		write.value_int(&tw, r.id)
		write.value_string(&tw, r.name)
		write.value_bool(&tw, r.ok)
		write.value_float(&tw, r.score)
		write.value_uint(&tw, r.small)
		write.end_record(&tw)
	}
	return write.tokens_finish(&tw)
}

@(test)
tokens_equal_marshal :: proc(t: ^testing.T) {
	Case :: struct {
		spec:   dsv.Spec,
		layout: dsv.Options,
	}
	for c in ([?]Case {
			{.Csv, {}},
			{.Csv, {crlf = true}},
			{.Csv, {delimiter = ';', comment = '#'}},
			{.Csv, {no_header = true, comment = '#'}},
			{.Tsv, {}},
			{.Tsv, {comment = '#', crlf = true}},
			{.Csv, {delimiter = '1'}},
			{.Plain, {}},
		}) {
		rows := TOKEN_ROWS[:]
		if c.spec == .Plain {
			rows = {TOKEN_ROWS[0], TOKEN_ROWS[2], TOKEN_ROWS[5]}
		}
		want, werr := dsv.marshal(rows, c.spec, c.layout, write = {}, allocator = context.temp_allocator)
		got, err := token_rows(rows, c.spec, c.layout)
		defer delete(got)
		testing.expect_value(t, err.kind, walktest.typed_kind(werr))
		testing.expectf(t, string(got) == string(want), "%v %v: %q, want %q", c.spec, c.layout, got, want)
		if werr == nil {
			doc: core.Document
			derr: core.Error
			switch c.spec {
			case .Csv:
				doc, derr = dsv.build(got, .Csv, c.layout)
			case .Tsv:
				doc, derr = dsv.build(got, .Tsv, c.layout)
			case .Plain:
				doc, derr = dsv.build(got, .Plain, c.layout)
			}
			walktest.expect_nil(t, derr)
			core.destroy(&doc)
		}
	}
}

// A cell that starts the output with a BOM is quoted, and one later in the text is not.
@(test)
a_bom_is_quoted_only_at_the_start :: proc(t: ^testing.T) {
	bom := "\xEF\xBB\xBFx"
	for rows in ([?][]Token_Row{{{1, bom, true, 1, 1}}, {{1, "a", true, 1, 1}, {2, bom, true, 1, 1}}}) {
		want, _ := dsv.marshal(rows, .Csv, {no_header = true}, write = {}, allocator = context.temp_allocator)
		got, err := token_rows(rows, .Csv, {no_header = true})
		defer delete(got)
		testing.expect_value(t, err.kind, core.Typed_Error_Kind.None)
		testing.expect_value(t, string(got), string(want))
	}
	tw: write.Tokens
	write.tokens_init(&tw, dsv.as(.Csv))
	write.value_string(&tw, bom)
	write.end_record(&tw)
	got, _ := write.tokens_finish(&tw)
	defer delete(got)
	testing.expect_value(t, string(got), "\"\xEF\xBB\xBFx\"\n")
}

@(test)
null_is_an_empty_cell :: proc(t: ^testing.T) {
	tw: write.Tokens
	write.tokens_init(&tw, dsv.as(.Csv))
	write.value_int(&tw, 1)
	write.value_null(&tw)
	write.value_null(&tw)
	write.end_record(&tw)
	write.value_null(&tw)
	write.value_int(&tw, 2)
	write.end_record(&tw)
	got, err := write.tokens_finish(&tw)
	defer delete(got)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, string(got), "1,,\n,2\n")
}

// A misuse returns its kind from the call, keeps it, and finishes with it and no bytes.
expect_token_refused :: proc(t: ^testing.T, spec: dsv.Spec, layout: dsv.Options, run: proc(tw: ^write.Tokens) -> core.Typed_Error_Kind, want: core.Typed_Error_Kind, loc := #caller_location) {
	tw: write.Tokens
	init := write.tokens_init(&tw, dsv.as(spec, layout))
	testing.expect_value(t, run(&tw) if init == .None else init, want, loc)
	testing.expect_value(t, write.value_int(&tw, 1), want, loc)
	got, err := write.tokens_finish(&tw)
	testing.expect_value(t, err.kind, want, loc)
	testing.expect_value(t, len(got), 0, loc)
}

@(test)
token_misuse_is_refused :: proc(t: ^testing.T) {
	W :: write
	expect_token_refused(t, .Csv, {}, proc(tw: ^W.Tokens) -> core.Typed_Error_Kind {return W.open_object(tw)}, .Unsupported)
	expect_token_refused(t, .Csv, {}, proc(tw: ^W.Tokens) -> core.Typed_Error_Kind {return W.open_array(tw)}, .Unsupported)
	expect_token_refused(t, .Csv, {}, proc(tw: ^W.Tokens) -> core.Typed_Error_Kind {return W.close(tw)}, .Unsupported)
	expect_token_refused(t, .Csv, {}, proc(tw: ^W.Tokens) -> core.Typed_Error_Kind {return W.key(tw, "a")}, .Unsupported)
	expect_token_refused(t, .Csv, {}, proc(tw: ^W.Tokens) -> core.Typed_Error_Kind {return W.value_float(tw, math.inf_f64(-1))}, .Non_Finite)
	expect_token_refused(t, .Csv, {}, proc(tw: ^W.Tokens) -> core.Typed_Error_Kind {return W.value_string(tw, "\xff\xfe")}, .Invalid_Utf8)
	expect_token_refused(t, .Tsv, {}, proc(tw: ^W.Tokens) -> core.Typed_Error_Kind {
			W.value_string(tw, "")
			return W.end_record(tw)
		}, .Unwritable)
	expect_token_refused(t, .Csv, {}, proc(tw: ^W.Tokens) -> core.Typed_Error_Kind {return W.end_record(tw)}, .Unwritable)
	expect_token_refused(t, .Plain, {}, proc(tw: ^W.Tokens) -> core.Typed_Error_Kind {return W.value_string(tw, "a,b")}, .Unwritable)
	expect_token_refused(t, .Plain, {comment = '#'}, proc(tw: ^W.Tokens) -> core.Typed_Error_Kind {return W.value_string(tw, "#a")}, .Unwritable)
	expect_token_refused(t, .Csv, {delimiter = '"'}, proc(tw: ^W.Tokens) -> core.Typed_Error_Kind {return .None}, .Bad_Option)
}

@(test)
a_record_left_open_is_refused :: proc(t: ^testing.T) {
	tw: write.Tokens
	write.tokens_init(&tw, dsv.as(.Csv))
	write.value_int(&tw, 1)
	write.end_record(&tw)
	write.value_int(&tw, 2)
	got, err := write.tokens_finish(&tw)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.Out_Of_Order)
	testing.expect_value(t, len(got), 0)
	write.tokens_init(&tw, dsv.as(.Csv))
	got, err = write.tokens_finish(&tw)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, len(got), 0)
}

@(test)
rows_to_a_stream :: proc(t: ^testing.T) {
	rows := make([]Token_Row, 9000, context.temp_allocator)
	for &r, i in rows {
		r = TOKEN_ROWS[i % len(TOKEN_ROWS)]
		r.id = i64(i)
	}
	want, _ := dsv.marshal(rows, .Csv, {}, write = {}, allocator = context.temp_allocator)
	buf: bytes.Buffer
	defer bytes.buffer_destroy(&buf)
	got, err := token_rows(rows, .Csv, {}, bytes.buffer_to_stream(&buf))
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, len(got), 0)
	testing.expect(t, len(want) > 64 * 1024)
	testing.expect(t, string(bytes.buffer_to_bytes(&buf)) == string(want))
}

@(test)
rows_to_a_failing_stream :: proc(t: ^testing.T) {
	_, err := token_rows(TOKEN_ROWS[:], .Csv, {}, io.Stream{procedure = refusing_stream})
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.Write_Failed)
	testing.expect_value(t, err.cause, io.Error.Permission_Denied)
}

@(private)
token_try :: proc(data: rawptr, allocator: runtime.Allocator) -> ([]u8, core.Typed_Error_Kind) {
	text, err := token_rows(TOKEN_ROWS[:], (^dsv.Spec)(data)^, {}, allocator = allocator)
	return text, err.kind
}

@(test)
rows_under_failing_allocators :: proc(t: ^testing.T) {
	for spec in ([?]dsv.Spec{.Csv, .Tsv}) {
		spec := spec
		want, _ := dsv.marshal(TOKEN_ROWS[:], spec, {}, write = {}, allocator = context.temp_allocator)
		walktest.sweep_write(t, token_try, &spec, string(want))
	}
}
