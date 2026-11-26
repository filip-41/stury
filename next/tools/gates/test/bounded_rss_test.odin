package gates_tests

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:strconv"
import "core:testing"
import "stury:jq"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/query"
import "stury:testkit"

// Target NDJSON stream size in MiB (defaults to 64 MiB per goals.md §5; override with `-define:RSS_GATE_MB=N`).
RSS_GATE_MB: int : #config(RSS_GATE_MB, 64)

// Hard upper bound on peak heap and RSS delta for streaming evaluation over the full stream (goals.md §5: < 11 MiB).
@(private = "file")
RSS_BOUND_BYTES :: u64(11 << 20)

// Process-wide OS `ru_maxrss` (`RUSAGE_SELF`) reflects concurrent test threads (such as 100k-depth tests) and
// sanitizer shadow mappings. Assert OS `ru_maxrss` deterministically when running single-threaded without sanitizers
// (`-define:ODIN_TEST_THREADS=1`); `Tracking_Allocator` peak heap and `query.Heap`'s 11 MiB budget ALWAYS assert.
@(private = "file")
CHECK_OS_MAXRSS :: #config(ODIN_TEST_THREADS, 0) == 1 && ODIN_SANITIZER_FLAGS == {}

@(private = "file")
FOREACH_MILESTONE :: u64(16_384)

@(private = "file")
STREAM_WINDOW_BYTES :: 64 << 10

// Fixed-width 512-byte realistic NDJSON event record generator.
// Streams `target_bytes` through a single reusable 64 KiB window without ever materializing the stream in RAM.
@(private = "file")
RECORD_PAD :: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456"

@(private = "file")
Ndjson_Stream :: struct {
	target_bytes:         u64,
	emitted_bytes:        u64,
	emitted_records:      u64,
	expected_sum:         i64,
	milestone_n:          u64,
	milestone_sum:        i64,
	window:               []u8,
	wlen:                 int,
	pieces:               tape.Pieces,
	recs:                 json.Records,
	alloc:                runtime.Allocator,
	batch:                [32]tape.Record,
	batch_len:            int,
	batch_pos:            int,
	eof:                  bool,
	line_buf:             [640]u8,
	line_pos:             int,
	line_len:             int,
}

@(private = "file")
ndjson_fill_line :: proc(s: ^Ndjson_Stream) -> bool {
	if s.emitted_bytes >= s.target_bytes {
		return false
	}
	id := s.emitted_records + 1
	val := i64((id * 7) % 100) + 1
	s.emitted_records += 1
	s.expected_sum += val
	if s.emitted_records % FOREACH_MILESTONE == 0 {
		s.milestone_n = s.emitted_records
		s.milestone_sum = s.expected_sum
	}
	line := fmt.bprintf(
		s.line_buf[:],
		`{{"id":%d,"svc":"ingest","ok":true,"val":%d,"pad":"%s"}}` + "\n",
		id + 10_000_000,
		val,
		RECORD_PAD,
	)
	s.line_pos = 0
	s.line_len = len(line)
	s.emitted_bytes += u64(len(line))
	return true
}

@(private = "file")
ndjson_fill_window :: proc(s: ^Ndjson_Stream, start: int) -> int {
	pos := start
	for pos < len(s.window) {
		if s.line_pos >= s.line_len {
			if !ndjson_fill_line(s) {
				break
			}
		}
		avail := s.line_len - s.line_pos
		space := len(s.window) - pos
		n := min(avail, space)
		copy(s.window[pos:pos + n], s.line_buf[s.line_pos:s.line_pos + n])
		pos += n
		s.line_pos += n
	}
	return pos
}

@(private = "file")
ndjson_stream_init :: proc(s: ^Ndjson_Stream, target_bytes: u64, alloc: runtime.Allocator) {
	s^ = {
		target_bytes = target_bytes,
		alloc        = alloc,
		window       = make([]u8, STREAM_WINDOW_BYTES, alloc),
	}
	s.wlen = ndjson_fill_window(s, 0)
	done := s.emitted_bytes >= s.target_bytes && s.line_pos >= s.line_len
	s.pieces = tape.Pieces{
		from      = 0,
		last      = done,
		allocator = alloc,
	}
	s.recs = json.records_open(s.window[:s.wlen], .Lines, .Json, {pieces = &s.pieces})
}

@(private = "file")
ndjson_stream_destroy :: proc(s: ^Ndjson_Stream) {
	tape.destroy_records(&s.recs)
	tape.destroy(&s.pieces)
	delete(s.window, s.alloc)
	s^ = {}
}

@(private = "file")
ndjson_stream_refill :: proc(s: ^Ndjson_Stream) -> bool {
	if !s.pieces.more {
		s.eof = true
		return false
	}
	keep_off := int(s.pieces.keep - s.pieces.from)
	kept := s.wlen - keep_off
	if kept > 0 && keep_off > 0 {
		copy(s.window[:kept], s.window[keep_off:s.wlen])
	}
	s.wlen = ndjson_fill_window(s, kept)
	done := s.emitted_bytes >= s.target_bytes && s.line_pos >= s.line_len
	s.pieces.from = s.pieces.keep
	s.pieces.last = done
	if tape.records_window(&s.recs, s.window[:s.wlen]) != nil {
		s.eof = true
		return false
	}
	return true
}

// `jq.Hooks.input` callback pulling one JSON record lazily from the 64 KiB-windowed NDJSON stream.
// Each record document is owned by the emitted `query.Value` and freed immediately once `reduce`/`foreach` moves on.
@(private = "file")
ndjson_jq_input_hook :: proc(data: rawptr, h: ^query.Heap) -> (v: query.Value, ok: bool, status: query.Status) {
	s := (^Ndjson_Stream)(data)
	for {
		if s.batch_pos < s.batch_len {
			rec := s.batch[s.batch_pos]
			s.batch_pos += 1
			if rec.err != nil {
				return query.NULL, false, query.fail(h, .Parse, .None, query.text_borrowed("bad NDJSON record"))
			}
			lo := int(rec.lo - s.pieces.from)
			hi := int(rec.hi - s.pieces.from)
			raw := s.window[lo:hi]
			// Clone only this single ~512-byte line into `h.allocator`; `tape.destroy_document` frees it via `.Owns_Src`.
			owned_src, aerr := make([]u8, len(raw), h.allocator)
			if aerr != nil {
				return query.NULL, false, query.fail(h, .Memory, .None, query.text_borrowed("out of memory"))
			}
			copy(owned_src, raw)
			doc, berr := json.build(owned_src, .Json, {}, h.allocator)
			if berr != nil {
				delete(owned_src, h.allocator)
				return query.NULL, false, query.fail(h, .Parse, .None, query.text_borrowed("parse error"))
			}
			doc.flags += {.Owns_Src}
			val, st := query.document_value(h, doc, owned = true)
			if st != .Ok {
				// `document_value` destroys `doc` (and `owned_src`) on failure when `owned = true`.
				return query.NULL, false, st
			}
			return val, true, .Ok
		}

		if s.eof {
			return query.NULL, false, .Ok
		}

		// Use `records_find` with empty path (root) to frame one batch of up to 32 records in the current window.
		answers: [32]tape.Span_Answer
		n := json.records_find(&s.recs, nil, s.batch[:], answers[:], {}, s.alloc)
		if n > 0 {
			s.batch_len = n
			s.batch_pos = 0
			continue
		}
		if !ndjson_stream_refill(s) {
			return query.NULL, false, .Ok
		}
	}
}

@(private = "file")
Stream_Out :: struct {
	h:     ^query.Heap,
	count: int,
	last:  [dynamic]u8,
}

@(private = "file")
stream_out_cb :: proc(data: rawptr, v: query.Value, h: ^query.Heap) -> bool {
	o := (^Stream_Out)(data)
	defer query.release(h, v)
	clear(&o.last)
	if query.write_json(h, &o.last, v) != .Ok {
		return false
	}
	o.count += 1
	return true
}

@(private = "file")
run_bounded_jq_stream :: proc(
	t: ^testing.T,
	label: string,
	filter: string,
	target_bytes: u64,
	expect_count: proc(s: ^Ndjson_Stream) -> int,
	expect_json: proc(s: ^Ndjson_Stream, buf: []u8) -> string,
) {
	prog, cerrs := jq.compile(filter)
	defer jq.destroy_program(prog)
	testing.expect_value(t, len(cerrs), 0)
	if len(cerrs) != 0 {
		return
	}

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, runtime.heap_allocator())
	defer mem.tracking_allocator_destroy(&track)
	talloc := mem.tracking_allocator(&track)

	rss_before := max_rss_bytes()

	stream: Ndjson_Stream
	ndjson_stream_init(&stream, target_bytes, talloc)

	h: query.Heap
	query.heap_init(&h, talloc, RSS_BOUND_BYTES)

	hooks := jq.Hooks{
		data  = &stream,
		input = ndjson_jq_input_hook,
	}
	run: jq.Run
	jq.run_init(&run, prog, &h, nil, &hooks)

	out := Stream_Out{
		h    = &h,
		last = make([dynamic]u8, 0, 128, talloc),
	}

	end := jq.run_value(&run, query.NULL, stream_out_cb, &out)
	testing.expect_value(t, end, jq.Run_End.Done)
	testing.expect_value(t, stream.recs.err, tape.Error(nil))
	testing.expect(t, stream.emitted_bytes >= target_bytes)

	want_outputs := expect_count(&stream)
	testing.expect(t, want_outputs > 0)
	testing.expect_value(t, out.count, want_outputs)

	want_buf: [128]u8
	want := expect_json(&stream, want_buf[:])
	testing.expect_value(t, string(out.last[:]), want)

	rss_after := max_rss_bytes()
	rss_delta := rss_after - rss_before if rss_after > rss_before else u64(0)
	peak_heap := u64(track.peak_memory_allocated)
	emitted_records := stream.emitted_records

	// Destroy all streaming structures before checking leak balance.
	delete(out.last)
	jq.run_destroy(&run)
	testing.expect_value(t, query.heap_live(&h), 0)
	query.heap_destroy(&h)
	ndjson_stream_destroy(&stream)

	log.infof(
		"[bounded_rss:%s] streamed=%d MiB (%d records) peak_heap=%d KiB rss_delta=%d KiB check_os_rss=%v",
		label,
		target_bytes >> 20,
		emitted_records,
		peak_heap >> 10,
		rss_delta >> 10,
		CHECK_OS_MAXRSS,
	)

	testing.expectf(
		t,
		peak_heap < RSS_BOUND_BYTES,
		"%s peak heap %d bytes exceeded %d byte bound",
		label,
		peak_heap,
		RSS_BOUND_BYTES,
	)
	when CHECK_OS_MAXRSS {
		if rss_before > 0 && rss_after > 0 {
			testing.expectf(
				t,
				rss_delta < RSS_BOUND_BYTES,
				"%s RSS delta %d bytes exceeded %d byte bound",
				label,
				rss_delta,
				RSS_BOUND_BYTES,
			)
		}
	}
	testing.expect_value(t, track.current_memory_allocated, 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
}

@(test)
gate_bounded_rss_records_stream_64mb :: proc(t: ^testing.T) {
	testkit.deadline(t)

	target := u64(max(RSS_GATE_MB, 1)) << 20

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, runtime.heap_allocator())
	defer mem.tracking_allocator_destroy(&track)
	talloc := mem.tracking_allocator(&track)

	rss_before := max_rss_bytes()

	stream: Ndjson_Stream
	ndjson_stream_init(&stream, target, talloc)

	path_val := [1]tape.Step{tape.Name("val")}
	out_recs: [32]tape.Record
	answers: [32]tape.Span_Answer
	total_count: u64 = 0
	total_sum: i64 = 0

	for {
		n := json.records_find(&stream.recs, path_val[:], out_recs[:], answers[:], {}, talloc)
		for i in 0 ..< n {
			testing.expect_value(t, out_recs[i].err, tape.Error(nil))
			testing.expect_value(t, answers[i].outcome, tape.Presence.Found)
			lo := int(answers[i].lo - stream.pieces.from)
			hi := int(answers[i].hi - stream.pieces.from)
			v, ok := strconv.parse_i64_of_base(string(stream.window[lo:hi]), 10)
			testing.expect(t, ok)
			total_sum += v
			total_count += 1
		}
		if n < len(out_recs) {
			if !ndjson_stream_refill(&stream) {
				break
			}
		}
	}

	rss_after := max_rss_bytes()
	rss_delta := rss_after - rss_before if rss_after > rss_before else u64(0)
	peak_heap := u64(track.peak_memory_allocated)

	testing.expect_value(t, stream.recs.err, tape.Error(nil))
	testing.expect_value(t, total_count, stream.emitted_records)
	testing.expect_value(t, total_sum, stream.expected_sum)

	ndjson_stream_destroy(&stream)

	log.infof(
		"[bounded_rss:records_find] streamed=%d MiB (%d records) peak_heap=%d KiB rss_delta=%d KiB check_os_rss=%v",
		target >> 20,
		total_count,
		peak_heap >> 10,
		rss_delta >> 10,
		CHECK_OS_MAXRSS,
	)

	testing.expectf(t, peak_heap < RSS_BOUND_BYTES, "records_find peak heap %d >= %d", peak_heap, RSS_BOUND_BYTES)
	when CHECK_OS_MAXRSS {
		if rss_before > 0 && rss_after > 0 {
			testing.expectf(t, rss_delta < RSS_BOUND_BYTES, "records_find RSS delta %d >= %d", rss_delta, RSS_BOUND_BYTES)
		}
	}
	testing.expect_value(t, track.current_memory_allocated, 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
}

@(test)
gate_bounded_rss_jq_reduce_inputs_64mb :: proc(t: ^testing.T) {
	testkit.deadline(t)
	target := u64(max(RSS_GATE_MB, 1)) << 20
	run_bounded_jq_stream(
		t,
		"jq_reduce_inputs",
		`reduce inputs as $r ({n: 0, sum: 0}; .n += 1 | .sum += $r.val)`,
		target,
		proc(_: ^Ndjson_Stream) -> int {
			return 1
		},
		proc(s: ^Ndjson_Stream, buf: []u8) -> string {
			return fmt.bprintf(buf, `{{"n":%d,"sum":%d}}`, s.emitted_records, s.expected_sum)
		},
	)
}

@(test)
gate_bounded_rss_jq_foreach_inputs_64mb :: proc(t: ^testing.T) {
	testkit.deadline(t)
	target := u64(max(RSS_GATE_MB, 1)) << 20
	run_bounded_jq_stream(
		t,
		"jq_foreach_inputs",
		`foreach inputs as $r ({n: 0, sum: 0}; .n += 1 | .sum += $r.val; if .n % 16384 == 0 then . else empty end)`,
		target,
		proc(s: ^Ndjson_Stream) -> int {
			return int(s.emitted_records / FOREACH_MILESTONE)
		},
		proc(s: ^Ndjson_Stream, buf: []u8) -> string {
			return fmt.bprintf(buf, `{{"n":%d,"sum":%d}}`, s.milestone_n, s.milestone_sum)
		},
	)
}
