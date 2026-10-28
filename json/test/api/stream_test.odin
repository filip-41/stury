package json_tests

import "core:io"
import "core:strings"
import "core:testing"
import json "../.."

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
Stream_Case :: struct {
	src:     string,
	framing: json.Framing,
	cap:     int,
}

// Each record, its fault as `judge_record` tells it after a `validate` of its bytes, and the iterator's fault: the
// reader's must equal the whole input's.
@(private = "file")
expect_stream_agrees :: proc(t: ^testing.T, c: Stream_Case, step: int, eof_with_data: bool) -> bool {
	src := transmute([]byte)c.src
	opts := json.Record_Opts{framing = c.framing, max_record_bytes = c.cap}
	want := json.records(src, opts)
	tr := Trickle{src = src, step = step, eof_with_data = eof_with_data}
	got := json.records_from({procedure = trickle_proc, data = &tr}, opts, context.temp_allocator)
	defer json.destroy(&got)
	got.chunk = step
	for w in json.next_record(&want) {
		g, ok := json.next_record(&got)
		if !testing.expectf(t, ok && g.at == w.at && string(g.bytes) == string(w.bytes) && string(g.key) == string(w.key), "%q %v step %d: record at %d, got %v (%v)", c.src, c.framing, step, w.at, g, ok) {
			return false
		}
		_, wj := json.judge_record(src, w, json.validate(w.bytes), opts)
		_, gj := json.judge_record(&got, g, json.validate(g.bytes), opts)
		if !testing.expectf(t, gj == wj, "%q %v step %d: record at %d judged %v, want %v", c.src, c.framing, step, w.at, gj, wj) {
			return false
		}
	}
	_, extra := json.next_record(&got)
	return testing.expectf(t, !extra && got.err == want.err && got.read_err == nil, "%q %v step %d: err %v %v, want %v", c.src, c.framing, step, got.err, got.read_err, want.err)
}

// A pushed reader fed `step` new bytes a window, after the bytes it carries: the stream's end comes with the last
// bytes when `eof_with_data` is set, else as a window of none.
@(private = "file")
Push_Feed :: struct {
	src:           []byte,
	pos:           int,
	step:          int,
	eof_with_data: bool,
}

@(private = "file")
next_pushed :: proc(rr: ^json.Record_Reader, f: ^Push_Feed) -> (rec: json.Record, ok: bool) {
	for {
		if rec, ok = json.next_record(rr); ok {
			return
		}
		carry, more := json.record_carry(rr)
		if !more {
			return
		}
		n := min(f.step, len(f.src) - f.pos)
		window := make([]byte, len(carry) + n, context.temp_allocator)
		copy(window, carry)
		copy(window[len(carry):], f.src[f.pos:][:n])
		f.pos += n
		json.record_push(rr, window, f.pos == len(f.src) && (n == 0 || f.eof_with_data))
	}
}

// The pushed reader's records, judged faults and fault: the whole input's.
@(private = "file")
expect_pushed_agrees :: proc(t: ^testing.T, c: Stream_Case, step: int, eof_with_data: bool) -> bool {
	src := transmute([]byte)c.src
	opts := json.Record_Opts{framing = c.framing, max_record_bytes = c.cap}
	want := json.records(src, opts)
	got := json.records_pushed(opts)
	defer json.destroy(&got)
	feed := Push_Feed{src = src, step = step, eof_with_data = eof_with_data}
	for w in json.next_record(&want) {
		g, ok := next_pushed(&got, &feed)
		if !testing.expectf(t, ok && g.at == w.at && string(g.bytes) == string(w.bytes) && string(g.key) == string(w.key), "%q %v step %d: pushed record at %d, got %v (%v)", c.src, c.framing, step, w.at, g, ok) {
			return false
		}
		_, wj := json.judge_record(src, w, json.validate(w.bytes), opts)
		_, gj := json.judge_record(&got, g, json.validate(g.bytes), opts)
		if !testing.expectf(t, gj == wj, "%q %v step %d: pushed record at %d judged %v, want %v", c.src, c.framing, step, w.at, gj, wj) {
			return false
		}
	}
	_, extra := next_pushed(&got, &feed)
	return testing.expectf(t, !extra && got.err == want.err, "%q %v step %d: pushed err %v, want %v", c.src, c.framing, step, got.err, want.err)
}

// The pushed reader's next record as a caller that reads each record itself takes it (`next_record_open`): an open
// text validated and ended by that read (`end_record`), and a text the window cut read again once pushed more.
@(private = "file")
next_read_pushed :: proc(rr: ^json.Record_Reader, f: ^Push_Feed) -> (rec: json.Record, read: Maybe(json.Error), ok: bool) {
	for {
		if rec, ok = json.next_record_open(rr); ok {
			read = json.validate(rec.bytes)
			ended, cut := json.end_record(rr, read)
			switch {
			case ended.bytes != nil:
				return ended, json.validate(ended.bytes) if read != nil else nil, true
			case !cut:
				// No text was open, and the record is as handed out, or the text is past the cap.
				return rec, read, rr.err == nil
			}
		}
		carry, more := json.record_carry(rr)
		if !more {
			return {}, nil, false
		}
		n := min(f.step, len(f.src) - f.pos)
		window := make([]byte, len(carry) + n, context.temp_allocator)
		copy(window, carry)
		copy(window[len(carry):], f.src[f.pos:][:n])
		f.pos += n
		json.record_push(rr, window, f.pos == len(f.src) && (n == 0 || f.eof_with_data))
	}
}

// Read through `next_record_open` and `end_record`, the pushed reader yields the records `records` yields: the
// same text where its read accepts it, else the same fault at the same offset, and the same records past it.
@(private = "file")
expect_read_pushed_agrees :: proc(t: ^testing.T, c: Stream_Case, step: int, eof_with_data: bool) -> bool {
	src := transmute([]byte)c.src
	opts := json.Record_Opts{framing = c.framing, max_record_bytes = c.cap}
	want := json.records(src, opts)
	got := json.records_pushed(opts)
	defer json.destroy(&got)
	feed := Push_Feed{src = src, step = step, eof_with_data = eof_with_data}
	for w in json.next_record(&want) {
		g, gread, ok := next_read_pushed(&got, &feed)
		wread := json.validate(w.bytes)
		same := ok && g.at == w.at && (string(g.bytes) == string(w.bytes) || wread != nil && gread == wread)
		if !testing.expectf(t, same, "%q %v step %d: read record at %d %q (%v), got %v %v (%v)", c.src, c.framing, step, w.at, w.bytes, wread, g, gread, ok) {
			return false
		}
	}
	g, gread, extra := next_read_pushed(&got, &feed)
	if e, capped := want.err.?; extra && capped && e.kind == .Limit_Format {
		// A text past the cap that its read refuses first: the read's fault, as it stops there.
		return testing.expectf(t, g.at == e.offset && gread != nil, "%q %v step %d: read record %v (%v), want a fault at %d", c.src, c.framing, step, g, gread, e.offset)
	}
	return testing.expectf(t, !extra && got.err == want.err, "%q %v step %d: read err %v, want %v", c.src, c.framing, step, got.err, want.err)
}

// `records_from` and a pushed reader, read through `next_record` and through `next_record_open`, yield the records, offsets, judged faults and fault that `records` yields over
// the whole input, whatever the read sizes, for every framing, records longer than a chunk, and faults past the first window.
@(test)
test_records_from_agrees_with_records :: proc(t: ^testing.T) {
	long := strings.repeat("x", 300, context.temp_allocator)
	long_string := strings.concatenate({`{"s":"`, long, `"}`}, context.temp_allocator)
	cases := []Stream_Case {
		{"1\n\n {\"a\":2}\r\ntrue\n", .NDJSON, 0},
		{"\xEF\xBB\xBF1\n2", .NDJSON, 0},
		{"1\n\xEF\xBB\xBF2\n", .NDJSON, 0},
		{strings.concatenate({long_string, "\n", long_string, "\r\n[1,\n", long_string}, context.temp_allocator), .NDJSON, 0},
		{strings.concatenate({"1\n", long_string, "\ntru\n2\n"}, context.temp_allocator), .NDJSON, 0},
		{"[1]\n[2,\n", .NDJSON, 0},
		{"\x1e1\n\x1e[2]\n\x1e\x1e{\"a\":3}", .JSON_Seq, 0},
		{"\xEF\xBB\xBF \x1e1 \x1e2", .JSON_Seq, 0},
		{" x\x1e1\n", .JSON_Seq, 0},
		{"\x1e[1]]\n\x1e2\x1e3 ", .JSON_Seq, 0},
		{"\x1e \n \x1e\n", .JSON_Seq, 0},
		{strings.concatenate({"\x1e", long_string, "\n\x1e", long_string, "\n\x1enul\x1e[1]\n"}, context.temp_allocator), .JSON_Seq, 0},
		{"\x1e1\n\x1e\xEF\xBB\xBF2\n", .JSON_Seq, 0},
		{strings.concatenate({"\xEF\xBB\xBF \n", long_string, "\n"}, context.temp_allocator), .None, 0},
		{" \n ", .None, 0},
		{strings.concatenate({"[1, ", long_string, ", {\"a\": [2, 3]}]"}, context.temp_allocator), .Root_Entries, 0},
		{strings.concatenate({"{\"a\": 1, \"b\": ", long_string, "}"}, context.temp_allocator), .Root_Entries, 0},
		{"{\"a\" 1}", .Root_Entries, 0},
		{"tru", .Root_Entries, 0},
		// Texts across windows, pretty and packed, scalars cut by a read, faults past the first window.
		{strings.concatenate({"\xEF\xBB\xBF{\n  \"s\": ", long_string, ",\n  \"t\": [1,\n 2]\n}\n", long_string, long_string, "12 34\n\"x\\\\\" true"}, context.temp_allocator), .Concatenated, 0},
		{strings.concatenate({long_string, " nul[1] ", long_string, "]  [2,"}, context.temp_allocator), .Concatenated, 0},
		{strings.concatenate({"1 ", long_string, " \xEF\xBB\xBF2"}, context.temp_allocator), .Concatenated, 0},
		{strings.concatenate({"\"", long, "\\\"", long, "\" 1"}, context.temp_allocator), .Concatenated, 0},
		{" \n ", .Concatenated, 0},
		{strings.concatenate({"1 2 ", long_string, " 3"}, context.temp_allocator), .Concatenated, 100},
		{strings.concatenate({"[1]", strings.repeat(" ", 200, context.temp_allocator), "[", long, "]"}, context.temp_allocator), .Concatenated, 100},
		// Faults a read stops at before the text's brackets close it, stray closers, tokens a window cuts.
		{strings.concatenate({"{\"a\" 1, ", long_string, "} [2] ", long_string, "]] 3 [4}"}, context.temp_allocator), .Concatenated, 0},
		{strings.concatenate({"[1.5e3, -0.25, true, null, \"\\ud83d\\ude00\xe2\x82\xac\", ", long_string, "]\"", long, "\"{}"}, context.temp_allocator), .Concatenated, 0},
		{strings.concatenate({"[\"a\nb\", ", long_string, "] [5"}, context.temp_allocator), .Concatenated, 0},
		// Under a cap: a long line, blank or not, a long record, a long whole text, a long entry.
		{strings.concatenate({"1\n2\n", long_string, "\n3\n"}, context.temp_allocator), .NDJSON, 100},
		{strings.concatenate({"1\n", long, "\n2\n"}, context.temp_allocator), .NDJSON, 100},
		{strings.concatenate({"1\n", strings.repeat(" ", 200, context.temp_allocator), "\n2\n"}, context.temp_allocator), .NDJSON, 100},
		{"12345678\r\n1\n", .NDJSON, 8},
		{strings.concatenate({"\x1e1\n\x1e", long_string, "\x1e2\n"}, context.temp_allocator), .JSON_Seq, 100},
		{strings.concatenate({"\x1e1\n\x1e", strings.repeat(" ", 200, context.temp_allocator), "\x1e2\n"}, context.temp_allocator), .JSON_Seq, 100},
		{strings.concatenate({" x", long, "\x1e1\n"}, context.temp_allocator), .JSON_Seq, 100},
		{strings.concatenate({strings.repeat(" ", 200, context.temp_allocator), long_string}, context.temp_allocator), .None, 100},
		{strings.concatenate({strings.repeat(" ", 200, context.temp_allocator), "[1]"}, context.temp_allocator), .None, 100},
		{strings.concatenate({"[1, ", long_string, "]"}, context.temp_allocator), .Root_Entries, 100},
	}
	for c in cases {
		for step in ([]int{1, 2, 3, 7, 64, 130, 1 << 16}) {
			for eof_with_data in ([]bool{false, true}) {
				if !expect_stream_agrees(t, c, step, eof_with_data) || !expect_pushed_agrees(t, c, step, eof_with_data) || !expect_read_pushed_agrees(t, c, step, eof_with_data) {
					return
				}
			}
		}
	}
}

// A record longer than the default chunk is read whole, at its stream offset.
@(test)
test_records_from_reads_a_record_past_the_chunk :: proc(t: ^testing.T) {
	long := strings.repeat("x", 3 * 64 * 1024, context.temp_allocator)
	text := strings.concatenate({"1\n\"", long, "\"\n2\n"}, context.temp_allocator)
	tr := Trickle{src = transmute([]byte)text, step = 1 << 20}
	rr := json.records_from({procedure = trickle_proc, data = &tr}, {framing = .NDJSON})
	defer json.destroy(&rr)
	ats: [dynamic]u64
	defer delete(ats)
	for rec in json.next_record(&rr) {
		testing.expect_value(t, json.validate(rec.bytes), nil)
		append(&ats, rec.at)
	}
	testing.expect_value(t, len(ats), 3)
	testing.expect_value(t, ats[2], u64(len(text) - 2))
	testing.expect_value(t, rr.err, nil)
}

// The cap bounds the window: a line past it is refused at its first byte once the byte past the cap is read,
// without reading the rest of the line.
@(test)
test_records_from_bounds_the_window :: proc(t: ^testing.T) {
	text := strings.concatenate({"1\n", strings.repeat("x", 1 << 20, context.temp_allocator)}, context.temp_allocator)
	tr := Trickle{src = transmute([]byte)text, step = 4096}
	rr := json.records_from({procedure = trickle_proc, data = &tr}, {framing = .NDJSON, max_record_bytes = 1000})
	defer json.destroy(&rr)
	rr.chunk = 4096
	n := 0
	for _ in json.next_record(&rr) {
		n += 1
	}
	testing.expect_value(t, n, 1)
	testing.expect_value(t, rr.err, json.Error{kind = .Limit_Format, detail = u8(json.Fault.Record_Too_Long), offset = 2})
	testing.expect(t, tr.pos < 3 * 4096)
	window, _ := json.record_window(&rr)
	testing.expect(t, len(window) < 3 * 4096)
	bad := json.records_from({procedure = trickle_proc, data = &tr}, {max_record_bytes = -1})
	testing.expect_value(t, bad.err, json.Error{kind = .Bad_Option})
}

// A reader's failure ends the records: those framed whole before it are yielded, and the rest is no fault.
@(test)
test_records_from_reports_the_readers_failure :: proc(t: ^testing.T) {
	cases := []struct {
		src:     string,
		framing: json.Framing,
		records: int,
	} {
		{"1\n2\n[3,", .NDJSON, 2},
		{"1\n2", .NDJSON, 1},
		{"\x1e1\n\x1e[2,", .JSON_Seq, 1},
		{"[1, 2]", .Root_Entries, 0},
		{"[1]", .None, 0},
	}
	for c in cases {
		for step in ([]int{1, 3, 100}) {
			tr := Trickle{src = transmute([]byte)c.src, step = step, fail = .Unexpected_EOF}
			rr := json.records_from({procedure = trickle_proc, data = &tr}, {framing = c.framing})
			n := 0
			for _ in json.next_record(&rr) {
				n += 1
			}
			testing.expectf(t, n == c.records, "%q step %d: %d records, want %d", c.src, step, n, c.records)
			testing.expect_value(t, rr.err, nil)
			testing.expect_value(t, rr.read_err, io.Error.Unexpected_EOF)
			json.destroy(&rr)
		}
	}
}

// A typed read over a `Record_Reader` reads what one over the whole input's `Records` reads, and ends on the
// reader's failure with `.Truncated` at the end of what it gave.
@(test)
test_record_read_over_a_record_reader :: proc(t: ^testing.T) {
	Row :: struct {
		id: int,
	}
	text := "{\"id\":1}\n{\"id\":\"x\"}\n{\"id\":3}\n"
	tr := Trickle{src = transmute([]byte)text, step = 5}
	rr := json.records_from({procedure = trickle_proc, data = &tr}, {framing = .NDJSON})
	defer json.destroy(&rr)
	rd: json.Record_Read
	defer json.destroy(&rd)
	testing.expect_value(t, json.record_read_init(&rd, Row, &rr, allocator = context.temp_allocator), nil)
	ids: [dynamic]int
	defer delete(ids)
	refused := 0
	for {
		row: Row
		more, err := json.unmarshal(&rd, &row)
		if !more {
			testing.expect_value(t, err, nil)
			break
		}
		if err != nil {
			refused += 1
			testing.expect_value(t, json.record_read_at(&rd), 9)
			continue
		}
		append(&ids, row.id)
	}
	testing.expect_value(t, len(ids), 2)
	testing.expect_value(t, refused, 1)

	failing := Trickle{src = transmute([]byte)string("{\"id\":1}\n{\"id\""), step = 4, fail = .Unexpected_EOF}
	fr := json.records_from({procedure = trickle_proc, data = &failing}, {framing = .NDJSON})
	defer json.destroy(&fr)
	testing.expect_value(t, json.record_read_init(&rd, Row, &fr, allocator = context.temp_allocator), nil)
	row: Row
	more, err := json.unmarshal(&rd, &row)
	testing.expect(t, more && err == nil && row.id == 1)
	more, err = json.unmarshal(&rd, &row)
	testing.expect(t, !more)
	testing.expect_value(t, err, json.Unmarshal_Error{kind = .Syntax, syntax = .Truncated, offset = 14})
}
