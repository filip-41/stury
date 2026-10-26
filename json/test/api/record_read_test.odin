package json_tests

// `Record_Read`: each record matches `unmarshal` of that record's bytes. A fault's offset is into the record,
// blank lines are not records, and a trailing record with no newline counts. The handle survives a return by
// value, the options it holds are applied at each read, and the end of the input is `.Bad_Option`.

import json "../.."
import "core:fmt"
import "core:testing"

@(private = "file")
Read_Rec :: struct {
	id:   i64,
	name: string,
	v:    i64,
	flag: bool,
}

// The records `src` frames, so a read can be compared with `unmarshal` of each record's bytes.
@(private = "file")
framed_records :: proc(src: string) -> [dynamic]json.Record {
	recs := make([dynamic]json.Record, context.temp_allocator)
	it := json.records(raw(src), .NDJSON)
	for rec in json.next_record(&it) {
		append(&recs, rec)
	}
	return recs
}

@(private = "file")
expect_records_match :: proc(t: ^testing.T, src: string, opts: json.Unmarshal_Opts, n: int, loc := #caller_location) {
	expected := framed_records(src)
	testing.expect_value(t, len(expected), n, loc = loc)
	it := json.records(raw(src), .NDJSON)
	rd: json.Record_Read
	testing.expect_value(t, json.record_read_init(&rd, Read_Rec, &it, opts, allocator = context.temp_allocator), nil, loc = loc)
	defer json.destroy(&rd)
	for rec in expected {
		got, want: Read_Rec
		got_err := json.unmarshal(&rd, &got)
		want_err := json.unmarshal(rec.bytes, &want, opts, allocator = context.temp_allocator)
		testing.expectf(t, fmt.tprint(got_err) == fmt.tprint(want_err), "%q: %v, unmarshal %v", rec.bytes, got_err, want_err, loc = loc)
		testing.expectf(t, fmt.tprint(got) == fmt.tprint(want), "%q: %v, unmarshal %v", rec.bytes, got, want, loc = loc)
		if e, bad := got_err.?; bad {
			testing.expectf(t, e.offset <= u64(len(rec.bytes)), "%q: offset %d", rec.bytes, e.offset, loc = loc)
		}
		testing.expect_value(t, json.record_read_at(&rd), rec.at, loc = loc)
	}
	// The output's end, not a fault: no record is left.
	got: Read_Rec
	testing.expect_value(t, um_err(json.unmarshal(&rd, &got)).kind, .Bad_Option, loc = loc)
}

@(test)
test_unmarshal_record_matches_unmarshal :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	// Blank lines, a leading space, and a last record with no newline.
	src := "\n{\"id\":1,\"name\":\"n00000001\",\"v\":2,\"flag\":true}\n\n \t\n {\"id\":2,\"name\":\"bee\",\"v\":3,\"flag\":false}\r\n{\"id\":4,\"id\":9,\"name\":\"cee\",\"v\":0,\"flag\":true}"
	expect_records_match(t, src, {}, 3)
	expect_records_match(t, src, {borrow_strings = true}, 3)
	expect_records_match(t, src, {duplicates = .First}, 3)
	expect_records_match(t, src, {strictness = .Lazy}, 3)
	expect_records_match(t, src, {dialect = .Jsonc}, 3)
	expect_records_match(t, "", {}, 0)
	expect_records_match(t, "\n\n \r\n", {}, 0)

	// A plan the caller keeps is borrowed, and still reads after the reader is destroyed.
	plan := json.type_plan_init(Read_Rec, {}, context.temp_allocator)
	quote := raw(`{"id":8,"name":"kept","v":1,"flag":true}`)
	it := json.records(quote, .NDJSON)
	kept: json.Record_Read
	testing.expect_value(t, json.record_read_init(&kept, Read_Rec, &it, {}, &plan, context.temp_allocator), nil)
	got: Read_Rec
	testing.expect_value(t, json.unmarshal(&kept, &got), nil)
	json.destroy(&kept)
	want: Read_Rec
	testing.expect_value(t, json.unmarshal(quote, &want, {}, &plan, context.temp_allocator), nil)
	testing.expect_value(t, got, want)
	other := json.type_plan_init(i64, {}, context.temp_allocator)
	testing.expect_value(t, um_err(json.record_read_init(&kept, Read_Rec, &it, {}, &other)).kind, .Plan_Mismatch)
}

@(test)
test_unmarshal_record_fault_is_into_the_record :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	// The bad record does not start at byte 0, and it has no newline after it.
	src := "{\"id\":1,\"name\":\"a\",\"v\":2,\"flag\":true}\n\n{\"id\":nope,\"name\":\"b\",\"v\":0,\"flag\":false}"
	rd: json.Record_Read
	it := json.records(raw(src), .NDJSON)
	testing.expect_value(t, json.record_read_init(&rd, Read_Rec, &it, allocator = context.temp_allocator), nil)
	defer json.destroy(&rd)
	expected := framed_records(src)
	testing.expect_value(t, len(expected), 2)
	for rec, k in expected {
		got, want: Read_Rec
		got_err := json.unmarshal(&rd, &got)
		want_err := json.unmarshal(rec.bytes, &want, allocator = context.temp_allocator)
		testing.expectf(t, fmt.tprint(got_err) == fmt.tprint(want_err), "at %d %q: %v, unmarshal %v", rec.at, rec.bytes, got_err, want_err)
		if k == 1 {
			e := um_err(got_err)
			w := um_err(want_err)
			testing.expect(t, rec.at > 0)
			testing.expect_value(t, json.record_read_at(&rd), rec.at)
			testing.expect_value(t, e.kind, w.kind)
			testing.expect_value(t, e.offset, w.offset)
			testing.expect(t, e.kind == .Syntax && e.syntax == .Bad_Literal)
			testing.expectf(t, rec.at + e.offset <= u64(len(src)), "at %d + %d", rec.at, e.offset)
		}
	}

	// A typed fault, with its path, on a value the descent gives up.
	Inner :: struct {
		n: i64,
	}
	Outer :: struct {
		id:    i64,
		inner: Inner,
	}
	text := raw(`{"id":1,"inner":{"n":true}}`)
	ord: json.Record_Read
	oit := json.records(text, .NDJSON)
	testing.expect_value(t, json.record_read_init(&ord, Outer, &oit, allocator = context.temp_allocator), nil)
	defer json.destroy(&ord)
	og, ow: Outer
	got_err := json.unmarshal(&ord, &og)
	want_err := json.unmarshal(text, &ow, allocator = context.temp_allocator)
	testing.expectf(t, fmt.tprint(got_err) == fmt.tprint(want_err), "nested")
	oe := um_err(got_err)
	testing.expect_value(t, oe.kind, .Wrong_Kind)
	testing.expect(t, oe.n_steps > 0)
	testing.expect(t, oe.offset <= u64(len(text)))
}

// A fault that frames no record has no record to be in: its offset is in the input, and `record_read_at` is 0
// instead of the last record's.
@(test)
test_unmarshal_record_framing_fault_is_into_the_input :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	good := "{\"id\":1,\"name\":\"a\",\"v\":2,\"flag\":true}\n"
	src := fmt.tprintf("%s%s\xEF\xBB\xBF%s", good, good, good)
	rd: json.Record_Read
	it := json.records(raw(src), .NDJSON)
	testing.expect_value(t, json.record_read_init(&rd, Read_Rec, &it, allocator = context.temp_allocator), nil)
	defer json.destroy(&rd)
	got: Read_Rec
	testing.expect_value(t, json.unmarshal(&rd, &got), nil)
	testing.expect_value(t, json.unmarshal(&rd, &got), nil)
	testing.expect_value(t, json.record_read_at(&rd), u64(len(good)))
	err := um_err(json.unmarshal(&rd, &got))
	testing.expect_value(t, err.kind, .Syntax)
	testing.expect_value(t, err.syntax, .Bad_Char)
	testing.expect_value(t, json.record_read_at(&rd), u64(0))
	testing.expect_value(t, err.offset, u64(2 * len(good)))
}

@(test)
test_unmarshal_record_walks_a_shape_it_does_not_descend :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	rd: json.Record_Read
	src := "{\"a\":1,\"b\":2}\n\n{\"a\":3}"
	it := json.records(raw(src), .NDJSON)
	testing.expect_value(t, json.record_read_init(&rd, map[string]i64, &it, allocator = context.temp_allocator), nil)
	defer json.destroy(&rd)
	got, want: map[string]i64
	testing.expect_value(t, json.unmarshal(&rd, &got), nil)
	testing.expect_value(t, json.unmarshal(raw(`{"a":1,"b":2}`), &want, allocator = context.temp_allocator), nil)
	testing.expect_value(t, len(got), len(want))
	for k, v in want {
		testing.expectf(t, got[k] == v, "%s %d, unmarshal %d", k, got[k], v)
	}
	got = nil
	testing.expect_value(t, json.unmarshal(&rd, &got), nil)
	testing.expect_value(t, len(got), 1)
	testing.expect_value(t, got["a"], i64(3))
	testing.expect(t, um_err(json.unmarshal(&rd, &got)).kind == .Bad_Option)
	// A nil target is refused before a record is pulled.
	testing.expect(t, json.unmarshal(&rd, (^Read_Rec)(nil)) != nil)
}

// A frame this large is written over by the callee: a returned handle that pointed into it would read the wrong
// bytes. The reader's state is on the heap, so the handle can be returned by value.
@(private = "file")
RETURNED_FRAME_BYTES :: 70 * 1024

@(private = "file")
clobber_bytes :: #force_no_inline proc(buf: ^[RETURNED_FRAME_BYTES]u8) {
	for i in 0 ..< len(buf) {
		buf[i] = u8(i * 31 + 7)
	}
}

@(private = "file")
clobber_returned_frame :: #force_no_inline proc() {
	buf: [RETURNED_FRAME_BYTES]u8 = ---
	clobber_bytes(&buf)
}

@(private = "file")
returned_record_reader :: proc(it: ^json.Records) -> (rd: json.Record_Read, ok: bool) {
	ok = json.record_read_init(&rd, Read_Rec, it, allocator = context.temp_allocator) == nil
	return
}

@(test)
test_record_read_handle_survives_return :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	it := json.records(raw(`{"id":5,"name":"returned","v":1,"flag":true}`), .NDJSON)
	rd, ok := returned_record_reader(&it)
	testing.expect(t, ok)
	defer json.destroy(&rd)
	clobber_returned_frame()
	got: Read_Rec
	testing.expect_value(t, json.unmarshal(&rd, &got), nil)
	testing.expect_value(t, got.id, i64(5))
	testing.expect_value(t, got.name, "returned")
	testing.expect_value(t, got.v, i64(1))
	testing.expect_value(t, got.flag, true)
}

// A handle copied after a read binds the shape of its own plan, not the original's, which may be gone.
@(test)
test_record_read_copy_after_a_read :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	line := `{"id":5,"name":"copied","v":1,"flag":true}`
	it := json.records(raw(fmt.tprintf("%s\n%s\n", line, line)), .NDJSON)
	rd: json.Record_Read
	testing.expect_value(t, json.record_read_init(&rd, Read_Rec, &it, allocator = context.temp_allocator), nil)
	got: Read_Rec
	testing.expect_value(t, json.unmarshal(&rd, &got), nil)
	copied := rd
	rd = {}
	defer json.destroy(&copied)
	got = {}
	testing.expect_value(t, json.unmarshal(&copied, &got), nil)
	testing.expect_value(t, got.id, i64(5))
	testing.expect_value(t, got.name, "copied")
}

@(private = "file")
string_is_in :: proc(s: string, src: []byte) -> bool {
	lo := uintptr(raw_data(src))
	p := uintptr(raw_data(s))
	return p >= lo && p + uintptr(len(s)) <= lo + uintptr(len(src))
}

@(test)
test_record_read_opts_after_init_apply :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	line := `{"id":1,"name":"a","v":2,"flag":true,"id":9}`
	dup := fmt.tprintf("%s\n%s\n%s\n", line, line, line)
	it := json.records(raw(dup), .NDJSON)
	rd: json.Record_Read
	testing.expect_value(t, json.record_read_init(&rd, Read_Rec, &it, allocator = context.temp_allocator), nil)
	defer json.destroy(&rd)

	// `.Last` from init; `.First` on the handle after it keeps the first occurrence.
	got: Read_Rec
	testing.expect_value(t, json.unmarshal(&rd, &got), nil)
	testing.expect_value(t, got.id, i64(9))
	rd.opts.duplicates = .First
	testing.expect_value(t, json.unmarshal(&rd, &got), nil)
	testing.expect_value(t, got.id, i64(1))

	// `.Refuse` is live too.
	rd.opts.duplicates = .Refuse
	testing.expect_value(t, um_err(json.unmarshal(&rd, &got)).kind, .Duplicate_Key)

	// `limits` is re-bound at each read: a digit cap that refuses the second read does not refuse the first.
	dline := "{\"id\":10,\"name\":\"n\",\"v\":2,\"flag\":true}\n"
	digits := raw(fmt.tprintf("%s%s%s", dline, dline, dline))
	dit := json.records(digits, .NDJSON)
	dr: json.Record_Read
	testing.expect_value(t, json.record_read_init(&dr, Read_Rec, &dit, allocator = context.temp_allocator), nil)
	defer json.destroy(&dr)
	testing.expect_value(t, json.unmarshal(&dr, &got), nil)
	dr.opts.limits.max_scalar_digits = 1
	limit_err := um_err(json.unmarshal(&dr, &got))
	testing.expect_value(t, limit_err.kind, .Syntax)
	testing.expect_value(t, limit_err.syntax, .Limit_Digits)
	dr.opts.limits.max_scalar_digits = 0
	testing.expect_value(t, json.unmarshal(&dr, &got), nil)

	// `borrow_strings` is live: the copied string does not point into the source, the borrowed one does.
	buf: [128]u8
	src := `{"id":1,"name":"borrow","v":2,"flag":true}`
	n := len(src)
	copy(buf[:n], src)
	buf[n] = '\n'
	copy(buf[n + 1:], src)
	text := buf[:2 * n + 1]
	bit := json.records(text, .NDJSON)
	br: json.Record_Read
	testing.expect_value(t, json.record_read_init(&br, Read_Rec, &bit, allocator = context.temp_allocator), nil)
	defer json.destroy(&br)
	testing.expect_value(t, json.unmarshal(&br, &got), nil)
	testing.expect(t, !string_is_in(got.name, text))
	br.opts.borrow_strings = true
	testing.expect_value(t, json.unmarshal(&br, &got), nil)
	testing.expect(t, string_is_in(got.name, text))
}

@(test)
test_record_read_destroy_twice :: proc(t: ^testing.T) {
	it := json.records(raw(`{"id":1,"name":"a","v":2,"flag":true}`), .NDJSON)
	rd: json.Record_Read
	testing.expect_value(t, json.record_read_init(&rd, Read_Rec, &it), nil)
	json.destroy(&rd)
	json.destroy(&rd)
	got: Read_Rec
	testing.expect_value(t, um_err(json.unmarshal(&rd, &got)).kind, .Bad_Option)

	// A handle that was never initialized is empty, and destroying it is not a read of its state.
	empty: json.Record_Read
	json.destroy(&empty)
	testing.expect_value(t, um_err(json.unmarshal(&empty, &got)).kind, .Bad_Option)
}

@(test)
test_record_read_refuses_structural_json :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Lit :: struct {
		a: i64,
	}
	line := "{\"a\":1}\n"
	src := raw(fmt.tprintf("%s%s", line, line))
	it := json.records(src, .NDJSON)
	rd: json.Record_Read
	testing.expect_value(t, um_err(json.record_read_init(&rd, Lit, &it, {strictness = .Structural})).kind, .Bad_Option)
	// `.Jsonc` reads it.
	testing.expect_value(t, json.record_read_init(&rd, Lit, &it, {strictness = .Structural, dialect = .Jsonc}, allocator = context.temp_allocator), nil)
	defer json.destroy(&rd)
	got: Lit
	testing.expect_value(t, json.unmarshal(&rd, &got), nil)
	// The refusal is live too: `.Structural` over plain JSON changed after init refuses the next record.
	rd.opts.strictness = .Strict
	testing.expect_value(t, json.unmarshal(&rd, &got), nil)
	rd.opts.strictness = .Structural
	testing.expect_value(t, um_err(json.unmarshal(&rd, &got)).kind, .Bad_Option)
}
