package csv_tests

// `Record_Read`: one row per `unmarshal`, matching `unmarshal` of the same table, from an in-memory `Records`
// or a streaming `Record_Reader`. The header is read once, a fault's offset is into the row's bytes, the options
// the reader holds apply at each row, and a reader is destroyed once.

import "core:fmt"
import "core:io"
import "core:mem"
import "core:strings"
import "core:testing"
import csv "../"

@(private = "file")
um_err :: proc(err: Maybe(csv.Unmarshal_Error)) -> csv.Unmarshal_Error {
	e, _ := err.?
	return e
}

// One read of `rd` that pulls a row: that row's refusal.
@(private = "file")
pull :: proc(t: ^testing.T, rd: ^csv.Record_Read, ptr: ^$T, loc := #caller_location) -> Maybe(csv.Unmarshal_Error) {
	more, err := csv.unmarshal(rd, ptr)
	testing.expect(t, more, "no row pulled", loc = loc)
	return err
}

// One read of `rd` that pulls no row: nil at the input's end, else why the rows ended.
@(private = "file")
past_end :: proc(t: ^testing.T, rd: ^csv.Record_Read, ptr: ^$T, loc := #caller_location) -> Maybe(csv.Unmarshal_Error) {
	more, err := csv.unmarshal(rd, ptr)
	testing.expect(t, !more, "a row pulled past the end", loc = loc)
	return err
}

@(private = "file")
Rec :: struct {
	id:   i64,
	name: string `csv:"full name"`,
	v:    f64,
	ok:   bool,
}

// A reader over `src`'s bytes, at most `step` bytes a call (all of them when 0), failing with `fail` instead of
// ending when it is set.
@(private = "file")
Bytes :: struct {
	src:  []byte,
	pos:  int,
	step: int,
	fail: io.Error,
}

@(private = "file")
bytes_read :: proc(data: rawptr, mode: io.Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From) -> (i64, io.Error) {
	b := (^Bytes)(data)
	#partial switch mode {
	case .Read:
		if b.pos == len(b.src) {
			return 0, b.fail if b.fail != nil else .EOF
		}
		n := copy(p[:min(len(p), b.step if b.step > 0 else len(p))], b.src[b.pos:])
		b.pos += n
		return i64(n), nil
	case .Query:
		return io.query_utility({.Read, .Query})
	}
	return 0, .Unsupported
}

@(test)
test_record_read_header_by_name :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	src := "full name,id,ok,v\n\"a, b\",1,true,2.5\nc,2,false,3\n"
	it := csv.records(transmute([]byte)src)
	defer csv.destroy(&it)
	rd: csv.Record_Read
	testing.expect_value(t, csv.record_read_init(&rd, Rec, &it, allocator = context.temp_allocator), nil)
	defer csv.destroy(&rd)
	first := 1 + len("full name,id,ok,v")
	got: Rec
	testing.expect_value(t, pull(t, &rd, &got), nil)
	testing.expect_value(t, got.id, i64(1))
	testing.expect_value(t, got.name, "a, b")
	testing.expect_value(t, got.v, 2.5)
	testing.expect_value(t, got.ok, true)
	testing.expect_value(t, csv.record_read_at(&rd), u64(first))
	testing.expect_value(t, pull(t, &rd, &got), nil)
	testing.expect_value(t, got.id, i64(2))
	testing.expect_value(t, got.name, "c")
	testing.expect_value(t, got.v, 3.0)
	testing.expect_value(t, got.ok, false)
	testing.expect(t, csv.record_read_at(&rd) > u64(first))
	testing.expect_value(t, past_end(t, &rd, &got), nil)
}

@(test)
test_record_read_header_in_order :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	// `no_header`: column k is the struct's field k, and the dialect is ragged so a row may hold fewer.
	src := "7,a,1.5,true\n8,b,2.5,false\n"
	it := csv.records(transmute([]byte)src, {no_header = true})
	defer csv.destroy(&it)
	rd: csv.Record_Read
	testing.expect_value(t, csv.record_read_init(&rd, Rec, &it, {no_header = true}, allocator = context.temp_allocator), nil)
	defer csv.destroy(&rd)
	got: Rec
	testing.expect_value(t, pull(t, &rd, &got), nil)
	testing.expect_value(t, got.id, i64(7))
	testing.expect_value(t, got.name, "a")
	testing.expect_value(t, got.v, 1.5)
	testing.expect_value(t, got.ok, true)
	testing.expect_value(t, csv.record_read_at(&rd), u64(0))
}

@(test)
test_record_read_missing_and_extra_cells :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	src := "id,full name,v,ok\n1,a,1.5,true,extra\n2\n"
	it := csv.records(transmute([]byte)src, {dialect = {ragged = true}})
	defer csv.destroy(&it)
	rd: csv.Record_Read
	opt := csv.Unmarshal_Opts {
		read = {dialect = {ragged = true}},
	}
	testing.expect_value(t, csv.record_read_init(&rd, Rec, &it, opt, allocator = context.temp_allocator), nil)
	defer csv.destroy(&rd)
	got: Rec
	testing.expect_value(t, pull(t, &rd, &got), nil)
	testing.expect_value(t, got.id, i64(1))
	testing.expect_value(t, got.name, "a")
	testing.expect_value(t, got.v, 1.5)
	// The missing row: only `id`. A cell the row lacks leaves the field as the destination held it, as
	// `unmarshal` leaves a member the text lacks.
	got = {}
	testing.expect_value(t, pull(t, &rd, &got), nil)
	testing.expect_value(t, got.id, i64(2))
	testing.expect_value(t, got.name, "")
	testing.expect_value(t, got.v, 0)
	testing.expect_value(t, got.ok, false)

	// `.Refuse` refuses a cell past the header's columns, at that cell in the row.
	it2 := csv.records(transmute([]byte)src, {dialect = {ragged = true}})
	defer csv.destroy(&it2)
	rr: csv.Record_Read
	refuse := csv.Unmarshal_Opts {
		read           = {dialect = {ragged = true}},
		unknown_fields = .Refuse,
	}
	testing.expect_value(t, csv.record_read_init(&rr, Rec, &it2, refuse, allocator = context.temp_allocator), nil)
	defer csv.destroy(&rr)
	err := um_err(pull(t, &rr, &got))
	testing.expect_value(t, err.kind, .Unknown_Field)
	testing.expect_value(t, csv.record_read_at(&rr) + err.offset, u64(len("id,full name,v,ok\n1,a,1.5,true,")))
	testing.expect_value(t, src[int(csv.record_read_at(&rr) + err.offset):], "extra\n2\n")
}

@(test)
test_record_read_duplicate_header :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	src := "id,id\n1,2\n"
	it := csv.records(transmute([]byte)src)
	defer csv.destroy(&it)
	rd: csv.Record_Read
	testing.expect_value(t, um_err(csv.record_read_init(&rd, Rec, &it, {duplicates = .Refuse}, allocator = context.allocator)).kind, .Duplicate_Key)
	it_default := csv.records(transmute([]byte)src)
	defer csv.destroy(&it_default)
	testing.expect_value(t, csv.record_read_init(&rd, Rec, &it_default, allocator = context.temp_allocator), nil)
	csv.destroy(&rd)
	it2 := csv.records(transmute([]byte)src)
	defer csv.destroy(&it2)
	testing.expect_value(t, csv.record_read_init(&rd, Rec, &it2, {duplicates = .First}, allocator = context.temp_allocator), nil)
	defer csv.destroy(&rd)
	got: Rec
	testing.expect_value(t, pull(t, &rd, &got), nil)
	testing.expect_value(t, got.id, i64(1))
	it3 := csv.records(transmute([]byte)src)
	defer csv.destroy(&it3)
	testing.expect_value(t, csv.record_read_init(&rd, Rec, &it3, {duplicates = .Last}, allocator = context.temp_allocator), nil)
	testing.expect_value(t, pull(t, &rd, &got), nil)
	testing.expect_value(t, got.id, i64(2))
}

@(test)
test_record_read_live_options :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	// Two rows with a cell past the header's: the first is ignored, the second refused after the option changes.
	src := "id,full name,v,ok\n1,a,1.5,true,extra\n2,b,2.5,false,extra\n3,c,3.5,true,extra\n"
	it := csv.records(transmute([]byte)src, {dialect = {ragged = true}})
	defer csv.destroy(&it)
	rd: csv.Record_Read
	opt := csv.Unmarshal_Opts {
		read = {dialect = {ragged = true}},
	}
	testing.expect_value(t, csv.record_read_init(&rd, Rec, &it, opt, allocator = context.temp_allocator), nil)
	defer csv.destroy(&rd)
	got: Rec
	testing.expect_value(t, pull(t, &rd, &got), nil)
	testing.expect_value(t, got.id, i64(1))
	rd.opts.unknown_fields = .Refuse
	err := um_err(pull(t, &rd, &got))
	testing.expect_value(t, err.kind, .Unknown_Field)
	testing.expect_value(t, src[int(csv.record_read_at(&rd) + err.offset):], "extra\n3,c,3.5,true,extra\n")
	rd.opts.unknown_fields = .Ignore
	testing.expect_value(t, pull(t, &rd, &got), nil)
	testing.expect_value(t, got.id, i64(3))

	// `borrow_strings` is bound with the column table: a borrowed string points into the source.
	buf := make([]byte, len(src), context.temp_allocator)
	copy(buf, src)
	bit := csv.records(buf, {dialect = {ragged = true}})
	defer csv.destroy(&bit)
	br: csv.Record_Read
	bopt := csv.Unmarshal_Opts {
		read           = {dialect = {ragged = true}},
		borrow_strings = true,
	}
	testing.expect_value(t, csv.record_read_init(&br, Rec, &bit, bopt, allocator = context.temp_allocator), nil)
	defer csv.destroy(&br)
	testing.expect_value(t, pull(t, &br, &got), nil)
	testing.expect(t, string_is_in(got.name, buf))
}

@(private = "file")
string_is_in :: proc(s: string, src: []byte) -> bool {
	lo := uintptr(raw_data(src))
	p := uintptr(raw_data(s))
	return p >= lo && p + uintptr(len(s)) <= lo + uintptr(len(src))
}

@(test)
test_record_read_fault_is_into_the_row :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	src := "id,full name,v,ok\n1,a,1.5,true\n2,b,oops,false\n"
	it := csv.records(transmute([]byte)src)
	defer csv.destroy(&it)
	rd: csv.Record_Read
	testing.expect_value(t, csv.record_read_init(&rd, Rec, &it, allocator = context.temp_allocator), nil)
	defer csv.destroy(&rd)
	got: Rec
	testing.expect_value(t, pull(t, &rd, &got), nil)
	err := um_err(pull(t, &rd, &got))
	at := csv.record_read_at(&rd)
	testing.expect(t, at > 0)
	testing.expect_value(t, err.kind, .Wrong_Kind)
	testing.expect(t, err.offset < u64(len(src)) - at)
	testing.expect_value(t, src[int(at + err.offset):], "oops,false\n")
	testing.expect_value(t, err.n_steps, u8(2))
	if name, ok := err.steps[1].(csv.Name); ok {
		testing.expect_value(t, string(name), "v")
	} else {
		testing.expect(t, false)
	}
}

@(test)
test_record_read_stream :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	src := "full name,id,ok,v\n\"a, b\",1,true,2.5\nc,2,false,3\n"
	bytes := Bytes{src = transmute([]byte)src}
	rr := csv.records_from({procedure = bytes_read, data = &bytes}, allocator = context.temp_allocator)
	defer csv.destroy(&rr)
	rd: csv.Record_Read
	testing.expect_value(t, csv.record_read_init(&rd, Rec, &rr, allocator = context.temp_allocator), nil)
	defer csv.destroy(&rd)
	got: Rec
	testing.expect_value(t, pull(t, &rd, &got), nil)
	testing.expect_value(t, got.id, i64(1))
	testing.expect_value(t, got.name, "a, b")
	testing.expect_value(t, got.v, 2.5)
	testing.expect_value(t, got.ok, true)
	testing.expect_value(t, csv.record_read_at(&rd), u64(len("full name,id,ok,v\n")))
	testing.expect_value(t, pull(t, &rd, &got), nil)
	testing.expect_value(t, got.id, i64(2))
	testing.expect_value(t, got.name, "c")
	testing.expect_value(t, past_end(t, &rd, &got), nil)
}

@(test)
test_record_read_stream_fault_is_into_the_row :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	src := "id,full name,v,ok\n1,a,1.5,true\n2,b,oops,false\n"
	bytes := Bytes{src = transmute([]byte)src}
	rr := csv.records_from({procedure = bytes_read, data = &bytes}, allocator = context.temp_allocator)
	defer csv.destroy(&rr)
	rd: csv.Record_Read
	testing.expect_value(t, csv.record_read_init(&rd, Rec, &rr, allocator = context.temp_allocator), nil)
	defer csv.destroy(&rd)
	got: Rec
	testing.expect_value(t, pull(t, &rd, &got), nil)
	err := um_err(pull(t, &rd, &got))
	at := csv.record_read_at(&rd)
	testing.expect_value(t, err.kind, .Wrong_Kind)
	testing.expect_value(t, at + err.offset, u64(len("id,full name,v,ok\n1,a,1.5,true\n2,b,")))
}

// A fault is at the same place in the row's bytes whether the rows come from the input or from a window that
// has dropped the bytes before them.
@(test)
test_record_read_stream_fault_after_drop_is_into_the_row :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	head := strings.concatenate({"id,full name,v,ok\n", strings.repeat("1,a,1.5,true\n", 40, context.temp_allocator)}, context.temp_allocator)
	src := strings.concatenate({head, "2,b,oops,false\n"}, context.temp_allocator)
	for step in READ_STEPS {
		bytes := Bytes{src = transmute([]byte)src, step = step}
		rr := csv.records_from({procedure = bytes_read, data = &bytes}, allocator = context.temp_allocator)
		defer csv.destroy(&rr)
		rd: csv.Record_Read
		testing.expect_value(t, csv.record_read_init(&rd, Rec, &rr, allocator = context.temp_allocator), nil)
		defer csv.destroy(&rd)
		got: Rec
		for _ in 0 ..< 40 {
			testing.expect_value(t, pull(t, &rd, &got), nil)
		}
		err := um_err(pull(t, &rd, &got))
		testing.expect_value(t, err.kind, .Wrong_Kind)
		testing.expect_value(t, csv.record_read_at(&rd), u64(len(head)))
		testing.expect_value(t, err.offset, u64(len("2,b,")))
	}
}

// A fault that frames no row has no row to be in: its offset is in the input, from an `Records` and from a window
// that has dropped the bytes before it, and `record_read_at` is 0.
@(test)
test_record_read_framing_fault_is_into_the_input :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Id :: struct {
		id: i64,
	}
	head := strings.concatenate({"id\n", strings.repeat("1\n", 40, context.temp_allocator), "2"}, context.temp_allocator)
	src := strings.concatenate({head, "\xFF\n3\n"}, context.temp_allocator)
	at := u64(len(head))
	whole := csv.records(transmute([]byte)src)
	defer csv.destroy(&whole)
	bytes := Bytes{src = transmute([]byte)src, step = 3}
	rr := csv.records_from({procedure = bytes_read, data = &bytes}, allocator = context.temp_allocator)
	defer csv.destroy(&rr)
	for source in 0 ..< 2 {
		rd: csv.Record_Read
		init_err := csv.record_read_init(&rd, Id, &whole, allocator = context.temp_allocator) if source == 0 else csv.record_read_init(&rd, Id, &rr, allocator = context.temp_allocator)
		testing.expect_value(t, init_err, nil)
		defer csv.destroy(&rd)
		got: Id
		for _ in 0 ..< 40 {
			testing.expect_value(t, pull(t, &rd, &got), nil)
		}
		err := um_err(past_end(t, &rd, &got))
		testing.expectf(t, err.kind == .Syntax && err.syntax == .Bad_Char, "source %d: %v", source, err)
		testing.expect_value(t, csv.record_read_at(&rd), u64(0))
		testing.expect_value(t, err.offset, at)
	}
}

// The end of the input is no row and no error; a reader that failed ends the rows read before it as `.Syntax`
// `.Truncated`, at the end of the bytes it gave.
@(test)
test_record_read_reader_failure_is_not_the_end :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Id :: struct {
		id: i64,
	}
	src := "id\n1\n2\n3"
	for fail in ([]io.Error{nil, .Unexpected_EOF}) {
		bytes := Bytes{src = transmute([]byte)src, step = 2, fail = fail}
		rr := csv.records_from({procedure = bytes_read, data = &bytes}, allocator = context.temp_allocator)
		defer csv.destroy(&rr)
		rd: csv.Record_Read
		testing.expect_value(t, csv.record_read_init(&rd, Id, &rr, allocator = context.temp_allocator), nil)
		defer csv.destroy(&rd)
		got: Id
		testing.expect_value(t, pull(t, &rd, &got), nil)
		testing.expect_value(t, pull(t, &rd, &got), nil)
		if fail == nil {
			testing.expect_value(t, pull(t, &rd, &got), nil)
			testing.expect_value(t, got.id, i64(3))
			testing.expect_value(t, past_end(t, &rd, &got), nil)
		} else {
			// The bytes after the last line feed are not a row once the reader failed.
			err := um_err(past_end(t, &rd, &got))
			testing.expectf(t, err.kind == .Syntax && err.syntax == .Truncated, "%v", err)
			testing.expect_value(t, err.offset, u64(len(src)))
			testing.expect_value(t, rr.read_err, fail)
		}
	}
	// A reader that fails before the header is not an empty table.
	bytes := Bytes{fail = .Unexpected_EOF}
	rr := csv.records_from({procedure = bytes_read, data = &bytes}, allocator = context.temp_allocator)
	defer csv.destroy(&rr)
	rd: csv.Record_Read
	err := um_err(csv.record_read_init(&rd, Id, &rr, allocator = context.temp_allocator))
	testing.expectf(t, err.kind == .Syntax && err.syntax == .Truncated, "%v", err)
}

// The column table of a `no_header` reader is made with the allocator of `record_read_init`, whatever the context
// of the first `unmarshal`, so `destroy` frees it where it came from.
@(test)
test_record_read_no_header_columns_use_the_init_allocator :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Pair :: struct {
		a: i64,
		b: i64,
	}
	it := csv.records(transmute([]byte)string("1,2\n3,4\n"), {no_header = true})
	defer csv.destroy(&it)
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	rd: csv.Record_Read
	got: Pair
	{
		context.allocator = mem.tracking_allocator(&track)
		testing.expect_value(t, csv.record_read_init(&rd, Pair, &it, {read = {no_header = true}}, allocator = context.temp_allocator), nil)
		{
			context.allocator = context.temp_allocator
			testing.expect_value(t, pull(t, &rd, &got), nil)
		}
		csv.destroy(&rd)
	}
	testing.expect_value(t, got, Pair{1, 2})
	testing.expect_value(t, len(track.bad_free_array), 0)
	testing.expect_value(t, len(track.allocation_map), 0)
}

// The rows are framed by the iterator's scan, so a reader whose dialect, limits or strictness differ from it is
// refused, except a `.Lazy` reader over a scan that judged UTF-8.
@(test)
test_record_read_refuses_a_scan_of_other_options :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Id :: struct {
		id: i64,
	}
	src := transmute([]byte)string("id\n\"1\"\n\xFF\n")
	rd: csv.Record_Read
	defer csv.destroy(&rd)
	Case :: struct {
		scan:   csv.Read_Opts,
		reader: csv.Unmarshal_Opts,
		ok:     bool,
	}
	cases := []Case {
		{scan = {strictness = .Lazy}, reader = {read = {strictness = .Strict}}, ok = false},
		{scan = {strictness = .Structural}, reader = {read = {strictness = .Strict}}, ok = false},
		{scan = {strictness = .Strict}, reader = {read = {strictness = .Structural}}, ok = false},
		{scan = {dialect = csv.TSV}, reader = {}, ok = false},
		{scan = {}, reader = {read = {dialect = csv.TSV}}, ok = false},
		{scan = {limits = {max_fields = 4}}, reader = {}, ok = false},
		{scan = {}, reader = {read = {dialect = {ragged = true}}}, ok = false},
		{scan = {dialect = csv.TSV}, reader = {read = {dialect = csv.TSV}}, ok = true},
		{scan = {strictness = .Strict}, reader = {read = {strictness = .Lazy}}, ok = true},
		{scan = {strictness = .Lazy}, reader = {read = {strictness = .Lazy}}, ok = true},
		{scan = {strictness = .Structural}, reader = {read = {strictness = .Structural}}, ok = true},
	}
	for c, k in cases {
		it := csv.records(src, c.scan)
		defer csv.destroy(&it)
		err := csv.record_read_init(&rd, Id, &it, c.reader, allocator = context.temp_allocator)
		if c.ok {
			testing.expectf(t, err == nil, "case %d: %v", k, err)
		} else {
			testing.expectf(t, um_err(err).kind == .Bad_Option, "case %d: %v", k, err)
		}
	}
}

// A scan that skipped UTF-8 leaves it to the reader: set to `.Strict` after init, the reader judges every cell.
@(test)
test_record_read_strict_after_init_judges_utf8 :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Text :: struct {
		a: string,
	}
	src := transmute([]byte)string("a,b\nx,y\nz,\xFF\nw,v\n")
	for level in ([]csv.Strictness{.Lazy, .Structural}) {
		it := csv.records(src, {strictness = level})
		defer csv.destroy(&it)
		rd: csv.Record_Read
		testing.expect_value(t, csv.record_read_init(&rd, Text, &it, {read = {strictness = level}}, allocator = context.temp_allocator), nil)
		defer csv.destroy(&rd)
		got: Text
		testing.expect_value(t, pull(t, &rd, &got), nil)
		// The fault is in a column no field reads: only a strict read refuses it.
		rd.opts.strictness = .Strict
		err := um_err(pull(t, &rd, &got))
		testing.expectf(t, err.kind == .Syntax && err.syntax == .Bad_Char, "%v: %v", level, err)
	}
}

@(test)
test_record_read_destroy_twice :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	it := csv.records(transmute([]byte)string("id\n1\n"))
	defer csv.destroy(&it)
	rd: csv.Record_Read
	testing.expect_value(t, csv.record_read_init(&rd, Rec, &it, allocator = context.allocator), nil)
	csv.destroy(&rd)
	csv.destroy(&rd)
	got: Rec
	testing.expect_value(t, um_err(past_end(t, &rd, &got)).kind, .Bad_Option)
	// A handle that was never initialized is empty.
	empty: csv.Record_Read
	csv.destroy(&empty)
	testing.expect_value(t, um_err(past_end(t, &empty, &got)).kind, .Bad_Option)
}

@(test)
test_record_read_borrows_the_callers_plan :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	plan := csv.type_plan_init(Rec, {}, context.temp_allocator)
	it := csv.records(transmute([]byte)string("id,full name,v,ok\n3,x,4.5,true\n"))
	defer csv.destroy(&it)
	rd: csv.Record_Read
	testing.expect_value(t, csv.record_read_init(&rd, Rec, &it, {}, &plan, context.temp_allocator), nil)
	got: Rec
	testing.expect_value(t, pull(t, &rd, &got), nil)
	testing.expect_value(t, got.id, i64(3))
	csv.destroy(&rd)
	// The plan outlives the reader: another reader borrows it and reads.
	it2 := csv.records(transmute([]byte)string("id,full name,v,ok\n4,y,5.5,false\n"))
	defer csv.destroy(&it2)
	rd2: csv.Record_Read
	testing.expect_value(t, csv.record_read_init(&rd2, Rec, &it2, {}, &plan, context.temp_allocator), nil)
	defer csv.destroy(&rd2)
	testing.expect_value(t, pull(t, &rd2, &got), nil)
	testing.expect_value(t, got.id, i64(4))
}

// `.Lazy` judges the UTF-8 of every cell a field reads and of no other, from a scan that defers its faults and
// from one that skipped them at creation.
@(test)
test_record_read_lazy_utf8 :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Text :: struct {
		a: string,
	}
	// A fault in the column no field reads, a good row, then a fault in the column read.
	src := "a,b\nx,\xFF\ny,z\n\xFE,q\n"
	for created in ([]csv.Strictness{.Strict, .Lazy}) {
		it := csv.records(transmute([]byte)src, {strictness = created})
		defer csv.destroy(&it)
		rd: csv.Record_Read
		testing.expect_value(t, csv.record_read_init(&rd, Text, &it, {strictness = .Lazy}, allocator = context.temp_allocator), nil)
		defer csv.destroy(&rd)
		got: Text
		testing.expectf(t, pull(t, &rd, &got) == nil, "%v: %v", created, got)
		testing.expect_value(t, got.a, "x")
		testing.expectf(t, pull(t, &rd, &got) == nil, "%v", created)
		testing.expect_value(t, got.a, "y")
		err := um_err(pull(t, &rd, &got))
		testing.expectf(t, err.kind == .Syntax && err.syntax == .Bad_Char, "%v: %v", created, err)
		testing.expect_value(t, err.offset, 0)
		at := csv.record_read_at(&rd)
		testing.expect_value(t, at + err.offset, u64(len("a,b\nx,\xFF\ny,z\n")))
		// The path names the row the fault is in, as `unmarshal`'s lazy UTF-8 fault does.
		testing.expect_value(t, err.n_steps, u8(1))
		if row, ok := err.steps[0].(csv.Index); ok {
			testing.expect_value(t, u64(row), 2)
		} else {
			testing.expect(t, false)
		}
	}
}

// A refusal at the first row of a `no_header` reader leaves it ready for the next row.
@(test)
test_record_read_no_header_refusal_keeps_reader_ready :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Pair :: struct {
		a: i64,
		b: i64,
	}
	src := "1,2,3\n4,5,6\n"
	it := csv.records(transmute([]byte)src, {no_header = true})
	defer csv.destroy(&it)
	rd: csv.Record_Read
	opts := csv.Unmarshal_Opts {
		read           = {no_header = true},
		unknown_fields = .Refuse,
	}
	testing.expect_value(t, csv.record_read_init(&rd, Pair, &it, opts, allocator = context.temp_allocator), nil)
	defer csv.destroy(&rd)
	got: Pair
	testing.expect_value(t, um_err(pull(t, &rd, &got)).kind, .Unknown_Field)
	testing.expect_value(t, um_err(pull(t, &rd, &got)).kind, .Unknown_Field)

	src2 := "1,2,3\n4,5\n"
	it2 := csv.records(transmute([]byte)src2, {no_header = true, dialect = {ragged = true}})
	defer csv.destroy(&it2)
	rr: csv.Record_Read
	opts2 := csv.Unmarshal_Opts {
		read           = {no_header = true, dialect = {ragged = true}},
		unknown_fields = .Refuse,
	}
	testing.expect_value(t, csv.record_read_init(&rr, Pair, &it2, opts2, allocator = context.temp_allocator), nil)
	defer csv.destroy(&rr)
	testing.expect_value(t, um_err(pull(t, &rr, &got)).kind, .Unknown_Field)
	rr.opts.unknown_fields = .Ignore
	testing.expect_value(t, pull(t, &rr, &got), nil)
	testing.expect_value(t, got, Pair{4, 5})

	// A required field no column of the first row reads is `.Missing_Field` for it and for the rows after it.
	Need :: struct {
		a: i64,
		b: i64 `csv:",required"`,
	}
	src3 := "1\n4\n"
	it3 := csv.records(transmute([]byte)src3, {no_header = true})
	defer csv.destroy(&it3)
	rn: csv.Record_Read
	testing.expect_value(t, csv.record_read_init(&rn, Need, &it3, {read = {no_header = true}}, allocator = context.temp_allocator), nil)
	defer csv.destroy(&rn)
	need: Need
	testing.expect_value(t, um_err(pull(t, &rn, &need)).kind, .Missing_Field)
	testing.expect_value(t, um_err(pull(t, &rn, &need)).kind, .Missing_Field)
}

@(private = "file")
READ_STEPS :: [?]int{1, 2, 3, 7, 64}

// Every row of a stream read a few bytes at a time is the row `unmarshal` reads from the whole text, at the
// offset `records` gives it: a CRLF or a quoted line break may fall between two reads, and so may a BOM.
@(test)
test_record_read_stream_in_small_reads :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	block := "\"a\r\nb, \"\"q\"\"\",1,true,2.5\r\nc,2,false,3\r\n\"\xC3\xA9\",3,true,0.5\r\n"
	body := strings.concatenate({"full name,id,ok,v\r\n", strings.repeat(block, 20, context.temp_allocator)}, context.temp_allocator)
	for text in ([]string{body, strings.concatenate({"\xEF\xBB\xBF", body}, context.temp_allocator)}) {
		whole := transmute([]byte)text
		want: [dynamic]Rec
		testing.expect_value(t, csv.unmarshal(whole, &want, {}, nil, context.temp_allocator), nil)
		starts := make([dynamic]u64, context.temp_allocator)
		it := csv.records(whole)
		defer csv.destroy(&it)
		for rec in csv.next_record(&it) {
			append(&starts, rec.at)
		}
		testing.expect_value(t, len(starts), len(want) + 1)
		for step in READ_STEPS {
			bytes := Bytes{src = whole, step = step}
			rr := csv.records_from({procedure = bytes_read, data = &bytes}, allocator = context.temp_allocator)
			defer csv.destroy(&rr)
			rd: csv.Record_Read
			testing.expect_value(t, csv.record_read_init(&rd, Rec, &rr, allocator = context.temp_allocator), nil)
			defer csv.destroy(&rd)
			for w, k in want {
				got: Rec
				err := pull(t, &rd, &got)
				testing.expectf(t, err == nil && got == w, "step %d row %d: %v, want %v, %v", step, k, got, w, err)
				testing.expect_value(t, csv.record_read_at(&rd), starts[k + 1])
			}
			testing.expect_value(t, past_end(t, &rd, &Rec{}), nil)
		}
	}
}

// `.Lazy` over a stream scanned `.Strict` judges the UTF-8 of the cells a field reads after the window has
// dropped the bytes before them, at any read size.
@(test)
test_record_read_stream_lazy_utf8_after_drop :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Text :: struct {
		a: string,
	}
	// A fault in the column no field reads, then a fault in a short line that starts just before a scan block's
	// end: the line is read only after the window dropped the rows before it.
	head := strings.concatenate({"a,b\n", strings.repeat("kk,qq\n", 30, context.temp_allocator), "j,\xFF\n"}, context.temp_allocator)
	bad := "\xFE,q\nlast,q\n"
	for lead in 58 ..= 63 {
		pad := (lead - len(head) - len("p,\n")) % 64
		pad += 64 if pad < 0 else 0
		src := strings.concatenate({head, "p,", strings.repeat("z", pad, context.temp_allocator), "\n", bad}, context.temp_allocator)
		bad_at := len(src) - len(bad)
		testing.expect_value(t, bad_at % 64, lead)
		for step in READ_STEPS {
			bytes := Bytes{src = transmute([]byte)src, step = step}
			rr := csv.records_from({procedure = bytes_read, data = &bytes}, allocator = context.temp_allocator)
			defer csv.destroy(&rr)
			rd: csv.Record_Read
			testing.expect_value(t, csv.record_read_init(&rd, Text, &rr, {strictness = .Lazy}, allocator = context.temp_allocator), nil)
			defer csv.destroy(&rd)
			got: Text
			for k in 0 ..< 32 {
				testing.expectf(t, pull(t, &rd, &got) == nil, "lead %d step %d row %d", lead, step, k)
			}
			err := um_err(pull(t, &rd, &got))
			testing.expectf(t, err.kind == .Syntax && err.syntax == .Bad_Char, "lead %d step %d: %v", lead, step, err)
			testing.expect_value(t, csv.record_read_at(&rd) + err.offset, u64(bad_at))
		}
	}
}

// A list row reads every record, the header too, one element per cell, as `unmarshal` does. A refused cell's
// path is `[row][cell]`, its offset into the row's bytes, and under `.Lazy` every cell is judged.
@(test)
test_record_read_list_rows :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	src := "a,b\n1,\n2,x\n"
	it := csv.records(transmute([]byte)src)
	defer csv.destroy(&it)
	rd: csv.Record_Read
	testing.expect_value(t, csv.record_read_init(&rd, []Maybe(string), &it, allocator = context.temp_allocator), nil)
	defer csv.destroy(&rd)
	row: []Maybe(string)
	testing.expect_value(t, pull(t, &rd, &row), nil)
	testing.expect_value(t, fmt.tprint(row), `["a", "b"]`)
	testing.expect_value(t, pull(t, &rd, &row), nil)
	testing.expect_value(t, fmt.tprint(row), `["1", nil]`)
	testing.expect_value(t, pull(t, &rd, &row), nil)
	testing.expect_value(t, fmt.tprint(row), `["2", "x"]`)
	testing.expect_value(t, past_end(t, &rd, &row), nil)

	ints_it := csv.records(transmute([]byte)string("1,2\n3,x\n"))
	defer csv.destroy(&ints_it)
	ints: csv.Record_Read
	testing.expect_value(t, csv.record_read_init(&ints, [dynamic]int, &ints_it, allocator = context.temp_allocator), nil)
	defer csv.destroy(&ints)
	nums: [dynamic]int
	testing.expect_value(t, pull(t, &ints, &nums), nil)
	testing.expect_value(t, fmt.tprint(nums), "[1, 2]")
	err := um_err(pull(t, &ints, &nums))
	testing.expect_value(t, err.kind, csv.Unmarshal_Error_Kind.Wrong_Kind)
	testing.expect_value(t, path_text(err), "[1][1]")
	testing.expect_value(t, err.offset, u64(len("3,")))

	lazy_it := csv.records(transmute([]byte)string("a,b\nc,\xff\n"), {strictness = .Lazy})
	defer csv.destroy(&lazy_it)
	lazy: csv.Record_Read
	testing.expect_value(t, csv.record_read_init(&lazy, []string, &lazy_it, {strictness = .Lazy}, allocator = context.temp_allocator), nil)
	defer csv.destroy(&lazy)
	texts: []string
	testing.expect_value(t, pull(t, &lazy, &texts), nil)
	err = um_err(pull(t, &lazy, &texts))
	testing.expect_value(t, err.kind, csv.Unmarshal_Error_Kind.Syntax)
	testing.expect_value(t, err.offset, u64(len("c,")))

	nested: csv.Record_Read
	testing.expect_value(t, um_err(csv.record_read_init(&nested, [][]int, &it, allocator = context.allocator)).kind, csv.Unmarshal_Error_Kind.Unsupported)
}

// A map row's keys are the header's decoded names, which the reader keeps for every row, also after a stream's
// window has dropped the header; each row is the row `unmarshal` reads. The reader frees the keys, and there is
// no map row without a header.
@(test)
test_record_read_map_rows :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	body := strings.concatenate({"\"x\"\"y\",a,a\n", strings.repeat("1,,2\n,\"\",3\n", 20, context.temp_allocator), "4,z,q\n"}, context.temp_allocator)
	whole := transmute([]byte)body
	Text :: map[string]string
	want: []Text
	testing.expect_value(t, csv.unmarshal(whole, &want, {read = {duplicates = .First}}, nil, context.temp_allocator), nil)
	for step in READ_STEPS {
		bytes := Bytes{src = whole, step = step}
		rr := csv.records_from({procedure = bytes_read, data = &bytes}, allocator = context.temp_allocator)
		defer csv.destroy(&rr)
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		defer mem.tracking_allocator_destroy(&track)
		{
			context.allocator = mem.tracking_allocator(&track)
			rd: csv.Record_Read
			testing.expect_value(t, csv.record_read_init(&rd, Text, &rr, {read = {duplicates = .First}}, allocator = context.temp_allocator), nil)
			for w, k in want {
				got: Text
				err := pull(t, &rd, &got)
				same := err == nil && len(got) == len(w)
				for key, v in w {
					same &&= got[key] == v
				}
				testing.expectf(t, same, "step %d row %d: %v, want %v, %v", step, k, got, w, err)
			}
			testing.expect_value(t, past_end(t, &rd, &Text{}), nil)
			csv.destroy(&rd)
		}
		testing.expect_value(t, len(track.bad_free_array), 0)
		testing.expect_value(t, len(track.allocation_map), 0)
	}

	it := csv.records(transmute([]byte)string("a,b\n1,\n2,x\n"))
	defer csv.destroy(&it)
	rd: csv.Record_Read
	testing.expect_value(t, csv.record_read_init(&rd, map[string]int, &it, allocator = context.temp_allocator), nil)
	defer csv.destroy(&rd)
	ints: map[string]int
	testing.expect_value(t, pull(t, &rd, &ints), nil)
	testing.expect_value(t, fmt.tprint(ints), "map[a=1]")
	err := um_err(pull(t, &rd, &ints))
	testing.expect_value(t, err.kind, csv.Unmarshal_Error_Kind.Wrong_Kind)
	testing.expect_value(t, path_text(err), "[1].b")

	plain := csv.records(transmute([]byte)string("a\n1\n"), {no_header = true})
	defer csv.destroy(&plain)
	none: csv.Record_Read
	testing.expect_value(t, um_err(csv.record_read_init(&none, Text, &plain, {read = {no_header = true}}, allocator = context.allocator)).kind, csv.Unmarshal_Error_Kind.Unsupported)
}
