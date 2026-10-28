package csv_tests

import "core:io"
import "core:strings"
import "core:sync"
import "core:testing"
import csv "../"
import "../../host"

// A reader that hands out at most `step` bytes a call, the last of them with `.EOF` when `eof_with_data` is
// set, and then fails with `fail` instead of ending if it is set.
@(private = "file")
Trickle :: struct {
	src:           []byte,
	pos:           int,
	step:          int,
	eof_with_data: bool,
	fail:          io.Error,
}

@(private = "file")
trickle_proc :: proc(data: rawptr, mode: io.Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From) -> (i64, io.Error) {
	t := (^Trickle)(data)
	#partial switch mode {
	case .Read:
		if t.pos == len(t.src) {
			return 0, t.fail if t.fail != nil else .EOF
		}
		n := copy(p[:min(len(p), t.step)], t.src[t.pos:])
		t.pos += n
		if t.pos == len(t.src) && t.fail == nil && t.eof_with_data {
			return i64(n), .EOF
		}
		return i64(n), nil
	case .Query:
		return io.query_utility({.Read, .Query})
	}
	return 0, .Unsupported
}

// Whether `got` and `want` are the same record: its offset, and each field's bytes.
@(private = "file")
same_record :: proc(got, want: csv.Record) -> bool {
	if got.at != want.at || len(got.fields) != len(want.fields) {
		return false
	}
	for f, i in got.fields {
		w := want.fields[i]
		if string(got.src[f.lo:f.hi]) != string(want.src[w.lo:w.hi]) {
			return false
		}
	}
	return true
}

// `records_from` yields the records, offsets and fault that `records` yields over the whole input, whatever
// the read sizes and whether or not the reader returns `.EOF` with its last bytes.
@(test)
test_records_from_agrees_with_records :: proc(t: ^testing.T) {
	long := strings.repeat("x", 300, context.temp_allocator)
	corpus := []string {
		"a,b\n1,2\n",
		"\xEF\xBB\xBFa,b\r\n\r\n\"l1\nl2\",c\r\n",
		strings.concatenate({"a,\"", long, "\"\n", long, ",b\n"}, context.temp_allocator),
		strings.concatenate({long, "é\n", long, "\xE2\x82"}, context.temp_allocator),
		"a,b\n1,\"open",
		"a,b\n1\n",
	}
	for text in corpus {
		src := transmute([]byte)text
		for step in ([]int{1, 2, 3, 7, 64, 130}) {
			for eof_with_data in ([]bool{false, true}) {
				want := csv.records(src, allocator = context.temp_allocator)
				tr := Trickle{src = src, step = step, eof_with_data = eof_with_data}
				got := csv.records_from({procedure = trickle_proc, data = &tr}, allocator = context.temp_allocator)
				got.chunk = step
				for w in csv.next_record(&want) {
					g, ok := csv.next_record(&got)
					if !testing.expectf(t, ok && same_record(g, w), "%q step %d: record at %d, got %v (%v)", text, step, w.at, g, ok) {
						return
					}
				}
				_, extra := csv.next_record(&got)
				testing.expectf(t, !extra && got.err == want.err && got.read_err == nil, "%q step %d: err %v %v, want %v", text, step, got.err, got.read_err, want.err)
			}
		}
	}
}

@(test)
test_records_from_reports_the_readers_failure :: proc(t: ^testing.T) {
	tr := Trickle{src = transmute([]byte)string("a,b\nc,d\ne,"), step = 3, fail = .Unexpected_EOF}
	it := csv.records_from({procedure = trickle_proc, data = &tr})
	defer csv.destroy(&it)
	n := 0
	for _ in csv.next_record(&it) {
		n += 1
	}
	testing.expect_value(t, n, 2)
	testing.expect_value(t, it.err, nil)
	testing.expect_value(t, it.read_err, io.Error.Unexpected_EOF)
}

// The bytes a reader handed over before it failed are read, however few they are.
@(test)
test_records_from_reads_what_a_failing_reader_gave :: proc(t: ^testing.T) {
	cases := []struct {
		src:     string,
		records: int,
	}{{"", 0}, {"a", 0}, {"a\n", 1}, {"a\nb\n", 2}, {"ab\n", 1}, {"a\nb", 1}, {"\xEF\xBB\xBFa\n", 1}}
	for c in cases {
		for step in ([]int{1, 2, 100}) {
			tr := Trickle{src = transmute([]byte)c.src, step = step, fail = .Unexpected_EOF}
			it := csv.records_from({procedure = trickle_proc, data = &tr})
			n := 0
			for _ in csv.next_record(&it) {
				n += 1
			}
			testing.expectf(t, n == c.records, "%q step %d: %d records, want %d", c.src, step, n, c.records)
			testing.expect_value(t, it.err, nil)
			testing.expect_value(t, it.read_err, io.Error.Unexpected_EOF)
			csv.destroy(&it)
		}
	}
}

@(test)
test_records_from_refuses_a_bad_dialect :: proc(t: ^testing.T) {
	tr := Trickle{src = transmute([]byte)string("a"), step = 1}
	it := csv.records_from({procedure = trickle_proc, data = &tr}, {dialect = {delimiter = '"'}})
	defer csv.destroy(&it)
	_, ok := csv.next_record(&it)
	testing.expect(t, !ok)
	testing.expect_value(t, it.err, csv.Error{kind = .Bad_Option})
	testing.expect_value(t, tr.pos, 0)
	tr.src = transmute([]byte)string("a")
	bad := csv.records_from({procedure = trickle_proc, data = &tr}, {limits = {max_record_bytes = -1}})
	defer csv.destroy(&bad)
	testing.expect_value(t, bad.err, csv.Error{kind = .Bad_Option})
}

@(test)
test_record_cap :: proc(t: ^testing.T) {
	Cap_Case :: struct {
		src:  string,
		cap:  int,
		kind: Maybe(csv.Error_Kind),
		at:   u64,
		d:    csv.Dialect,
	}
	cases := []Cap_Case {
		{"abc\nde\n", 3, nil, 0, {}},
		{"abc", 3, nil, 0, {}},
		{"abcd", 3, .Limit_Format, 0, {}},
		{"abcd\n", 3, .Limit_Format, 0, {}},
		{"ab\nabcd\n", 3, .Limit_Format, 3, {}},
		{"abc\r\n", 3, .Limit_Format, 0, {}},
		{"abc\r\n", 4, nil, 0, {}},
		{"\"a\nb\"\n", 4, .Limit_Format, 0, {}},
		{"\"a\nb\"\n", 5, nil, 0, {}},
		{"a\n\n\n\nb\n", 1, nil, 0, {}},
		{"a\n#xyz\nb\n", 3, .Limit_Format, 2, {comment = '#'}},
		{"ab\"c\n", 2, .Bad_Char, 2, {}},
		{"ab\"c\n", 1, .Limit_Format, 0, {}},
		{"a,b\nc,d\ne\n", 2, .Limit_Format, 0, {}},
	}
	for c in cases {
		want: Maybe(csv.Error)
		if k, bad := c.kind.?; bad {
			want = csv_fault(c.at, .Record_Too_Long) if k == .Limit_Format else csv.Error{offset = c.at, kind = k}
		}
		src := transmute([]byte)c.src
		limits := csv.Limits{max_record_bytes = c.cap}
		testing.expectf(t, csv.validate(src, {dialect = c.d, limits = limits}) == want, "%q cap %d: validate %v, want %v", c.src, c.cap, csv.validate(src, {dialect = c.d, limits = limits}), want)
		_, err := collect(src, c.d, .Strict, limits)
		testing.expectf(t, err == want, "%q cap %d: records %v, want %v", c.src, c.cap, err, want)
	}
	// A line one byte over the cap, at offsets that straddle the scanner's blocks.
	long := strings.repeat("y", 200, context.temp_allocator)
	for at in ([]int{0, 62, 63, 64, 65, 138}) {
		src := transmute([]byte)strings.concatenate({strings.repeat("a\n", at / 2, context.temp_allocator), long, "\n"}, context.temp_allocator)
		want := csv_fault(u64(at / 2 * 2), .Record_Too_Long)
		testing.expect_value(t, csv.validate(src, {limits = {max_record_bytes = 199}}), want)
		testing.expect_value(t, csv.validate(src, {limits = {max_record_bytes = 200}}), nil)
	}
}

// A line past its cap whose capped block also holds an invalid UTF-8 byte: the earlier fault wins, the cap
// byte itself being judged as UTF-8 first, and a scan that does not judge UTF-8 reports the cap.
@(test)
test_record_cap_block_utf8 :: proc(t: ^testing.T) {
	for dialect in ([]csv.Dialect{{}, {comment = '#'}, {quoting = .None}, {quoting = .Backslash, comment = '#'}}) {
		for strictness in ([]csv.Strictness{.Strict, .Lazy}) {
			// The cap falls at byte 100, in the block that starts at 64.
			for bad_at in ([]int{70, 99, 100, 101, 127}) {
				line := transmute([]byte)strings.repeat("y", 200, context.temp_allocator)
				line[bad_at] = 0xFF
				opts := csv.Read_Opts{dialect = dialect, strictness = strictness, limits = {max_record_bytes = 100}}
				want := csv_fault(0, .Record_Too_Long)
				if strictness == .Strict && bad_at <= 100 {
					want = csv.Error{offset = u64(bad_at), kind = .Bad_Char}
				}
				testing.expectf(t, csv.validate(line, opts) == want, "%v %v bad at %d: %v, want %v", dialect, strictness, bad_at, csv.validate(line, opts), want)
			}
		}
	}
}

// `each_record` and `validate` over a text longer than its slices, with a runner whose helpers never start (so
// the caller claims the pieces in order) and with a thread pool. The records and the fault are the whole
// input's, in order.
@(test)
test_each_record_pieces :: proc(t: ^testing.T) {
	Tally :: struct {
		records: int,
		pieces:  int,
	}
	count :: proc(tally: ^Tally, piece: ^csv.Records, k: int) -> bool {
		sync.atomic_add(&tally.pieces, 1)
		for _ in csv.next_record(piece) {
			sync.atomic_add(&tally.records, 1)
		}
		return true
	}
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< 20_000 {
		strings.write_string(&b, "id,\"quoted\nline\",x\r\n" if i % 9 == 0 else "id,plain,x\n")
	}
	src := transmute([]byte)strings.to_string(b)
	alone := csv.Batch_Runner {
		threads = 64,
		start = proc(data: rawptr, n: int, task: proc(arg: rawptr), arg: rawptr) {},
		finish = proc(data: rawptr) {},
	}
	pool: host.Batch_Pool
	host.batch_pool_init(&pool, 4)
	defer host.destroy(&pool)
	for runner in ([]^csv.Batch_Runner{nil, &alone, &pool.runner}) {
		tally: Tally
		testing.expect_value(t, csv.each_record(src, count, &tally, {}, runner), nil)
		testing.expect_value(t, tally.records, 20_000)
		testing.expect_value(t, csv.validate(src, runner = runner), nil)
	}
	// A fault is reported once, at its offset, by whichever piece holds it.
	bad := strings.concatenate({strings.to_string(b), "a,\"open"}, context.temp_allocator)
	want := csv.Error{offset = u64(len(bad)), kind = .Truncated}
	for runner in ([]^csv.Batch_Runner{nil, &alone, &pool.runner}) {
		tally: Tally
		testing.expect_value(t, csv.each_record(transmute([]byte)bad, count, &tally, {}, runner), want)
		testing.expect_value(t, csv.validate(transmute([]byte)bad, runner = runner), want)
	}
}

@(test)
test_record_window_and_open_field_at :: proc(t: ^testing.T) {
	src := "a,b\n1,2\n3,\"x"
	tr := Trickle{src = transmute([]byte)src, step = 4}
	rr := csv.records_from({procedure = trickle_proc, data = &tr}, allocator = context.temp_allocator)
	defer csv.destroy(&rr)
	n := 0
	for rec in csv.next_record(&rr) {
		window, base := csv.record_window(&rr)
		testing.expect(t, raw_data(rec.src) == raw_data(window))
		record, _ := csv.open_field_at(&rr)
		testing.expect_value(t, base + u64(record), rec.at + 4)
		n += 1
	}
	testing.expect_value(t, n, 2)
	e, bad := rr.err.?
	testing.expect(t, bad && e.kind == .Truncated)
	window, base := csv.record_window(&rr)
	_, field := csv.open_field_at(&rr)
	testing.expect(t, field < len(window) && window[field] == '"')
	testing.expect_value(t, base + u64(field), 10)
}
