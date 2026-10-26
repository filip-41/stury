package csv_tests

import "base:runtime"
import "core:slice"
import "core:strings"
import "core:testing"
import cs ".."
import host "../../host"

// A runner whose helpers never start: the caller claims every piece, in source order.
@(private = "file")
caller_only :: proc() -> cs.Batch_Runner {
	return {
		threads = 64,
		start = proc(data: rawptr, n: int, task: proc(arg: rawptr), arg: rawptr) {},
		finish = proc(data: rawptr) {},
	}
}

@(test)
test_validate_records_lists_three_bad_rows :: proc(t: ^testing.T) {
	src := transmute([]byte)string("1,2,3,4\n1,2,3\n1,2,3,ab\"c\n1,2,3,\"open\n")
	want := []cs.Record_Fault {
		{lo = 8, hi = 13, err = cs.Error{kind = .Field_Count, offset = 8}},
		{lo = 14, hi = 24, err = cs.Error{kind = .Bad_Char, offset = 22}},
		{lo = 25, hi = 37, err = cs.Error{kind = .Truncated, offset = 37}},
	}
	// `validate` stops at the first refused record, so its fault is the list's first.
	testing.expect_value(t, cs.validate(src), want[0].err)
	caller := caller_only()
	pool: host.Batch_Pool
	host.batch_pool_init(&pool, 4)
	defer host.batch_pool_destroy(&pool)
	for runner in ([]^cs.Batch_Runner{nil, &caller, &pool.runner}) {
		faults, err := cs.validate_records(src, {}, runner)
		defer delete(faults)
		testing.expectf(t, slice.equal(faults, want), "%v, want %v", faults, want)
		testing.expect_value(t, err, nil)
		// Each fault's bytes are the refused record's, and its offset is into the text, not into the record.
		testing.expect_value(t, string(src[faults[0].lo:faults[0].hi]), "1,2,3")
		testing.expect_value(t, string(src[faults[1].lo:faults[1].hi]), `1,2,3,ab"c`)
		testing.expect_value(t, string(src[faults[2].lo:faults[2].hi]), "1,2,3,\"open\n")
		testing.expect_value(t, cs.render_error(src, faults[1].err, context.temp_allocator), "3:9: Bad_Char")
	}
}

// A row `validate` refuses, and the offset in it of the refused byte.
@(private = "file")
Tail_Case :: struct {
	row: string,
	at:  int,
}

// A quote inside a field and a UTF-8 lead: both leave the record's end to the quote count, and the line after
// each is read on.
@(private = "file")
TAIL_CASES :: []Tail_Case {
	{`5,ab"c` + "\n", 4},
	{"5,ab\xffc\n", 4},
}

@(test)
test_validate_records_reads_on_after_a_framing_fault :: proc(t: ^testing.T) {
	caller := caller_only()
	pool: host.Batch_Pool
	host.batch_pool_init(&pool, 4)
	defer host.batch_pool_destroy(&pool)
	for c in TAIL_CASES {
		src := transmute([]byte)strings.concatenate({"a,b\n1,2,3\n3,4\n", c.row, "7,8\n"}, context.temp_allocator)
		want := []cs.Record_Fault {
			{lo = 4, hi = 9, err = cs.Error{kind = .Field_Count, offset = 4}},
			{lo = 14, hi = 20, err = cs.Error{kind = .Bad_Char, offset = u64(14 + c.at)}},
		}
		testing.expect_value(t, cs.validate(src), want[0].err)
		for runner in ([]^cs.Batch_Runner{nil, &caller, &pool.runner}) {
			faults, err := cs.validate_records(src, {}, runner)
			defer delete(faults)
			testing.expectf(t, slice.equal(faults, want), "%q: %v, want %v", c.row, faults, want)
			testing.expect_value(t, err, nil)
			testing.expect_value(t, faults[len(faults) - 1].err, want[1].err)
		}
	}
	for c in TAIL_CASES {
		src := transmute([]byte)strings.concatenate({"a,b\n", c.row, "7,8\n"}, context.temp_allocator)
		want := cs.Error{kind = .Bad_Char, offset = u64(4 + c.at)}
		for runner in ([]^cs.Batch_Runner{nil, &caller, &pool.runner}) {
			faults, err := cs.validate_records(src, {}, runner)
			defer delete(faults)
			testing.expectf(t, len(faults) == 1, "%q: %v", c.row, faults)
			testing.expectf(t, faults[0].err == want && err == nil, "%q: %v %v, want %v", c.row, faults, err, want)
			testing.expect_value(t, string(src[faults[0].lo:faults[0].hi]), c.row[:len(c.row) - 1])
		}
	}
}

@(test)
test_validate_records_is_empty_on_a_clean_text :: proc(t: ^testing.T) {
	Clean_Case :: struct {
		src:  string,
		opts: cs.Read_Opts,
	}
	for c in ([]Clean_Case{
		{"1,2,3,4\n5,6,7,8\n", {}},
		{"1,2,3,4\n", {}},
		{"", {}},
		{"\xef\xbb\xbf1,2,3,4\n5,6,7,8\n", {}},
		{"1,2\n1,2,3\n", {dialect = {ragged = true}}},
		{"1,2,3,4\n1,2,3,\xff\n", {strictness = .Structural}},
	}) {
		src := transmute([]byte)c.src
		testing.expectf(t, cs.validate(src, c.opts) == nil, "%q", c.src)
		faults, err := cs.validate_records(src, c.opts)
		testing.expectf(t, err == nil && faults == nil, "%q: %v %v", c.src, faults, err)
		delete(faults)
	}
}

// A text of four chunks, so a pool splits its first-fault scan, and a text whose refused records are spread
// through it: the list is the text's, not the runner's.
@(test)
test_validate_records_agrees_across_runners :: proc(t: ^testing.T) {
	big: [dynamic]byte
	defer delete(big)
	for i in 0 ..< 40000 {
		if i % 8000 == 4000 {
			append(&big, ..transmute([]byte)string("1,2,3\n"))
			continue
		}
		append(&big, ..transmute([]byte)string("1,2,3,4\n"))
	}
	pool: host.Batch_Pool
	host.batch_pool_init(&pool, 4)
	defer host.batch_pool_destroy(&pool)
	for src in ([][]byte{big[:], transmute([]byte)string("1,2,3,4\n1,2,3\n")}) {
		serial, serr := cs.validate_records(src)
		defer delete(serial)
		testing.expectf(t, len(serial) > 0, "%d bytes: no faults", len(src))
		for runner in ([]^cs.Batch_Runner{nil, &pool.runner}) {
			faults, err := cs.validate_records(src, {}, runner)
			defer delete(faults)
			testing.expectf(t, slice.equal(faults, serial), "%d bytes: %v, serial %v", len(src), faults, serial)
			testing.expectf(t, err == nil && serr == nil, "%d bytes: %v, serial %v", len(src), err, serr)
		}
	}
}

// `validate` and the list agree on what the text refuses: the same verdict, and the same first fault.
@(test)
test_validate_records_agrees_with_validate :: proc(t: ^testing.T) {
	Case :: struct {
		src:  string,
		opts: cs.Read_Opts,
	}
	for c in ([]Case{
		{"1,2,3,4\n", {}},
		{"1,2,3,4\n1,2,3\n", {}},
		{"1,2,3,4\n1,2,3,ab\"c\n", {}},
		{"1,2,3,4\n1,2,3,\"open\n", {}},
		{"1,2,3,4\r1,2,3,4\n", {}},
		{"1,2,3,4\n1,2,3,\xff\n", {}},
		{"1,2,3,4\n1,2,3,\xff\n", {strictness = .Structural}},
		{"1,2\n1,2,3\n", {dialect = {ragged = true}}},
		{"1,2,3,4\n1,2,3,4,5\n", {limits = {max_fields = 4}}},
		{"1,2,3,4\n1,2,3,4\n", {limits = {max_record_bytes = 4}}},
		{"\xef\xbb\xbf1,2,3,4\n1,2,3\n", {}},
		{"1,2,3,4\r\n", {}},
		{"1\t2\n3\t4\n1\t2\t3\n", {dialect = cs.TSV}},
		{"#note\n1,2,3,4\n1,2\n", {dialect = {comment = '#'}}},
	}) {
		src := transmute([]byte)c.src
		whole := cs.validate(src, c.opts)
		ve, vbad := whole.?
		faults, err := cs.validate_records(src, c.opts)
		defer delete(faults)
		testing.expectf(t, err == nil, "%q: err %v", c.src, err)
		testing.expectf(t, len(faults) > 0 == vbad, "%q: %d faults, validate %v", c.src, len(faults), whole)
		if len(faults) > 0 {
			testing.expectf(t, faults[0].err == ve, "%q: first fault %v, validate %v", c.src, faults[0].err, ve)
		}
	}
}

// One refused record, and the text the read resumes at.
@(private = "file")
Span_Case :: struct {
	name: string,
	src:  string,
	opts: cs.Read_Opts,
	want: []cs.Record_Fault,
}

@(private = "file")
SPAN_CASES :: []Span_Case {
	// A quoted LF inside a record that has too few fields, too many, or too many bytes is not its end: the
	// resume does not land in the quoted field.
	{"field count", "a,b,c\n1,\"x\ny\"\n4,5,6\n", {}, []cs.Record_Fault{{lo = 6, hi = 13, err = {kind = .Field_Count, offset = 6}}}},
	{"field cap", "a,b,c\n1,\"x\ny\",3,4\n4,5,6\n", {limits = {max_fields = 3}}, []cs.Record_Fault{{lo = 6, hi = 17, err = {kind = .Limit_Fields, offset = 6}}}},
	{"record cap", "a,b\n1,\"x\ny\"\n4,5\n", {limits = {max_record_bytes = 3}}, []cs.Record_Fault{{lo = 4, hi = 11, err = {kind = .Limit_Record, offset = 4}}}},
	// A fault inside a multi-line quoted field ends at the LF past the field's close.
	{"utf-8 in quotes", "a,b\n\"x\ny\xff\nz\",2\n4,5\n", {}, []cs.Record_Fault{{lo = 4, hi = 14, err = {kind = .Bad_Char, offset = 8}}}},
	// A final refused record without an LF spans to the input's end.
	{"last, field count", "a,b,c\n1,2", {}, []cs.Record_Fault{{lo = 6, hi = 9, err = {kind = .Field_Count, offset = 6}}}},
	{"last, too many", "a,b\n1,2\n3,4,5", {}, []cs.Record_Fault{{lo = 8, hi = 13, err = {kind = .Field_Count, offset = 8}}}},
	{"last, quote fault", "a,b\n1,2\n3,x\"y", {}, []cs.Record_Fault{{lo = 8, hi = 13, err = {kind = .Bad_Char, offset = 11}}}},
	{"last, open quote", "a,b\n1,2\n3,\"y\n", {}, []cs.Record_Fault{{lo = 8, hi = 13, err = {kind = .Truncated, offset = 13}}}},
	{"crlf, field count", "a,b,c\r\n1,2\r\n4,5,6\r\n", {}, []cs.Record_Fault{{lo = 7, hi = 10, err = {kind = .Field_Count, offset = 7}}}},
	{"crlf, quote fault", "a,b\r\n3,x\"y\r\n5,6\r\n", {}, []cs.Record_Fault{{lo = 5, hi = 10, err = {kind = .Bad_Char, offset = 8}}}},
	{"stray quote", "a,b\n3,x\"y\n4,5,6\n7,8\n", {}, []cs.Record_Fault{
		{lo = 4, hi = 9, err = {kind = .Bad_Char, offset = 7}},
		{lo = 10, hi = 15, err = {kind = .Field_Count, offset = 10}},
	}},
	{"comment line", "a,b\n#\xff\"x\n1,2\n", {dialect = {comment = '#'}}, []cs.Record_Fault{{lo = 4, hi = 8, err = {kind = .Bad_Char, offset = 5}}}},
	{"unquoted", "a;b\n1;\"x;3\n4;5\n", {dialect = {delimiter = ';', quoting = .None}}, []cs.Record_Fault{{lo = 4, hi = 10, err = {kind = .Field_Count, offset = 4}}}},
}

// The span of a refused record is its bytes without the line break, one fault per record whatever the quotes in
// it, on every runner, and the first fault is `validate`'s.
@(test)
test_validate_records_spans_the_refused_record :: proc(t: ^testing.T) {
	caller := caller_only()
	pool: host.Batch_Pool
	host.batch_pool_init(&pool, 4)
	defer host.batch_pool_destroy(&pool)
	for c in SPAN_CASES {
		src := transmute([]byte)c.src
		testing.expect_value(t, cs.validate(src, c.opts), Maybe(cs.Error)(c.want[0].err))
		for runner in ([]^cs.Batch_Runner{nil, &caller, &pool.runner}) {
			faults, err := cs.validate_records(src, c.opts, runner)
			defer delete(faults)
			testing.expectf(t, slice.equal(faults, c.want), "%s: %v, want %v", c.name, faults, c.want)
			testing.expectf(t, err == nil, "%s: err %v", c.name, err)
		}
	}
}

// A refused allocation is `.Out_Of_Memory`, never a list with refused records missing.
@(test)
test_validate_records_refused_allocation_is_out_of_memory :: proc(t: ^testing.T) {
	src := transmute([]byte)string("1,2,3,4\n1,2,3\n")
	faults, err := cs.validate_records(src, allocator = runtime.nil_allocator())
	testing.expect_value(t, err, cs.Error{kind = .Out_Of_Memory})
	testing.expect(t, faults == nil)
}
