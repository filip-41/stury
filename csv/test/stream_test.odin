package csv_tests

import "base:runtime"
import "core:io"
import "core:strings"
import "core:testing"
import csv "../"
import "../../host"

STREAM_DIALECTS :: []csv.Dialect {
	{},
	csv.TSV,
	{delimiter = ';', quoting = .None},
	{comment = '#'},
	{ragged = true},
	{delimiter = '\t', quoting = .None, escapes = .Backslash, comment = '#', ragged = true},
}

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

@(private = "file")
rnd :: proc(s: ^u64) -> u64 {
	s^ ~= s^ << 13
	s^ ~= s^ >> 7
	s^ ~= s^ << 17
	return s^
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

// For every read size from 1 to 130, `records_from` yields the records, offsets and fault `records` yields over
// the whole, in every dialect, with and without caps.
@(test)
test_records_from_agrees_with_records :: proc(t: ^testing.T) {
	long := strings.repeat("x", 300, context.temp_allocator)
	corpus := []string {
		"",
		"\n",
		"a",
		"\xEF\xBB\xBF",
		"\xEF\xBB\xBFa,b\n",
		"\xEF\xBB",
		strings.concatenate({"a,\"", long, "\"\n", long, ",b\n"}, context.temp_allocator),
		strings.concatenate({long, "\n", long, ",x\n"}, context.temp_allocator),
		strings.concatenate({"\"", long, "\n", long}, context.temp_allocator),
		strings.concatenate({long, "é\n", long, "\xE2\x82"}, context.temp_allocator),
	}
	seed := u64(0x2545F4914F6CDD1D)
	for d in STREAM_DIALECTS {
		inputs := make([dynamic][]byte, context.temp_allocator)
		for text in corpus {
			append(&inputs, transmute([]byte)text)
		}
		for _ in 0 ..< 40 {
			append(&inputs, generate(&seed, d, context.temp_allocator))
		}
		for src, n in inputs {
			for step in 1 ..= 130 {
				strictness := csv.Strictness.Strict if rnd(&seed) % 4 != 0 else .Structural
				limits: csv.Limits
				if rnd(&seed) % 3 == 0 {
					limits.max_record_bytes = 1 + int(rnd(&seed) % 120)
				}
				if rnd(&seed) % 6 == 0 {
					limits.max_fields = 1 + int(rnd(&seed) % 4)
				}
				if !records_from_agrees(t, src, d, strictness, limits, step, rnd(&seed)) {
					testing.expectf(t, false, "%v input %d %q step %d %v %v", d, n, src, step, strictness, limits)
					return
				}
			}
		}
		free_all(context.temp_allocator)
	}
}

@(private = "file")
records_from_agrees :: proc(t: ^testing.T, src: []byte, d: csv.Dialect, strictness: csv.Strictness, limits: csv.Limits, step: int, coin: u64) -> bool {
	want := csv.records(src, d, strictness, limits)
	defer csv.records_destroy(&want)
	tr := Trickle{src = src, step = 1 + int(coin % u64(step)), eof_with_data = coin & 256 != 0}
	got := csv.records_from({procedure = trickle_proc, data = &tr}, d, strictness, limits)
	got.chunk = step
	defer csv.records_destroy(&got)
	for w in csv.next_record(&want) {
		g, ok := csv.next_record(&got)
		if !testing.expectf(t, ok && same_record(g, w), "record at %d: got %v (%v)", w.at, g, ok) {
			return false
		}
	}
	_, extra := csv.next_record(&got)
	ok := testing.expectf(t, !extra && got.err == want.err && got.read_err == nil, "err %v %v %v, want %v", extra, got.err, got.read_err, want.err)
	vok := testing.expectf(t, csv.validate(src, d, strictness, limits) == want.err, "validate %v, want %v", csv.validate(src, d, strictness, limits), want.err)
	return ok && vok
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
	long := strings.repeat("y", 200, context.temp_allocator)
	for at in 0 ..< 140 {
		src := transmute([]byte)strings.concatenate({strings.repeat("a\n", at / 2, context.temp_allocator), long, "\n"}, context.temp_allocator)
		want := csv.Error{offset = u64(at / 2 * 2), kind = .Limit_Record}
		testing.expect_value(t, csv.validate(src, {}, .Strict, {max_record_bytes = 199}), want)
		testing.expect_value(t, csv.validate(src, {}, .Strict, {max_record_bytes = 200}), nil)
		_, err := collect(src, {}, .Strict, {max_record_bytes = 199})
		testing.expect_value(t, err, want)
	}
}

// Large CSV in dialect `d` past several of `each_record`'s slices (32 KiB), with a row at every slice offset
// that the offset cuts at a random byte: a quoted line break, a doubled quote, CRLF, UTF-8, an escape, a comment
// line or a row's end, and, for each of `faults`, a broken row there instead.
@(private = "file")
big_csv :: proc(seed: ^u64, d: csv.Dialect, size: int, faults: []int, long: int) -> []byte {
	SLICE :: 32 * 1024
	out := make([dynamic]byte, context.temp_allocator)
	delim := d.delimiter if d.delimiter != 0 else ','
	crlf := rnd(seed) % 2 == 0
	eol := "\r\n" if crlf else "\n"
	width := 3
	quoted := []string{"\"a\nb\"", "\"a\"\"b\"", "\"c\r\nd\"", "\"日本\"", "\"\"", "\"x,y\"", "😀"}
	unquoted := []string{"a\\nb", "x\"y", "日本", "\\\\", "\\t", "😀z", "plain"}
	broken_quoted := []string{"a\"b", "\"ab\"c", "a\rb", "\xFFx", "\"open"}
	broken_unquoted := []string{"a\rb", "\xFFx", "\\x", "a\\"}
	row :: proc(out: ^[dynamic]byte, first: string, n: int, delim: byte, eol: string) {
		append(out, first)
		for _ in 1 ..< n {
			append(out, delim)
			append(out, "f")
		}
		append(out, eol)
	}
	for k := 1; ; k += 1 {
		p := k * SLICE
		if p >= size {
			break
		}
		special := strings.builder_make(context.temp_allocator)
		fault := false
		for f in faults {
			fault ||= f == k
		}
		switch {
		case fault && long > 0:
			strings.write_string(&special, strings.repeat("L", long + 1, context.temp_allocator))
		case fault && !d.ragged && rnd(seed) % 3 == 0:
			strings.write_string(&special, "w")
			strings.write_byte(&special, delim)
		case fault && d.quoting == .Quotes:
			strings.write_string(&special, broken_quoted[rnd(seed) % u64(len(broken_quoted))])
		case fault:
			strings.write_string(&special, broken_unquoted[rnd(seed) % u64(len(broken_unquoted))])
		case d.comment != 0 && rnd(seed) % 3 == 0:
			strings.write_byte(&special, d.comment)
			strings.write_string(&special, " a \"comment\" \\x")
		case d.quoting == .Quotes:
			strings.write_string(&special, quoted[rnd(seed) % u64(len(quoted))])
		case:
			strings.write_string(&special, unquoted[rnd(seed) % u64(len(unquoted))])
		}
		first := strings.to_string(special)
		is_comment := d.comment != 0 && len(first) > 0 && first[0] == d.comment
		n := 1 if is_comment else width
		row_len := len(first) + 2 * (n - 1) + len(eol)
		j := int(rnd(seed) % u64(row_len + 1))
		for len(out) < p - j - 300 {
			row(&out, "plain", width if !d.ragged else 1 + int(rnd(seed) % 4), delim, eol)
		}
		pad := p - j - len(out) - 2 * (width - 1) - len(eol)
		row(&out, strings.repeat("x", pad, context.temp_allocator), width, delim, eol)
		row(&out, first, n, delim, eol)
	}
	for len(out) < size {
		row(&out, "tail", width, delim, eol)
	}
	if rnd(seed) % 2 == 0 {
		pop(&out)
	}
	return out[:]
}

// What `each_record` handed each piece's task: its records, their fields flat in `fields`, and its fault. Each
// piece's entry is written by the one thread that ran it, in the heap.
@(private = "file")
Piece_Log :: [64]Piece

@(private = "file")
Piece :: struct {
	seen:   bool,
	recs:   [dynamic]Logged,
	fields: [dynamic]csv.Field,
	src:    []byte,
	err:    Maybe(csv.Error),
}

@(private = "file")
Logged :: struct {
	at:     u64,
	lo, hi: int,
}

@(private = "file")
log_piece :: proc(data: rawptr, piece: ^csv.Records, k: int) -> bool {
	log := (^Piece_Log)(data)
	if k >= len(log) {
		return false
	}
	log_records(&log[k], piece)
	return true
}

@(private = "file")
log_records :: proc(p: ^Piece, piece: ^csv.Records) {
	p.seen = true
	p.recs = make([dynamic]Logged, runtime.heap_allocator())
	p.fields = make([dynamic]csv.Field, runtime.heap_allocator())
	for r in csv.next_record(piece) {
		append(&p.recs, Logged{at = r.at, lo = len(p.fields), hi = len(p.fields) + len(r.fields)})
		append(&p.fields, ..r.fields)
		p.src = r.src
	}
	p.err = piece.err
}

@(private = "file")
log_free :: proc(log: ^Piece_Log) {
	for &p in log {
		delete(p.recs)
		delete(p.fields)
	}
}

// `each_record` and `validate` with `runner` against `records` and `validate` alone: the records of the pieces
// in order, up to the first that ends on a fault, and the fault.
@(private = "file")
pieces_agree :: proc(t: ^testing.T, src: []byte, d: csv.Dialect, strictness: csv.Strictness, limits: csv.Limits, runner: ^csv.Batch_Runner, what: string) -> bool {
	want := new(Piece, context.temp_allocator)
	defer delete(want.recs)
	defer delete(want.fields)
	whole := csv.records(src, d, strictness, limits, context.temp_allocator)
	log_records(want, &whole)
	if !testing.expectf(t, csv.validate(src, d, strictness, limits) == want.err, "%s: validate %v, records %v", what, csv.validate(src, d, strictness, limits), want.err) {
		return false
	}
	if got := csv.validate(src, d, strictness, limits, runner); !testing.expectf(t, got == want.err, "%s: validate with a runner %v, want %v", what, got, want.err) {
		return false
	}
	log := new(Piece_Log, context.temp_allocator)
	defer log_free(log)
	fault := csv.each_record(src, d, log_piece, log, runner, strictness, limits)
	if !testing.expectf(t, fault == want.err, "%s: each_record %v, want %v", what, fault, want.err) {
		return false
	}
	i := 0
	for &p, k in log {
		if !p.seen {
			break
		}
		for r in p.recs {
			if !testing.expectf(t, i < len(want.recs), "%s: piece %d record at %d past the whole's", what, k, r.at) {
				return false
			}
			w := want.recs[i]
			got := csv.Record{fields = p.fields[r.lo:r.hi], at = r.at, src = p.src}
			if !testing.expectf(t, same_record(got, {fields = want.fields[w.lo:w.hi], at = w.at, src = want.src}), "%s: piece %d record at %d, want one at %d", what, k, r.at, w.at) {
				return false
			}
			i += 1
		}
		if p.err != nil {
			return testing.expectf(t, p.err == want.err, "%s: piece %d ends on %v, want %v", what, k, p.err, want.err)
		}
	}
	return testing.expectf(t, i == len(want.recs), "%s: %d records, want %d", what, i, len(want.recs))
}

// Pieces cut at every slice, by a runner whose helpers never come so the caller claims them in order, and by a
// pool of threads.
@(test)
test_pieces_agree_with_the_whole :: proc(t: ^testing.T) {
	alone := csv.Batch_Runner {
		threads = 64,
		start = proc(data: rawptr, n: int, task: proc(arg: rawptr), arg: rawptr) {},
		finish = proc(data: rawptr) {},
	}
	pool: host.Batch_Pool
	host.batch_pool_init(&pool, 4)
	defer host.batch_pool_destroy(&pool)
	seed := u64(0x9E3779B97F4A7C15)
	for d in STREAM_DIALECTS {
		for variant in 0 ..< 9 {
			size := 5 * 128 * 1024 + int(rnd(&seed) % 4096)
			faults: []int
			long := 0
			limits: csv.Limits
			switch variant {
			case 1:
				faults = {3 + int(rnd(&seed) % 14)}
			case 2:
				faults = {7, 4}
			case 3:
				faults = {1}
			case 4:
				faults = {16}
				long = 4096
				limits.max_record_bytes = 4096
			case 5:
				limits.max_record_bytes = 400
			case 6:
				limits.max_fields = 2 if !d.ragged else 3
			}
			src := big_csv(&seed, d, size, faults, long)
			strictness := csv.Strictness.Strict if variant != 7 else .Structural
			if variant == 8 {
				src[0] = '"'
			}
			if !pieces_agree(t, src, d, strictness, limits, &alone, "alone") || !pieces_agree(t, src, d, strictness, limits, &pool.runner, "pool") {
				testing.expectf(t, false, "%v variant %d", d, variant)
				return
			}
			free_all(context.temp_allocator)
		}
	}
}
