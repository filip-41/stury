package csv_tests

// `Record_Read`: one row per `unmarshal`, matching `unmarshal` of the same table, from an in-memory `Records`
// or a streaming `Record_Reader`. The header is read once, a fault's offset is into the row's bytes, the options
// the reader holds apply at each row, and a reader is destroyed once.

import "core:io"
import "core:testing"
import csv "../"

@(private = "file")
um_err :: proc(err: Maybe(csv.Unmarshal_Error)) -> csv.Unmarshal_Error {
	e, _ := err.?
	return e
}

@(private = "file")
Rec :: struct {
	id:   i64,
	name: string `csv:"full name"`,
	v:    f64,
	ok:   bool,
}

// A reader over `src`'s bytes, a chunk a call.
@(private = "file")
Bytes :: struct {
	src: []byte,
	pos: int,
}

@(private = "file")
bytes_read :: proc(data: rawptr, mode: io.Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From) -> (i64, io.Error) {
	b := (^Bytes)(data)
	#partial switch mode {
	case .Read:
		if b.pos == len(b.src) {
			return 0, .EOF
		}
		n := copy(p, b.src[b.pos:])
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
	defer csv.record_read_destroy(&rd)
	first := 1 + len("full name,id,ok,v")
	got: Rec
	testing.expect_value(t, csv.unmarshal(&rd, &got), nil)
	testing.expect_value(t, got.id, i64(1))
	testing.expect_value(t, got.name, "a, b")
	testing.expect_value(t, got.v, 2.5)
	testing.expect_value(t, got.ok, true)
	testing.expect_value(t, csv.record_read_at(&rd), u64(first))
	testing.expect_value(t, csv.unmarshal(&rd, &got), nil)
	testing.expect_value(t, got.id, i64(2))
	testing.expect_value(t, got.name, "c")
	testing.expect_value(t, got.v, 3.0)
	testing.expect_value(t, got.ok, false)
	testing.expect(t, csv.record_read_at(&rd) > u64(first))
	// No row is left.
	e, refused := csv.unmarshal(&rd, &got).?
	testing.expect(t, refused && e.kind == .Bad_Option)
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
	defer csv.record_read_destroy(&rd)
	got: Rec
	testing.expect_value(t, csv.unmarshal(&rd, &got), nil)
	testing.expect_value(t, got.id, i64(7))
	testing.expect_value(t, got.name, "a")
	testing.expect_value(t, got.v, 1.5)
	testing.expect_value(t, got.ok, true)
	testing.expect_value(t, csv.record_read_at(&rd), u64(0))
}

@(test)
test_record_read_missing_and_extra_cells :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	// Ragged: a row's cells past the header's are unknown, and the cells it lacks are absent.
	src := "id,full name,v,ok\n1,a,1.5,true,extra\n2\n"
	it := csv.records(transmute([]byte)src, {dialect = {ragged = true}})
	defer csv.destroy(&it)
	rd: csv.Record_Read
	opt := csv.Unmarshal_Opts {
		read = {dialect = {ragged = true}},
	}
	testing.expect_value(t, csv.record_read_init(&rd, Rec, &it, opt, allocator = context.temp_allocator), nil)
	defer csv.record_read_destroy(&rd)
	got: Rec
	testing.expect_value(t, csv.unmarshal(&rd, &got), nil)
	testing.expect_value(t, got.id, i64(1))
	testing.expect_value(t, got.name, "a")
	testing.expect_value(t, got.v, 1.5)
	// The missing row: only `id`. A cell the row lacks leaves the field as the destination held it, as
	// `unmarshal` leaves a member the text lacks.
	got = {}
	testing.expect_value(t, csv.unmarshal(&rd, &got), nil)
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
	defer csv.record_read_destroy(&rr)
	err := um_err(csv.unmarshal(&rr, &got))
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
	testing.expect_value(t, um_err(csv.record_read_init(&rd, Rec, &it, {duplicates = .Refuse})).kind, .Duplicate_Key)
	// `.Refuse` is the default too, from a fresh iterator.
	it_default := csv.records(transmute([]byte)src)
	defer csv.destroy(&it_default)
	testing.expect_value(t, um_err(csv.record_read_init(&rd, Rec, &it_default)).kind, .Duplicate_Key)
	// `.First` keeps the first column.
	it2 := csv.records(transmute([]byte)src)
	defer csv.destroy(&it2)
	testing.expect_value(t, csv.record_read_init(&rd, Rec, &it2, {duplicates = .First}, allocator = context.temp_allocator), nil)
	defer csv.record_read_destroy(&rd)
	got: Rec
	testing.expect_value(t, csv.unmarshal(&rd, &got), nil)
	testing.expect_value(t, got.id, i64(1))
	// `.Last` keeps the last.
	it3 := csv.records(transmute([]byte)src)
	defer csv.destroy(&it3)
	testing.expect_value(t, csv.record_read_init(&rd, Rec, &it3, {duplicates = .Last}, allocator = context.temp_allocator), nil)
	testing.expect_value(t, csv.unmarshal(&rd, &got), nil)
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
	defer csv.record_read_destroy(&rd)
	got: Rec
	testing.expect_value(t, csv.unmarshal(&rd, &got), nil)
	testing.expect_value(t, got.id, i64(1))
	rd.opts.unknown_fields = .Refuse
	err := um_err(csv.unmarshal(&rd, &got))
	testing.expect_value(t, err.kind, .Unknown_Field)
	testing.expect_value(t, src[int(csv.record_read_at(&rd) + err.offset):], "extra\n3,c,3.5,true,extra\n")
	// Back to `.Ignore`, the next row reads.
	rd.opts.unknown_fields = .Ignore
	testing.expect_value(t, csv.unmarshal(&rd, &got), nil)
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
	defer csv.record_read_destroy(&br)
	testing.expect_value(t, csv.unmarshal(&br, &got), nil)
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
	defer csv.record_read_destroy(&rd)
	got: Rec
	testing.expect_value(t, csv.unmarshal(&rd, &got), nil)
	err := um_err(csv.unmarshal(&rd, &got))
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
	defer csv.record_read_destroy(&rd)
	got: Rec
	testing.expect_value(t, csv.unmarshal(&rd, &got), nil)
	testing.expect_value(t, got.id, i64(1))
	testing.expect_value(t, got.name, "a, b")
	testing.expect_value(t, got.v, 2.5)
	testing.expect_value(t, got.ok, true)
	testing.expect_value(t, csv.record_read_at(&rd), u64(len("full name,id,ok,v\n")))
	testing.expect_value(t, csv.unmarshal(&rd, &got), nil)
	testing.expect_value(t, got.id, i64(2))
	testing.expect_value(t, got.name, "c")
	e, refused := csv.unmarshal(&rd, &got).?
	testing.expect(t, refused && e.kind == .Bad_Option)
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
	defer csv.record_read_destroy(&rd)
	got: Rec
	testing.expect_value(t, csv.unmarshal(&rd, &got), nil)
	err := um_err(csv.unmarshal(&rd, &got))
	at := csv.record_read_at(&rd)
	testing.expect_value(t, err.kind, .Wrong_Kind)
	testing.expect_value(t, at + err.offset, u64(len("id,full name,v,ok\n1,a,1.5,true\n2,b,")))
}

@(test)
test_record_read_destroy_twice :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	it := csv.records(transmute([]byte)string("id\n1\n"))
	defer csv.destroy(&it)
	rd: csv.Record_Read
	testing.expect_value(t, csv.record_read_init(&rd, Rec, &it), nil)
	csv.record_read_destroy(&rd)
	csv.record_read_destroy(&rd)
	got: Rec
	testing.expect_value(t, um_err(csv.unmarshal(&rd, &got)).kind, .Bad_Option)
	// A handle that was never initialized is empty.
	empty: csv.Record_Read
	csv.record_read_destroy(&empty)
	testing.expect_value(t, um_err(csv.unmarshal(&empty, &got)).kind, .Bad_Option)
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
	testing.expect_value(t, csv.unmarshal(&rd, &got), nil)
	testing.expect_value(t, got.id, i64(3))
	csv.record_read_destroy(&rd)
	// The plan outlives the reader: another reader borrows it and reads.
	it2 := csv.records(transmute([]byte)string("id,full name,v,ok\n4,y,5.5,false\n"))
	defer csv.destroy(&it2)
	rd2: csv.Record_Read
	testing.expect_value(t, csv.record_read_init(&rd2, Rec, &it2, {}, &plan, context.temp_allocator), nil)
	defer csv.record_read_destroy(&rd2)
	testing.expect_value(t, csv.unmarshal(&rd2, &got), nil)
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
		defer csv.record_read_destroy(&rd)
		got: Text
		testing.expectf(t, csv.unmarshal(&rd, &got) == nil, "%v: %v", created, got)
		testing.expect_value(t, got.a, "x")
		testing.expectf(t, csv.unmarshal(&rd, &got) == nil, "%v", created)
		testing.expect_value(t, got.a, "y")
		err := um_err(csv.unmarshal(&rd, &got))
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
