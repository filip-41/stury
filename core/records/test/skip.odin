package records_tests

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"
import core "../.."
import host "../../../host"
import typed "../../typed"
import records ".."
import schema "../../schema"
import dsv "../../../dsv"
import json "../../../json"
import yaml "../../../yaml"
import testkit "../../../testkit"

// A reader that goes on past each bad record `records.skip` names, in memory and on streams of every chunk size, against
// the records and faults written out, and `validate` and `check_each` past them on one thread and on pools.

// Each record of `it` as its text, and each bad record `skip` goes past as `!TEXT@AT`, its text the bytes of `src` it
// spans, of which the window's are the last, then the fault the records ended on.
@(private = "file")
skipping :: proc(t: ^testing.T, it: ^records.Reader, src: string) -> (got: []string, fault: Maybe(core.Fault)) {
	out := make([dynamic]string, context.temp_allocator)
	for {
		for rec in records.next(it) {
			append(&out, strings.clone(string(rec.text), context.temp_allocator))
		}
		bad, ok := records.skip(it)
		if !ok {
			break
		}
		spanned := src[bad.at:bad.end]
		testing.expectf(t, strings.has_suffix(spanned, string(bad.text)), "%q holds %q", spanned, bad.text)
		append(&out, fmt.tprintf("!%s@%d", spanned, bad.at))
	}
	return out[:], it.fault
}

@(private = "file")
LONG :: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

Skip_Case :: struct {
	src:  string,
	want: []string,
}

// The records of each case, in memory and on a stream read in chunks of each size, whose records are the same but for
// a torn last record, which the stream holds.
@(private = "file")
expect_skipping :: proc(t: ^testing.T, as: core.As, framing: core.Framing, cases: []Skip_Case, loc := #caller_location) {
	for c in cases {
		it := records.open(transmute([]u8)c.src, as, framing)
		got, fault := skipping(t, &it, c.src)
		records.close(&it)
		testing.expectf(t, slice.equal(got, c.want) && fault == nil, "%q: %q %v, want %q", c.src, got, fault, c.want, loc = loc)
		for size in ([?]int{1, 3, 64}) {
			trickle := testkit.Chunked{src = transmute([]u8)c.src, sizes = {size}}
			s := records.open_stream(testkit.chunked(&trickle), as, framing)
			streamed, stream_fault := skipping(t, &s, c.src)
			want := c.want
			if len(s.held) > 0 {
				// The stream holds the torn last record.
				want = want[:len(want) - 1]
			}
			testing.expectf(t, slice.equal(streamed, want) && stream_fault == nil, "%q in chunks of %d: %q %v held %q, want %q", c.src, size, streamed, stream_fault, s.held, c.want, loc = loc)
			records.close(&s)
		}
	}
}

@(test)
skip_concatenated_json :: proc(t: ^testing.T) {
	expect_skipping(t, json.as(.Json), .Concatenated, {
		{"{\"v\":1}\n{\"v\" 2}\n{\"v\":3}\n", {"{\"v\":1}", "!{\"v\" 2}@8", "{\"v\":3}"}},
		// A fault at its line's first byte starts the next record there.
		{"[1, 2\n{\"b\":1}\n", {"![1, 2@0", "{\"b\":1}"}},
		{"x\ny\n1\n", {"!x@0", "!y@2", "1"}},
		{"{\"v\":1} {\"v\" 2} {\"v\":3}\n2", {"{\"v\":1}", "!{\"v\" 2} {\"v\":3}@8", "2"}},
		{"{\"v\":1}\r\n{\"v\" 2}\r\n3\r\n", {"{\"v\":1}", "!{\"v\" 2}@9", "3"}},
		{"\xef\xbb\xbf{\"v\" 2}\n3\n", {"!{\"v\" 2}@3", "3"}},
		// A bad last record with no line end runs to the input's end.
		{"1\n{\"a\":", {"1", "!{\"a\":@2"}},
		{"1\n\"a\n2", {"1", "!\"a@2", "2"}},
		// A bad record that spans a stream's windows.
		{"1\n{\"a\" " + LONG + "\n2\n", {"1", "!{\"a\" " + LONG + "@2", "2"}},
	})
	// The comments past the record before a bad one are the bad record's.
	expect_skipping(t, json.as(.Jsonc), .Concatenated, {{"1 // one\n/* c */ x\n2", {"1", "!// one\n/* c */ x@2", "2"}}})
}

@(test)
skip_rows :: proc(t: ^testing.T) {
	expect_skipping(t, dsv.as(.Csv), .Lines, {
		{"a,b\n1,2\n3,\"x\n4,5\n", {"1,2", "!3,\"x@8", "4,5"}},
		{"a,b\n1,2\n3\n4,5\n", {"1,2", "!3@8", "4,5"}},
		{"a,b\n3\n4,5\n", {"!3@4", "4,5"}},
		{"a,b\r\n1,2\r\n3\r\n4,5\r\n", {"1,2", "!3@10", "4,5"}},
		{"\xef\xbb\xbfa,b\n3\n4,5", {"!3@7", "4,5"}},
		{"a,b\n1,2\n3,4,5", {"1,2", "!3,4,5@8"}},
	})
	expect_skipping(t, dsv.as(.Csv, {no_header = true}), .Lines, {{"1\n2,3\n4\n", {"1", "!2,3@2", "4"}}})
	// A row past the first batch.
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	strings.write_string(&b, "a,b\n")
	want := make([dynamic]string, context.temp_allocator)
	for i in 0 ..< 300 {
		if i == 270 {
			append(&want, fmt.tprintf("!x@%d", strings.builder_len(b)))
			strings.write_string(&b, "x\n")
		} else {
			append(&want, fmt.tprintf("%d,%d", i, i))
			fmt.sbprintf(&b, "%d,%d\n", i, i)
		}
	}
	expect_skipping(t, dsv.as(.Csv), .Lines, {{strings.to_string(b), want[:]}})
	// A header that does not read names no column, so no row is read past it.
	it := records.open(transmute([]u8)string("a,\"b\n1,2\n"), dsv.as(.Csv))
	defer records.close(&it)
	_, more := records.next(&it)
	_, skipped := records.skip(&it)
	testing.expect(t, !more && !skipped && it.fault != nil)
}

@(test)
skip_documents :: proc(t: ^testing.T) {
	expect_skipping(t, yaml.as(.Yaml_1_2), .Concatenated, {
		{"a: 1\n---\nb: [\n---\nc: 3\n", {"a: 1\n", "!---\nb: [@5", "---\nc: 3\n"}},
		{"a: 1\n---\nb: c: d\n---\nc: 3\n", {"a: 1\n", "!---\nb: c: d@5", "---\nc: 3\n"}},
		{"--- [\n", {"!--- [@0"}},
	})
}

// No framing past `.Entries` or a CBOR item has a place to go on at, and under `.Lines` a record is framed whatever its
// text.
@(test)
skip_refused :: proc(t: ^testing.T) {
	it := records.open(transmute([]u8)string("[1, x, 2]"), json.as(.Json), .Entries)
	defer records.close(&it)
	for _ in records.next(&it) {}
	_, skipped := records.skip(&it)
	testing.expect(t, !skipped && it.fault != nil)
	lines := records.open(transmute([]u8)string("1\nx\n2"), json.as(.Json), .Lines)
	defer records.close(&lines)
	got, _ := skipping(t, &lines, "1\nx\n2")
	testing.expectf(t, slice.equal(got, []string{"1", "x", "2"}), "%q", got)
}

@(private = "file")
WIDTHS :: [?]int{1, 2, 6}

// `validate` with `skip` gives one fault per bad record on one thread and on pools alike.
@(test)
skip_validate :: proc(t: ^testing.T) {
	pools: [len(WIDTHS)]host.Pool
	for w, i in WIDTHS {
		host.pool_init(&pools[i], w)
	}
	defer for &p in pools {
		host.pool_destroy(&p)
	}
	Case :: struct {
		src:     string,
		as:      core.As,
		framing: core.Framing,
		at:      []u64,
	}
	for c in ([?]Case{
		{"{\"v\":1}\n{\"v\" 2}\n[1,\n{\"v\":3}\nx", json.as(.Json), .Concatenated, {13, 28, 28}},
		{"{\"v\":1}\n{\"v\" 2}\n[1,\n{\"v\":3}\nx", json.as(.Json), .Lines, {13, 19, 28}},
		{"\x1e1\n\x1e{\"v\" 2}\n\x1e[\n", json.as(.Json), .Seq, {9, 15}},
		{"a,b\n1,2\n3\n4,5\n6,\"7\n", dsv.as(.Csv), .Lines, {9, 16}},
		{"a: 1\n---\nb: [\n---\nc: 3\n--- ]\n", yaml.as(.Yaml_1_2), .Concatenated, {14, 27}},
	}) {
		src := transmute([]u8)c.src
		serial, _ := records.validate(src, c.as, c.framing, context.temp_allocator, skip = true)
		at := make([]u64, len(serial), context.temp_allocator)
		for f, i in serial {
			at[i] = f.at
		}
		testing.expectf(t, slice.equal(at, c.at), "%v %q: faults at %v, want %v", c.framing, c.src, at, c.at)
		for &pool in pools {
			got, _ := records.validate(src, c.as, c.framing, context.temp_allocator, &pool.runner, skip = true)
			testing.expectf(t, slice.equal(got, serial), "%v %q at width %d: %v, want %v", c.framing, c.src, pool.runner.threads + 1, got, serial)
		}
	}
}

// `check_each` with `bad_records` counts a bad record as a failure, names it with its fault, and checks the records past
// it, the same on pools.
@(test)
skip_check :: proc(t: ^testing.T) {
	c, err := schema.compile(transmute([]u8)string(`{"type":"object","required":["v"]}`), json.as(.Json))
	if !testkit.expect_nil(t, err) {
		return
	}
	defer schema.destroy(c)
	b: schema.Bound
	b, err = schema.bind(c, json.checks(.Json))
	if !testkit.expect_nil(t, err) {
		return
	}
	defer schema.unbind(&b)
	pool: host.Pool
	host.pool_init(&pool, 3)
	defer host.pool_destroy(&pool)
	src := transmute([]u8)string("{\"v\":1}\nx\n{}\n{\"v\" 2}\n{\"v\":3}\n")
	for framing in ([?]core.Framing{.Lines, .Concatenated}) {
		for runner in ([?]^core.Runner{nil, &pool.runner}) {
			sink := typed.Sink{entries = make([dynamic]core.Error_Entry, context.temp_allocator)}
			bad := make([dynamic]records.Bad_Record, context.temp_allocator)
			count, failure, fatal, failed := records.check_each(src, b.plan.as, framing, &b.plan, nil, &sink, runner, 0, .Default, .Notice, &bad)
			testing.expectf(t, count == 5 && failure.kind == .Walk && failed == 1 && fatal.kind == .None, "%v: %d records, first failure %v of record %d, fatal %v", framing, count, failure.kind, failed, fatal.kind)
			if testing.expectf(t, len(bad) == 2, "%v: bad %v", framing, bad[:]) {
				testing.expectf(t, string(bad[0].text) == "x" && bad[0].at == 8 && bad[1].at == 13 && bad[1].fault.kind == .Bad_Char, "%v: %v", framing, bad[:])
			}
			records_of := make([dynamic]i64, context.temp_allocator)
			for e in sink.entries {
				if e.kind == .Walk || len(records_of) == 0 || records_of[len(records_of) - 1] != e.record {
					append(&records_of, e.record)
				}
			}
			testing.expectf(t, slice.equal(records_of[:], []i64{1, 2, 3}), "%v width %v: failures of records %v", framing, runner != nil, records_of[:])
		}
	}
}
