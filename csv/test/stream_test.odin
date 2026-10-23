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

// `records_from` yields the records, offsets and fault `records` yields over the whole, however the reader
// hands the bytes out and whether or not it ends with its last bytes.
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
	defer csv.records_destroy(&it)
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
			csv.records_destroy(&it)
		}
	}
}

@(test)
test_records_from_refuses_a_bad_dialect :: proc(t: ^testing.T) {
	tr := Trickle{src = transmute([]byte)string("a"), step = 1}
	it := csv.records_from({procedure = trickle_proc, data = &tr}, {delimiter = '"'})
	defer csv.records_destroy(&it)
	_, ok := csv.next_record(&it)
	testing.expect(t, !ok)
	testing.expect_value(t, it.err, csv.Error{kind = .Bad_Option})
	testing.expect_value(t, tr.pos, 0)
	tr.src = transmute([]byte)string("a")
	bad := csv.records_from({procedure = trickle_proc, data = &tr}, {}, .Strict, {max_record_bytes = -1})
	defer csv.records_destroy(&bad)
	testing.expect_value(t, bad.err, csv.Error{kind = .Bad_Option})
}

@(test)
test_record_cap :: proc(t: ^testing.T) {
	Cap_Case :: struct {
		src:  string,
		cap:  int,
		kind: csv.Error_Kind,
		at:   u64,
		d:    csv.Dialect,
	}
	cases := []Cap_Case {
		{"abc\nde\n", 3, .None, 0, {}},
		{"abc", 3, .None, 0, {}},
		{"abcd", 3, .Limit_Record, 0, {}},
		{"abcd\n", 3, .Limit_Record, 0, {}},
		{"ab\nabcd\n", 3, .Limit_Record, 3, {}},
		{"abc\r\n", 3, .Limit_Record, 0, {}},
		{"abc\r\n", 4, .None, 0, {}},
		{"\"a\nb\"\n", 4, .Limit_Record, 0, {}},
		{"\"a\nb\"\n", 5, .None, 0, {}},
		{"a\n\n\n\nb\n", 1, .None, 0, {}},
		{"a\n#xyz\nb\n", 3, .Limit_Record, 2, {comment = '#'}},
		{"ab\"c\n", 2, .Bad_Char, 2, {}},
		{"ab\"c\n", 1, .Limit_Record, 0, {}},
		{"a,b\nc,d\ne\n", 2, .Limit_Record, 0, {}},
	}
	for c in cases {
		want: Maybe(csv.Error)
		if c.kind != .None {
			want = csv.Error{offset = c.at, kind = c.kind}
		}
		src := transmute([]byte)c.src
		limits := csv.Limits{max_record_bytes = c.cap}
		testing.expectf(t, csv.validate(src, c.d, .Strict, limits) == want, "%q cap %d: validate %v, want %v", c.src, c.cap, csv.validate(src, c.d, .Strict, limits), want)
		_, err := collect(src, c.d, .Strict, limits)
		testing.expectf(t, err == want, "%q cap %d: records %v, want %v", c.src, c.cap, err, want)
	}
	// A line one byte over the cap, at offsets that straddle the scanner's blocks.
	long := strings.repeat("y", 200, context.temp_allocator)
	for at in ([]int{0, 62, 63, 64, 65, 138}) {
		src := transmute([]byte)strings.concatenate({strings.repeat("a\n", at / 2, context.temp_allocator), long, "\n"}, context.temp_allocator)
		want := csv.Error{offset = u64(at / 2 * 2), kind = .Limit_Record}
		testing.expect_value(t, csv.validate(src, {}, .Strict, {max_record_bytes = 199}), want)
		testing.expect_value(t, csv.validate(src, {}, .Strict, {max_record_bytes = 200}), nil)
	}
}

// `each_record` hands each piece of a text past its slices to the task, and `validate` takes the same runner: with
// a runner whose helpers never come, so the caller claims the pieces in order, and with a pool of threads, the
// records are the whole's in order and the fault is the whole's.
@(test)
test_each_record_pieces :: proc(t: ^testing.T) {
	Tally :: struct {
		records: int,
		pieces:  int,
	}
	count :: proc(data: rawptr, piece: ^csv.Records, k: int) -> bool {
		tally := (^Tally)(data)
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
	defer host.batch_pool_destroy(&pool)
	for runner in ([]^csv.Batch_Runner{nil, &alone, &pool.runner}) {
		tally: Tally
		testing.expect_value(t, csv.each_record(src, {}, count, &tally, runner), nil)
		testing.expect_value(t, tally.records, 20_000)
		testing.expect_value(t, csv.validate(src, {}, .Strict, {}, runner), nil)
	}
	// A fault is reported once, at its offset, by whichever piece holds it.
	bad := strings.concatenate({strings.to_string(b), "a,\"open"}, context.temp_allocator)
	want := csv.Error{offset = u64(len(bad)), kind = .Truncated}
	for runner in ([]^csv.Batch_Runner{nil, &alone, &pool.runner}) {
		tally: Tally
		testing.expect_value(t, csv.each_record(transmute([]byte)bad, {}, count, &tally, runner), want)
		testing.expect_value(t, csv.validate(transmute([]byte)bad, {}, .Strict, {}, runner), want)
	}
}
