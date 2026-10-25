package csv_tests

// `csv.validate_records`: the records `validate` refuses, one fault for each, in source order, each with its
// bytes in the text and its fault's offset into the text. A refused record's end cannot be trusted, so the read
// resumes at the line after it and the records after a fault are listed too.

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
	// A four-field record, then a record a field short, a quote inside a field, and a quote that never closes:
	// the refused records start at offsets 8, 14 and 25 in the text.
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
		testing.expectf(t, err == want[0].err, "%v, want %v", err, want[0].err)
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

// A quote inside a field and a UTF-8 lead: both are framing faults, and the line after each is read on.
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
		// A two-field record, a short record, then the refused row and a clean record after it: 0, 4, 10, 14.
		src := transmute([]byte)strings.concatenate({"a,b\n1,2,3\n3,4\n", c.row, "7,8\n"}, context.temp_allocator)
		want := []cs.Record_Fault {
			{lo = 4, hi = 9, err = cs.Error{kind = .Field_Count, offset = 4}},
			{lo = 14, hi = 20, err = cs.Error{kind = .Bad_Char, offset = u64(14 + c.at)}},
		}
		testing.expect_value(t, cs.validate(src), want[0].err)
		for runner in ([]^cs.Batch_Runner{nil, &caller, &pool.runner}) {
			faults, err := cs.validate_records(src, {}, runner)
			defer delete(faults)
			// The faults before the framing fault stand, and it is listed after them: `err` is the text's first.
			testing.expectf(t, slice.equal(faults, want), "%q: %v, want %v", c.row, faults, want)
			testing.expectf(t, err == want[0].err, "%q: %v, want %v", c.row, err, want[0].err)
			testing.expect_value(t, faults[len(faults) - 1].err, want[1].err)
		}
	}
	// With no refused record before it, the framing fault is the text's first and so the batch's.
	for c in TAIL_CASES {
		src := transmute([]byte)strings.concatenate({"a,b\n", c.row, "7,8\n"}, context.temp_allocator)
		want := cs.Error{kind = .Bad_Char, offset = u64(4 + c.at)}
		for runner in ([]^cs.Batch_Runner{nil, &caller, &pool.runner}) {
			faults, err := cs.validate_records(src, {}, runner)
			defer delete(faults)
			testing.expectf(t, len(faults) == 1, "%q: %v", c.row, faults)
			testing.expectf(t, faults[0].err == want && err == want, "%q: %v %v, want %v", c.row, faults, err, want)
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
		// UTF-8 is not judged under `.Structural`, so the row is no fault there.
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
			testing.expectf(t, err == serr, "%d bytes: %v, serial %v", len(src), err, serr)
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
		fe, fbad := err.?
		testing.expectf(t, vbad == fbad, "%q: validate %v, list %v", c.src, whole, err)
		if vbad && fbad {
			testing.expectf(t, fe == ve, "%q: validate %v, list %v", c.src, ve, fe)
		}
		testing.expectf(t, len(faults) > 0 == vbad, "%q: %d faults, validate %v", c.src, len(faults), whole)
		if len(faults) > 0 {
			testing.expectf(t, faults[0].err == ve, "%q: first fault %v, validate %v", c.src, faults[0].err, ve)
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
