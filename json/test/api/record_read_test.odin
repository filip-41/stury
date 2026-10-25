package json_tests

// `Record_Read`: each record matches `unmarshal` of that record's bytes. A fault's offset is into the
// record, blank lines are not records, and a trailing record with no newline counts.

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

@(private = "file")
expect_records_match :: proc(t: ^testing.T, src: string, opts: json.Unmarshal_Opts, n: int, loc := #caller_location) {
	rd: json.Record_Read
	testing.expect_value(t, json.record_read_init(&rd, Read_Rec, opts, allocator = context.temp_allocator), nil, loc = loc)
	defer json.destroy(&rd)
	it := json.records(raw(src), .NDJSON)
	got_n := 0
	for rec in json.next_record(&it) {
		got, want: Read_Rec
		got_err := json.unmarshal(&rd, rec.bytes, &got)
		want_err := json.unmarshal(rec.bytes, &want, opts, allocator = context.temp_allocator)
		testing.expectf(t, fmt.tprint(got_err) == fmt.tprint(want_err), "%q: %v, unmarshal %v", rec.bytes, got_err, want_err, loc = loc)
		testing.expectf(t, fmt.tprint(got) == fmt.tprint(want), "%q: %v, unmarshal %v", rec.bytes, got, want, loc = loc)
		if e, bad := got_err.?; bad {
			testing.expectf(t, e.offset <= u64(len(rec.bytes)), "%q: offset %d", rec.bytes, e.offset, loc = loc)
		}
		got_n += 1
	}
	testing.expect_value(t, it.err, nil, loc = loc)
	testing.expect_value(t, got_n, n, loc = loc)
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
	expect_records_match(t, "", {}, 0)
	expect_records_match(t, "\n\n \r\n", {}, 0)

	// A plan the caller keeps is borrowed, and still reads after the reader is destroyed.
	plan := json.type_plan_init(Read_Rec, {}, context.temp_allocator)
	kept: json.Record_Read
	testing.expect_value(t, json.record_read_init(&kept, Read_Rec, {}, &plan, context.temp_allocator), nil)
	text := raw(`{"id":8,"name":"kept","v":1,"flag":true}`)
	got, want: Read_Rec
	testing.expect_value(t, json.unmarshal(&kept, text, &got), nil)
	json.destroy(&kept)
	testing.expect_value(t, json.unmarshal(text, &want, {}, &plan, context.temp_allocator), nil)
	testing.expect_value(t, got, want)
	other := json.type_plan_init(i64, {}, context.temp_allocator)
	testing.expect_value(t, um_err(json.record_read_init(&kept, Read_Rec, {}, &other)).kind, .Plan_Mismatch)
}

@(test)
test_unmarshal_record_fault_is_into_the_record :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	// The bad record does not start at byte 0, and it has no newline after it.
	src := "{\"id\":1,\"name\":\"a\",\"v\":2,\"flag\":true}\n\n{\"id\":nope,\"name\":\"b\",\"v\":0,\"flag\":false}"
	rd: json.Record_Read
	testing.expect_value(t, json.record_read_init(&rd, Read_Rec, allocator = context.temp_allocator), nil)
	defer json.destroy(&rd)
	it := json.records(raw(src), .NDJSON)
	n := 0
	for rec in json.next_record(&it) {
		got, want: Read_Rec
		got_err := json.unmarshal(&rd, rec.bytes, &got)
		want_err := json.unmarshal(rec.bytes, &want, allocator = context.temp_allocator)
		testing.expectf(t, fmt.tprint(got_err) == fmt.tprint(want_err), "at %d %q: %v, unmarshal %v", rec.at, rec.bytes, got_err, want_err)
		if n == 1 {
			e := um_err(got_err)
			w := um_err(want_err)
			testing.expect(t, rec.at > 0)
			testing.expect_value(t, e.kind, w.kind)
			testing.expect_value(t, e.offset, w.offset)
			testing.expect(t, e.kind == .Syntax && e.syntax == .Bad_Literal)
		}
		n += 1
	}
	testing.expect_value(t, n, 2)
	testing.expect_value(t, it.err, nil)

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
	testing.expect_value(t, json.record_read_init(&ord, Outer, allocator = context.temp_allocator), nil)
	defer json.destroy(&ord)
	og, ow: Outer
	testing.expectf(t, fmt.tprint(json.unmarshal(&ord, text, &og)) == fmt.tprint(json.unmarshal(text, &ow, allocator = context.temp_allocator)), "nested")
	oe := um_err(json.unmarshal(&ord, text, &og))
	testing.expect_value(t, oe.kind, .Wrong_Kind)
	testing.expect(t, oe.n_steps > 0)
}

@(test)
test_unmarshal_record_walks_a_shape_it_does_not_descend :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	rd: json.Record_Read
	testing.expect_value(t, json.record_read_init(&rd, map[string]i64, allocator = context.temp_allocator), nil)
	defer json.destroy(&rd)
	src := "{\"a\":1,\"b\":2}\n\n{\"a\":3}"
	it := json.records(raw(src), .NDJSON)
	n := 0
	for rec in json.next_record(&it) {
		got, want: map[string]i64
		got_err := json.unmarshal(&rd, rec.bytes, &got)
		want_err := json.unmarshal(rec.bytes, &want, allocator = context.temp_allocator)
		testing.expectf(t, fmt.tprint(got_err) == fmt.tprint(want_err), "%q: %v, unmarshal %v", rec.bytes, got_err, want_err)
		testing.expect_value(t, len(got), len(want))
		for k, v in want {
			testing.expectf(t, got[k] == v, "%q: %s %d, unmarshal %d", rec.bytes, k, got[k], v)
		}
		n += 1
	}
	testing.expect_value(t, n, 2)
	testing.expect(t, json.unmarshal(&rd, nil, (^Read_Rec)(nil)) != nil)
}
