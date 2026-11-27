package write_tests

import "base:runtime"
import "core:bytes"
import "core:io"
import "core:mem"
import "core:testing"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/ops/write"
import "stury:testkit"

// The output a writer spells into: a buffer that grows without losing a byte, a sink that takes the text in pieces of
// its buffer, and the errors of a sink or an allocator that refuses.

// What `pieces_writer` writes: `count` pieces of `size` bytes, each `i % 251` repeated, through `room`.
@(private = "file")
Pieces :: struct {
	count, size: int,
	ran:         bool,
}

@(private = "file")
pieces_writer :: proc(out: ^write.Out, doc: ^tape.Document, spec: u8, opts: write.Options, allocator: runtime.Allocator) -> (tape.Facts, write.Error) {
	p := (^Pieces)(context.user_ptr)
	p.ran = true
	for i in 0 ..< p.count {
		at := write.room(out, p.size)
		for j in 0 ..< p.size {
			at[j] = u8(i % 251)
		}
		out.cursor += p.size
	}
	return {}, nil
}

@(private = "file")
pieces_match :: proc(data: []u8, count, size: int) -> bool {
	if len(data) != count * size {
		return false
	}
	for i in 0 ..< count {
		for j in 0 ..< size {
			if data[i * size + j] != u8(i % 251) {
				return false
			}
		}
	}
	return true
}

// A document to hand the writers, which `to_buffer` reads the length of to size its buffer.
@(private = "file")
tiny_doc :: proc() -> json.Document {
	doc, _ := json.build(transmute([]u8)string("null"))
	return doc
}

// A sink that records the bytes it is given and the sizes of its writes, and takes at most `room` bytes in all and
// `per_write` in one call, naming no error for a short take unless `names_error`.
@(private = "file")
Recorder :: struct {
	took:        [dynamic]u8,
	writes:      int,
	biggest:     int,
	room:        int,
	per_write:   int,
	names_error: bool,
}

@(private = "file")
recorder_sink :: proc(r: ^Recorder) -> io.Writer {
	return io.Stream {
		data = r,
		procedure = proc(data: rawptr, mode: io.Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From) -> (i64, io.Error) {
			r := (^Recorder)(data)
			if mode != .Write {
				return 0, .Empty
			}
			r.writes += 1
			r.biggest = max(r.biggest, len(p))
			n := min(len(p), r.room - len(r.took), r.per_write)
			append(&r.took, ..p[:n])
			return i64(n), .Short_Write if n < len(p) && r.names_error else nil
		},
	}
}

@(private = "file")
unlimited :: proc() -> Recorder {
	return {room = max(int), per_write = max(int)}
}

// A buffer output that runs past its first allocation keeps every byte, whatever the piece size.
@(test)
out_buffer_grows_and_keeps_every_byte :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc := tiny_doc()
	defer json.destroy(&doc)
	for size in ([]int{1, 7, 100, 4095, write.ROOM_MAX}) {
		pieces := Pieces{count = 300_000 / size, size = size}
		context.user_ptr = &pieces
		text, _, err := write.to_buffer(&doc, 0, {}, context.allocator, pieces_writer)
		defer delete(text)
		testing.expect_value(t, err, nil)
		testing.expectf(t, pieces_match(text, pieces.count, size), "pieces of %d bytes", size)
	}
}

// A byte slice of any length is written whole: through the ROOM_MAX of one room and past it, into a buffer and into
// a sink.
@(test)
out_long_puts_keep_every_byte :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc := tiny_doc()
	defer json.destroy(&doc)
	lengths := [?]int{0, 1, write.ROOM_MAX - 1, write.ROOM_MAX, write.ROOM_MAX + 1, 3 * write.ROOM_MAX, write.SINK_BYTES - 1, write.SINK_BYTES, write.SINK_BYTES + 1, 300_001}
	for n in lengths {
		piece := make([]u8, n)
		defer delete(piece)
		for &b, i in piece {
			b = u8(i * 31)
		}
		Put :: struct {
			piece: []u8,
		}
		put := Put{piece}
		writer :: proc(out: ^write.Out, doc: ^tape.Document, spec: u8, opts: write.Options, allocator: runtime.Allocator) -> (tape.Facts, write.Error) {
			piece := (^Put)(context.user_ptr).piece
			write.put_byte(out, '<')
			write.put(out, piece)
			write.put(out, piece)
			write.put_byte(out, '>')
			return {}, nil
		}
		context.user_ptr = &put
		want := make([dynamic]u8)
		defer delete(want)
		append(&want, '<')
		append(&want, ..piece)
		append(&want, ..piece)
		append(&want, '>')
		text, _, err := write.to_buffer(&doc, 0, {}, context.allocator, writer)
		defer delete(text)
		testing.expectf(t, err == nil && string(text) == string(want[:]), "%d bytes into a buffer: %v", n, err)
		sink := unlimited()
		defer delete(sink.took)
		_, serr := write.to_sink(recorder_sink(&sink), &doc, 0, {}, context.allocator, writer)
		testing.expectf(t, serr == nil && string(sink.took[:]) == string(want[:]), "%d bytes into a sink: %v", n, serr)
	}
}

// A sink is written in pieces no larger than its buffer when the text is longer than it, and holds the whole text
// after the end.
@(test)
out_sink_takes_the_text_in_pieces :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc := tiny_doc()
	defer json.destroy(&doc)
	pieces := Pieces{count = 3000, size = 100}
	context.user_ptr = &pieces
	sink := unlimited()
	defer delete(sink.took)
	_, err := write.to_sink(recorder_sink(&sink), &doc, 0, {}, context.allocator, pieces_writer)
	testing.expect_value(t, err, nil)
	testing.expectf(t, sink.writes > 1 && sink.biggest <= write.SINK_BYTES, "%d writes, the biggest of %d bytes", sink.writes, sink.biggest)
	testing.expect(t, pieces_match(sink.took[:], 3000, 100))
}

// A text that fits the buffer of a sink is written once, at the end, and an empty text is not written at all.
@(test)
out_sink_writes_a_short_text_once :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc := tiny_doc()
	defer json.destroy(&doc)
	pieces := Pieces{count = 5, size = 100}
	context.user_ptr = &pieces
	sink := unlimited()
	defer delete(sink.took)
	_, err := write.to_sink(recorder_sink(&sink), &doc, 0, {}, context.allocator, pieces_writer)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, sink.writes, 1)
	testing.expect(t, pieces_match(sink.took[:], 5, 100))
	empty := Pieces{}
	context.user_ptr = &empty
	none := unlimited()
	defer delete(none.took)
	_, err = write.to_sink(recorder_sink(&none), &doc, 0, {}, context.allocator, pieces_writer)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, none.writes, 0)
}

// A sink that refuses part of the text — mid-stream or on the final flush — leaves the prefix it took and reports its error.
@(test)
out_failing_sink_reports_error_and_keeps_prefix :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc := tiny_doc()
	defer json.destroy(&doc)
	for tc in ([]struct { count, size, room, want_pieces: int }{
		{3000, 100, 100_000, 1000},
		{1, 50, 10, 0},
	}) {
		pieces := Pieces{count = tc.count, size = tc.size}
		context.user_ptr = &pieces
		sink := Recorder{room = tc.room, per_write = max(int), names_error = true}
		defer delete(sink.took)
		_, err := write.to_sink(recorder_sink(&sink), &doc, 0, {}, context.allocator, pieces_writer)
		testing.expect_value(t, err, write.Error(io.Error.Short_Write))
		testing.expect_value(t, len(sink.took), tc.room)
		if tc.want_pieces > 0 {
			testing.expect(t, pieces_match(sink.took[:], tc.want_pieces, tc.size))
		}
	}
}

// A sink that names no error and takes nothing is a short write, and one that takes a few bytes at a time is written
// again from where it stopped until it has the whole text.
@(test)
out_silent_sinks :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc := tiny_doc()
	defer json.destroy(&doc)
	pieces := Pieces{count = 1, size = 50}
	context.user_ptr = &pieces
	nothing := Recorder{room = max(int), per_write = 0}
	defer delete(nothing.took)
	_, err := write.to_sink(recorder_sink(&nothing), &doc, 0, {}, context.allocator, pieces_writer)
	testing.expect_value(t, err, write.Error(io.Error.Short_Write))
	testing.expect_value(t, nothing.writes, 1)
	trickle := Recorder{room = max(int), per_write = 7}
	defer delete(trickle.took)
	_, err = write.to_sink(recorder_sink(&trickle), &doc, 0, {}, context.allocator, pieces_writer)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, trickle.writes, 8)
	testing.expect(t, pieces_match(trickle.took[:], 1, 50))
	// And through a text of many buffers.
	many := Pieces{count = 3000, size = 100}
	context.user_ptr = &many
	slow := Recorder{room = max(int), per_write = 4001}
	defer delete(slow.took)
	_, err = write.to_sink(recorder_sink(&slow), &doc, 0, {}, context.allocator, pieces_writer)
	testing.expect_value(t, err, nil)
	testing.expect(t, pieces_match(slow.took[:], 3000, 100))
}

// A sink that says it took more than it was given is `Invalid_Write`, and a sink with no procedure is refused before
// the writer runs.
@(test)
out_sink_refusals :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc := tiny_doc()
	defer json.destroy(&doc)
	pieces := Pieces{count = 3000, size = 100}
	context.user_ptr = &pieces
	boasting := io.Stream {
		procedure = proc(data: rawptr, mode: io.Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From) -> (i64, io.Error) {
			return i64(len(p)) + 1, nil
		},
	}
	_, err := write.to_sink(boasting, &doc, 0, {}, context.allocator, pieces_writer)
	testing.expect_value(t, err, write.Error(io.Error.Invalid_Write))
	pieces.ran = false
	_, err = write.to_sink({}, &doc, 0, {}, context.allocator, pieces_writer)
	testing.expect_value(t, err, write.Error(tape.Bad_Option{"sink"}))
	testing.expect(t, !pieces.ran)
}

// An allocator that refuses the buffer's growth gives no text and its error, and one that refuses the first block
// gives its error before the writer runs.
@(test)
out_refused_allocation_gives_no_bytes :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc := tiny_doc()
	defer json.destroy(&doc)
	storage: [8192]u8
	arena: mem.Arena
	mem.arena_init(&arena, storage[:])
	pieces := Pieces{count = 1000, size = 100}
	context.user_ptr = &pieces
	text, _, err := write.to_buffer(&doc, 0, {}, mem.arena_allocator(&arena), pieces_writer)
	testing.expect(t, text == nil)
	_, refused := err.(runtime.Allocator_Error)
	testing.expectf(t, refused, "%v", err)
	pieces.ran = false
	f := testkit.Failing{backing = context.allocator, fail_at = 0}
	text, _, err = write.to_buffer(&doc, 0, {}, testkit.failing_allocator(&f), pieces_writer)
	testing.expect_value(t, err, write.Error(runtime.Allocator_Error.Out_Of_Memory))
	testing.expect(t, text == nil && !pieces.ran)
	f = {backing = context.allocator, fail_at = 0}
	unused := unlimited()
	_, err = write.to_sink(recorder_sink(&unused), &doc, 0, {}, testkit.failing_allocator(&f), pieces_writer)
	testing.expect_value(t, err, write.Error(runtime.Allocator_Error.Out_Of_Memory))
	testing.expect(t, !pieces.ran)
}

// Every allocation a buffer or a sink output makes may be refused: the write gives its error and keeps no block.
@(test)
out_refusals_free_every_block :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc := tiny_doc()
	defer json.destroy(&doc)
	pieces := Pieces{count = 3000, size = 100}
	context.user_ptr = &pieces
	Run :: struct {
		doc:  ^json.Document,
		sink: bool,
	}
	for sink in ([]bool{false, true}) {
		run := Run{&doc, sink}
		s := testkit.sweep_failures(proc(data: rawptr, a: runtime.Allocator) {
				r := (^Run)(data)
				if r.sink {
					recorded := Recorder{room = max(int), per_write = max(int)}
					defer delete(recorded.took)
					_, err := write.to_sink(recorder_sink(&recorded), r.doc, 0, {}, a, pieces_writer)
					if err != nil {
						_ = err.(runtime.Allocator_Error)
					}
				} else {
					text, _, err := write.to_buffer(r.doc, 0, {}, a, pieces_writer)
					if err == nil {
						delete(text, a)
					} else {
						_ = err.(runtime.Allocator_Error)
					}
				}
			}, &run)
		testing.expectf(t, s.bad == 0 && s.refused >= 1, "sink %v: %v", sink, s)
	}
}

// The bytes a buffer output returns are the sink's bytes: a sink over a `bytes.Buffer` gets what a buffer write gives.
@(test)
out_sink_and_buffer_agree :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc := tiny_doc()
	defer json.destroy(&doc)
	pieces := Pieces{count = 1500, size = 333}
	context.user_ptr = &pieces
	text, _, err := write.to_buffer(&doc, 0, {}, context.allocator, pieces_writer)
	defer delete(text)
	testing.expect_value(t, err, nil)
	sink: bytes.Buffer
	defer bytes.buffer_destroy(&sink)
	_, serr := write.to_sink(bytes.buffer_to_stream(&sink), &doc, 0, {}, context.allocator, pieces_writer)
	testing.expect_value(t, serr, nil)
	testing.expect(t, string(bytes.buffer_to_bytes(&sink)) == string(text))
}

@(test)
out_empty_buffer_finish_and_compact_and_size_hint :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// P9: `out_finish` on 0-byte buffer write frees its backing block and returns `nil, nil`.
	out: write.Out
	testing.expect_value(t, write.out_start(&out, context.allocator, {}, write.ROOM_MAX), nil)
	text, err := write.out_finish(&out)
	testing.expect_value(t, err, nil)
	testing.expect(t, text == nil && len(text) == 0)
	// Safe to call `out_drop` after `out_finish` because `out^` was zeroed.
	write.out_drop(&out)

	// P9: `out_start` with zero or nil allocator fails cleanly with `.Out_Of_Memory`.
	for bad in ([?]runtime.Allocator{{}, mem.nil_allocator()}) {
		o: write.Out
		testing.expect_value(t, write.out_start(&o, bad, {}, write.ROOM_MAX), runtime.Allocator_Error.Out_Of_Memory)
	}

	// P11: `compact` combinations.
	testing.expect(t, write.compact({}))
	testing.expect(t, !write.compact({indent = 2}))
	testing.expect(t, !write.compact({tab = true}))
	testing.expect(t, !write.compact({indent = 2, tab = true}))

	// P11: `opts.node != ROOT`, `tape.NO_NODE`, and `indent = 255`.
	doc, berr := json.build(transmute([]u8)string(`{"a":[1,2,3],"b":"leaf"}`))
	defer json.destroy(&doc)
	testing.expect_value(t, berr, nil)
	leaf, p := json.member({&doc, nil}, json.ROOT, "b")
	testing.expect_value(t, p, tape.Presence.Found)
	sub, _, serr := json.write(&doc, .Json, {node = leaf})
	defer delete(sub)
	testing.expectf(t, serr == nil && string(sub) == `"leaf"`, "subtree write: %q %v", sub, serr)
	_, _, no_err := json.write(&doc, .Json, {node = tape.NO_NODE})
	testing.expect_value(t, no_err, json.Write_Error(tape.Bad_Option{"node"}))
	big_ind, _, ierr := json.write(&doc, .Json, {indent = 255})
	defer delete(big_ind)
	testing.expect_value(t, ierr, nil)
}
