package json_tests

import json "../.."
import "core:io"
import "core:strings"
import "core:testing"

// A reader that hands out at most `step` bytes a call, then fails with `fail` instead of ending if it is set,
// along with the last bytes as a reader may.
@(private = "file")
Trickle :: struct {
	src:  []byte,
	pos:  int,
	step: int,
	fail: io.Error,
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
		return i64(n), t.fail if t.pos == len(t.src) else nil
	case .Query:
		return io.query_utility({.Read, .Query})
	}
	return 0, .Unsupported
}

// For every read size, `records_from` yields the records, offsets and fault `records` yields over the whole.
@(test)
test_records_from_agrees_with_records_over_any_chunking :: proc(t: ^testing.T) {
	long := strings.repeat("x", 300, context.temp_allocator)
	corpus := []string{
		"", "\n", "1", "1\n\n {\"a\":2}\r\ntrue\n\r\n  \n\"s\"", "\xEF\xBB\xBF1\n2\n", "1\n\xEF\xBB\xBF2\n",
		strings.concatenate({"\"x\"\n", long, "\n", long}, context.temp_allocator),
		"\x1e", "\x1e\x1e \n\x1e", " \n\x1e1\n\x1e\x1e{\n \"a\": 2\n}\n", "\n x\x1e1\n",
		"\x1egarbage!!\x1e[2]\n\x1e1\n\x1e2\nx\x1e{\"a\":", "\x1e1\x1e2\n", "\x1e[1]\n\x1e -1.5e3", "\x1e1-\x1e",
		"\xEF\xBB\xBF\x1e1\n\x1e2\n", strings.concatenate({"\x1e", long, "\x1e\x1e", long, "\n"}, context.temp_allocator),
	}
	for text in corpus {
		src := transmute([]byte)text
		for framing in ([]json.Framing{.NDJSON, .JSON_Seq}) {
			for step in ([]int{1, 2, 3, 5, 64, 100000}) {
				want := json.records(src, framing)
				tr := Trickle{src = src, step = step}
				got := json.records_from({procedure = trickle_proc, data = &tr}, framing)
				got.chunk = 4
				defer json.destroy(&got)
				for w in json.next_record(&want) {
					g, ok := json.next_record(&got)
					testing.expectf(t, ok && string(g.bytes) == string(w.bytes) && g.at == w.at, "%q %v step %d: got %q at %d (%v), want %q at %d", text, framing, step, g.bytes, g.at, ok, w.bytes, w.at)
					if !ok {
						break
					}
				}
				_, extra := json.next_record(&got)
				testing.expectf(t, !extra && got.err == want.err && got.read_err == nil, "%q %v step %d: err %v %v, want %v", text, framing, step, got.err, got.read_err, want.err)
			}
		}
	}
}

@(test)
test_records_from_refuses_root_entries :: proc(t: ^testing.T) {
	tr := Trickle{src = transmute([]byte)string("[1,2]"), step = 1}
	it := json.records_from({procedure = trickle_proc, data = &tr}, .Root_Entries)
	_, ok := json.next_record(&it)
	testing.expect(t, !ok)
	testing.expect_value(t, it.err, json.Error{kind = .Bad_Option})
	testing.expect_value(t, tr.pos, 0)
}

@(test)
test_records_from_reports_the_readers_failure :: proc(t: ^testing.T) {
	tr := Trickle{src = transmute([]byte)string("1\n2\n3"), step = 3, fail = .Unexpected_EOF}
	it := json.records_from({procedure = trickle_proc, data = &tr}, .NDJSON)
	defer json.destroy(&it)
	n := 0
	for _ in json.next_record(&it) {
		n += 1
	}
	testing.expect_value(t, n, 2)
	testing.expect_value(t, it.read_err, io.Error.Unexpected_EOF)
	testing.expect(t, it.err == nil)

	// The failing read handed over every byte: its whole records still come first.
	whole := Trickle{src = transmute([]byte)string("1\n2\n3"), step = 100, fail = .Unexpected_EOF}
	at_once := json.records_from({procedure = trickle_proc, data = &whole}, .NDJSON)
	defer json.destroy(&at_once)
	n = 0
	for _ in json.next_record(&at_once) {
		n += 1
	}
	testing.expect_value(t, n, 2)
	testing.expect_value(t, at_once.read_err, io.Error.Unexpected_EOF)
}
