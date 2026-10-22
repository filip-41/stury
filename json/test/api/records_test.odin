package json_tests

import host "../../../host"
import "base:runtime"
import json "../.."
import "core:slice"
import "core:strings"
import "core:sync"
import "core:testing"

@(test)
test_ndjson_yields_one_value_per_line :: proc(t: ^testing.T) {
	src := transmute([]byte)string("1\n\n {\"a\":2}\r\ntrue\n")
	expect_records(t, src, .NDJSON, {"1", " {\"a\":2}", "true"})
}

@(test)
test_json_seq_follows_rfc7464 :: proc(t: ^testing.T) {
	// A record runs to the next separator, line feeds and all. Whitespace before the first is stepped over.
	src := transmute([]byte)string(" \n\x1e1\n\x1e\x1e{\n \"a\": 2\n}\n")
	it := expect_records(t, src, .JSON_Seq, {"1\n", "{\n \"a\": 2\n}\n"})
	testing.expect(t, it.err == nil)
	it = expect_records(t, transmute([]byte)string("\n x\x1e1\n"), .JSON_Seq, {})
	testing.expect_value(t, it.err, json.Error{kind = .Bad_Char, offset = 2})

	// A record cut by the next record separator or by the input's end is yielded for validation to refuse.
	cut := transmute([]byte)string("\x1egarbage!!\x1e[2]\n\x1e1\n\x1e2\nx\x1e{\"a\":")
	it = expect_records(t, cut, .JSON_Seq, {"garbage!!", "[2]\n", "1\n", "2\nx", "{\"a\":"})
	testing.expect(t, it.err == nil)
	it = json.records(cut, .JSON_Seq)
	verdicts := []json.Error_Kind{.Bad_Char, .None, .None, .Trailing, .Truncated}
	for n := 0;; n += 1 {
		rec := json.next_record(&it) or_break
		verdict, _ := json.validate(rec.bytes).?
		testing.expect_value(t, verdict.kind, verdicts[n])
	}

	// RFC 7464 §2.4: a number nothing but a separator or the input's end follows may be cut short.
	Cut_Case :: struct {
		src:  string,
		recs: []string,
		at:   u64,
	}
	for c in ([]Cut_Case{{"\x1e1\x1e2\n", {}, 2}, {"\x1e[1]\n\x1e -1.5e3", {"[1]\n"}, 13}, {"\x1e1-\x1e", {}, 3}}) {
		it = expect_records(t, transmute([]byte)c.src, .JSON_Seq, c.recs)
		testing.expectf(t, it.err == json.Error{kind = .Truncated, offset = c.at}, "%q: %v", c.src, it.err)
	}
	expect_records(t, transmute([]byte)string("\x1e1 \x1e2\n\x1etrue\x1e\"a\""), .JSON_Seq, {"1 ", "2\n", "true", "\"a\""})
}

// Separators with nothing or only whitespace after them, before the next or the input's end, open no record,
// as the CLI's --seq filter and jq read them, a BOM at the input's first byte is stepped over.
@(test)
test_json_seq_blank_records_are_none :: proc(t: ^testing.T) {
	Blank_Case :: struct {
		src:  string,
		recs: []string,
	}
	for c in ([]Blank_Case{
		{"\x1e", {}},
		{"\x1e\x1e", {}},
		{"\x1e\n", {}},
		{"\x1e \r\n\t", {}},
		{"", {}},
		{"\xef\xbb\xbf", {}},
		{"\xef\xbb\xbf \x1e", {}},
		{"\x1e1\n\x1e", {"1\n"}},
		{"\x1e[1]\x1e  \n", {"[1]"}},
		{"\x1e[1]\n\x1e \n\x1e\x1e\n[2]\n", {"[1]\n", "[2]\n"}},
		{"\xef\xbb\xbf\x1e1\n", {"1\n"}},
		{"\xef\xbb\xbf \n\x1e[1]\n", {"[1]\n"}},
		{"\xef\xbb\xbf\x1e[1]\n\x1e\n", {"[1]\n"}},
	}) {
		testing.expectf(t, expect_records(t, raw(c.src), .JSON_Seq, c.recs).err == nil, "%q", c.src)
		faults, err := json.validate_records(raw(c.src), .JSON_Seq)
		testing.expectf(t, err == nil && faults == nil, "%q: %v %v", c.src, faults, err)
	}
	testing.expect_value(t, expect_records(t, raw("\xef\xbb\xbf1\n"), .JSON_Seq, {}).err, json.Error{kind = .Bad_Char, offset = 3})
}

// A line of JSON whitespace only, CRs among it, is blank, as the CLI's --ndjson filter reads it.
@(test)
test_ndjson_whitespace_lines_are_blank :: proc(t: ^testing.T) {
	src := raw("1\n\r\r\n \r\t\n\r\n2\n")
	expect_records(t, src, .NDJSON, {"1", "2"})
	faults, err := json.validate_records(src, .NDJSON)
	testing.expectf(t, err == nil && faults == nil, "%v %v", faults, err)
}

@(test)
test_root_entries_yield_elements_and_members :: proc(t: ^testing.T) {
	arr := transmute([]byte)string("\xef\xbb\xbf [1, \"a,]\" , [2, {\"b\": 3}] ,null]  \n")
	it := expect_records(t, arr, .Root_Entries, {"1", "\"a,]\"", "[2, {\"b\": 3}]", "null"})
	testing.expect(t, it.err == nil)

	obj := transmute([]byte)string(`{"a": 1, "b\"c" :[2] , "a":{}}`)
	it = json.records(obj, .Root_Entries)
	keys := []string{`"a"`, `"b\"c"`, `"a"`}
	values := []string{"1", "[2]", "{}"}
	n := 0
	for rec in json.next_record(&it) {
		testing.expect_value(t, string(rec.key), keys[n])
		testing.expect_value(t, string(rec.bytes), values[n])
		testing.expect_value(t, string(obj[rec.at:][:len(rec.bytes)]), values[n])
		n += 1
	}
	testing.expect(t, n == 3 && it.err == nil)

	for empty in ([]string{"[]", " [ \n ] ", "{}"}) {
		testing.expectf(t, expect_records(t, transmute([]byte)empty, .Root_Entries, {}).err == nil, "%q", empty)
	}
	// An entry missing between commas is yielded empty, for validation to refuse.
	expect_records(t, transmute([]byte)string("[1,,2,]"), .Root_Entries, {"1", "", "2", ""})
	expect_records(t, transmute([]byte)string("[,]"), .Root_Entries, {"", ""})
	// A scalar root yields nothing and is validated whole.
	testing.expect(t, expect_records(t, transmute([]byte)string(" 12 "), .Root_Entries, {}).err == nil)
	it = expect_records(t, transmute([]byte)string("[1, 2"), .Root_Entries, {})
	e, bad := it.err.(json.Error)
	testing.expect(t, bad && e.kind == .Truncated && e.offset == 5)
	// Keys and colons are the framing's, refused as `validate` refuses the whole.
	for src in ([]string{`{"a" 1}`, `{1: 2}`, `{"a": 1, "b"}`, `{"a\x": 1}`, `{"a`}) {
		it = expect_records(t, transmute([]byte)src, .Root_Entries, {"1"} if src == `{"a": 1, "b"}` else {})
		want, _ := json.validate(transmute([]byte)src).?
		e, bad = it.err.(json.Error)
		testing.expectf(t, bad && e == want, "%q: %v, validate %v", src, it.err, want)
	}
	// A BOM past the input's first byte starts no record, under every framing, and `validate_records` agrees.
	Bom_Case :: struct {
		src:     string,
		framing: json.Framing,
		at:      u64,
	}
	for c in ([]Bom_Case{{"1\n\xef\xbb\xbf2\n", .NDJSON, 2}, {"\x1e1 \x1e\xef\xbb\xbf2\n", .JSON_Seq, 4}, {"[1, \xef\xbb\xbf2]", .Root_Entries, 4}}) {
		want := json.Error{kind = .Bad_Char, offset = c.at}
		it = expect_records(t, transmute([]byte)c.src, c.framing, {"1 " if c.framing == .JSON_Seq else "1"})
		testing.expectf(t, it.err == want, "%q: %v", c.src, it.err)
		faults, ferr := json.validate_records(transmute([]byte)c.src, c.framing)
		testing.expectf(t, ferr == want && faults == nil, "%q: %v %v", c.src, ferr, faults)
	}
	testing.expect_value(t, json.validate(transmute([]byte)string("[1, \xef\xbb\xbf2]")), json.Error{kind = .Bad_Char, offset = 4})
}

// A whole text is valid exactly when its root's framing holds and every entry is valid one level down.
@(test)
test_validate_records_agrees_with_validate_on_a_root :: proc(t: ^testing.T) {
	for src in ([]string{`[1, [2], {"a": "b"}]`, `[1 2]`, `[1, tru]`, `{"a": 1, "b": [}`, "[1, \xef\xbb\xbf2]", `["a\"]`, `[1] [2]`, `[1],[2]`, `{"k": {"x": 1}, "k": 2}`}) {
		faults, err := json.validate_records(transmute([]byte)src, .Root_Entries)
		defer delete(faults)
		whole := json.validate(transmute([]byte)src)
		testing.expectf(t, (whole == nil) == (err == nil && len(faults) == 0), "%q: validate %v, records %v %v", src, whole, err, faults)
	}
}

// `each_record` hands out pieces whose records, in the order of `k`, are the serial iterator's, and
// `validate_records` returns exactly the records `validate` refuses, at every width.
@(test)
test_each_record_matches_the_serial_iterator :: proc(t: ^testing.T) {
	pool: host.Batch_Pool
	host.batch_pool_init(&pool, 4)
	defer host.batch_pool_destroy(&pool)
	for framing in json.Framing {
		src := many_records(framing)
		defer delete(src)
		want: [dynamic]json.Record
		defer delete(want)
		it := json.records(src, framing)
		for rec in json.next_record(&it) {
			append(&want, rec)
		}
		testing.expect(t, it.err == nil)
		for runner in ([]^json.Batch_Runner{nil, &pool.runner}) {
			got: Collected
			defer delete(got.pieces)
			err := json.each_record(src, framing, collect_piece, &got, runner)
			testing.expectf(t, err == nil, "%v: %v", framing, err)
			slice.sort_by(got.pieces[:], proc(a, b: Collected_Piece) -> bool {return a.k < b.k})
			n := 0
			for p, i in got.pieces {
				testing.expectf(t, p.k == i, "%v: piece %d numbered %d", framing, i, p.k)
				for rec in p.records {
					if n < len(want) {
						w := want[n]
						testing.expectf(t, rec.at == w.at && string(rec.bytes) == string(w.bytes) && string(rec.key) == string(w.key), "%v: record %d %v, serial %v", framing, n, rec, w)
					}
					n += 1
				}
				delete(p.records)
			}
			testing.expectf(t, n == len(want), "%v: %d records, serial %d", framing, n, len(want))

			faults, ferr := json.validate_records(src, framing, runner)
			defer delete(faults)
			testing.expect(t, ferr == nil)
			k := 0
			for w in want {
				limits := json.Limits{max_depth = json.MAX_DEPTH - 1} if framing == .Root_Entries else {}
				e, bad := json.validate(w.bytes, limits = limits).?
				if !bad {
					continue
				}
				e.offset += w.at
				if k < len(faults) {
					f := faults[k]
					testing.expectf(t, f.lo == w.at && f.hi == w.at + u64(len(w.bytes)) && f.err == e, "%v: fault %d %v, validate %v", framing, k, f, e)
				}
				k += 1
			}
			testing.expectf(t, k == len(faults) && k > 0, "%v: %d faults, validate refuses %d", framing, len(faults), k)
		}
	}
}

// A task that returns false ends the batch, and a framing fault is the first in the input.
@(test)
test_each_record_stops_and_reports_the_first_fault :: proc(t: ^testing.T) {
	pool: host.Batch_Pool
	host.batch_pool_init(&pool, 4)
	defer host.batch_pool_destroy(&pool)
	src := many_records(.JSON_Seq)
	defer delete(src)
	// A number a separator cuts, past the middle: the faults before it stand with it, as one thread finds them.
	at := len(src) / 2
	for src[at - 1] != '\n' || src[at] != 0x1E {
		at += 1
	}
	cut := slice.concatenate([][]byte{src[:at], transmute([]byte)string("\x1e7"), src[at:]})
	defer delete(cut)
	faults, err := json.validate_records(cut, .JSON_Seq, &pool.runner)
	defer delete(faults)
	serial, serr := json.validate_records(cut, .JSON_Seq)
	defer delete(serial)
	testing.expectf(t, err == json.Error{kind = .Truncated, offset = u64(at + 2)}, "%v, want %d", err, at + 2)
	testing.expect(t, serr == err && len(faults) > 0 && slice.equal(faults, serial) && slice.last(faults).lo < u64(at))

	calls: int
	stopped := json.each_record(src, .NDJSON, proc(data: rawptr, _: ^json.Records, _: int) -> bool {
		sync.atomic_add((^int)(data), 1)
		return false
	}, &calls, &pool.runner)
	testing.expect(t, stopped == nil && calls >= 1 && calls <= 4)
}

@(test)
test_render_error_counts_lines_of_a_records_input :: proc(t: ^testing.T) {
	src := transmute([]byte)string("\x1e1\n\x1e2\n\x1e3")
	it := json.records(src, .JSON_Seq)
	for _ in json.next_record(&it) {
	}
	e, bad := it.err.(json.Error)
	testing.expect(t, bad)
	testing.expect_value(t, json.render_error(src, e, context.temp_allocator), "3:3: Truncated")
}

@(private = "file")
Collected_Piece :: struct {
	k:       int,
	records: [dynamic]json.Record,
}

@(private = "file")
Collected :: struct {
	lock:   sync.Mutex,
	pieces: [dynamic]Collected_Piece,
}

@(private = "file")
collect_piece :: proc(data: rawptr, piece: ^json.Records, k: int) -> bool {
	c := (^Collected)(data)
	p := Collected_Piece{k = k}
	for rec in json.next_record(piece) {
		append(&p.records, rec)
	}
	sync.lock(&c.lock)
	append(&c.pieces, p)
	sync.unlock(&c.lock)
	return true
}

// The records of `src` are `want`, each at its offset (the iterator is run to read its `err`).
@(private = "file")
expect_records :: proc(t: ^testing.T, src: []byte, framing: json.Framing, want: []string, loc := #caller_location) -> json.Records {
	it := json.records(src, framing)
	n := 0
	for rec in json.next_record(&it) {
		if n < len(want) {
			testing.expect_value(t, string(rec.bytes), want[n], loc = loc)
			testing.expect_value(t, string(src[rec.at:][:len(rec.bytes)]), want[n], loc = loc)
		}
		n += 1
	}
	testing.expectf(t, n == len(want), "%q: %d records, want %d", string(src), n, len(want), loc = loc)
	return it
}

// About half a megabyte of records: valid, invalid, blank, a record longer than a claim, a record that nests
// to the depth cap, runs of `0x1E` and backslashes that straddle claims. Under
// `.Root_Entries` the records are one array's entries.
@(private)
many_records :: proc(framing: json.Framing) -> []byte {
	out: [dynamic]byte
	add :: proc(out: ^[dynamic]byte, framing: json.Framing, rec: string) {
		switch framing {
		case .JSON_Seq:
			append(out, "\x1e\x1e\x1e")
		case .Root_Entries:
			append(out, len(out) == 0 ? "[" : ",\n ")
		case .NDJSON:
		}
		append(out, rec)
		if framing != .Root_Entries {
			append(out, "\n")
		}
	}
	for i := 0; len(out) < 512 * 1024; i += 1 {
		switch i % 9 {
		case 0:
			add(&out, framing, ` { "id" : 1, "tags" : [ "a b", "c\"d,", "\\\\" ] } `)
		case 1:
			add(&out, framing, `[1, tru]`)
		case 2:
			add(&out, framing, strings.concatenate({`"x`, strings.repeat(`\`, 64, context.temp_allocator), `"`}, context.temp_allocator))
		case 3:
			add(&out, framing, `{"open": [1, 2`)
		case 4:
			if i == 40 {
				long := strings.repeat(`"spaced  out, [{", `, 20000)
				defer delete(long)
				add(&out, framing, strings.concatenate({"[", long, "0]"}, context.temp_allocator))
			}
		case 5:
			add(&out, framing, `-0.5e+3`)
		case 6:
			if i == 60 {
				add(&out, framing, nested_arrays(json.MAX_DEPTH))
			}
		case 7:
		case 8:
			add(&out, framing, `"]"`)
		}
	}
	if framing == .Root_Entries {
		append(&out, "]")
	}
	return out[:]
}

// A finished bad literal in a record is `Bad_Literal`, not the `Truncated` of a cut record, and NDJSON strips
// a leading BOM from its first record as the other framings do.
@(test)
test_records_name_a_bad_literal_and_strip_the_ndjson_bom :: proc(t: ^testing.T) {
	for src in ([]string{"[1, tru]", "tru\n", "1\ntru\n2\n"}) {
		faults, err := json.validate_records(raw(src), .NDJSON)
		testing.expectf(t, err == nil && len(faults) == 1 && faults[0].err.kind == .Bad_Literal, "%q: %v %v", src, faults, err)
		delete(faults)
	}
	expect_records(t, raw("\xef\xbb\xbf1\n2\n"), .NDJSON, {"1", "2"})
	faults, err := json.validate_records(raw("\xef\xbb\xbf1\n2\n"), .NDJSON)
	testing.expectf(t, err == nil && faults == nil, "%v %v", faults, err)
}

// A refused allocation is `.Out_Of_Memory`, never a valid result with records missing: the fault list of
// `validate_records`, and the slice states `each_record` makes for `.Root_Entries` at a width past one.
@(test)
test_records_refused_allocation_is_out_of_memory :: proc(t: ^testing.T) {
	faults, err := json.validate_records(raw("1\nx\n"), .NDJSON, allocator = runtime.nil_allocator())
	testing.expect(t, err == json.Error{kind = .Out_Of_Memory} && faults == nil, "validate_records")

	pool: host.Batch_Pool
	host.batch_pool_init(&pool, 4)
	defer host.batch_pool_destroy(&pool)
	src := many_records(.Root_Entries)
	defer delete(src)
	calls: int
	context.allocator = runtime.nil_allocator()
	err = json.each_record(src, .Root_Entries, proc(data: rawptr, _: ^json.Records, _: int) -> bool {
		sync.atomic_add((^int)(data), 1)
		return true
	}, &calls, &pool.runner)
	testing.expect(t, err == json.Error{kind = .Out_Of_Memory} && calls == 0, "each_record")
}
