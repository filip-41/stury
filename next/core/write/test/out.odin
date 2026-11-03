package write_test

import "core:bytes"
import "core:io"
import "core:mem"
import "core:strings"
import "core:testing"
import core "../.."
import write ".."

// Writes `count` pieces of `size` bytes, each `i % 251` repeated, through `room`.
put_pieces :: proc(out: ^write.Out, count, size: int) {
	for i in 0 ..< count {
		p := write.room(out, size)
		for j in 0 ..< size {
			p[j] = u8(i % 251)
		}
		out.cursor += size
	}
}

// Whether `data` is what `put_pieces` writes.
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

@(test)
buffer_grows_and_keeps_every_byte :: proc(t: ^testing.T) {
	spill: [write.ROOM_MAX]u8 = ---
	out: write.Out
	write.init(&out, &spill)
	put_pieces(&out, 3000, 100)
	data, err := write.finish(&out)
	defer delete(data)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.None)
	testing.expect(t, pieces_match(data, 3000, 100))
}

@(test)
empty_output_finishes_with_no_bytes :: proc(t: ^testing.T) {
	spill: [write.ROOM_MAX]u8 = ---
	out: write.Out
	write.init(&out, &spill)
	data, err := write.finish(&out)
	testing.expect_value(t, len(data), 0)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.None)
}

@(test)
stream_flushes_when_the_buffer_fills :: proc(t: ^testing.T) {
	sink: bytes.Buffer
	defer bytes.buffer_destroy(&sink)
	spill: [write.ROOM_MAX]u8 = ---
	out: write.Out
	write.init(&out, &spill, stream = bytes.buffer_to_stream(&sink))
	put_pieces(&out, 3000, 100)
	testing.expect(t, bytes.buffer_length(&sink) > 0, "nothing flushed before finish")
	testing.expect(t, out.size == write.STREAM_BUFFER, "a stream output grew its buffer")
	data, err := write.finish(&out)
	testing.expect_value(t, len(data), 0)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.None)
	testing.expect(t, pieces_match(bytes.buffer_to_bytes(&sink), 3000, 100))
	testing.expect_value(t, out.flushed, 300_000)
}

// A stream that takes `room` bytes in all and then refuses.
Limited :: struct {
	room: int,
	took: [dynamic]u8,
}

limited_stream :: proc(l: ^Limited) -> io.Stream {
	return {
		procedure = proc(data: rawptr, mode: io.Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From) -> (i64, io.Error) {
			l := (^Limited)(data)
			if mode != .Write {
				return 0, .Empty
			}
			n := min(len(p), l.room - len(l.took))
			append(&l.took, ..p[:n])
			return i64(n), nil if n == len(p) else .Short_Write
		},
		data = l,
	}
}

@(test)
failing_stream_leaves_a_prefix_and_reports_write_failed :: proc(t: ^testing.T) {
	l := Limited{room = 100_000}
	defer delete(l.took)
	spill: [write.ROOM_MAX]u8 = ---
	out: write.Out
	write.init(&out, &spill, stream = limited_stream(&l))
	put_pieces(&out, 3000, 100)
	testing.expect_value(t, out.err, core.Typed_Error_Kind.Write_Failed)
	data, err := write.finish(&out)
	testing.expect_value(t, len(data), 0)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.Write_Failed)
	testing.expect_value(t, err.cause, io.Error.Short_Write)
	testing.expect_value(t, len(l.took), 100_000)
	testing.expect(t, pieces_match(l.took[:], 1000, 100))
}

@(test)
stream_refusing_the_final_flush_is_reported :: proc(t: ^testing.T) {
	l := Limited{room = 10}
	defer delete(l.took)
	spill: [write.ROOM_MAX]u8 = ---
	out: write.Out
	write.init(&out, &spill, stream = limited_stream(&l))
	put_pieces(&out, 1, 50)
	_, err := write.finish(&out)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.Write_Failed)
	testing.expect_value(t, err.cause, io.Error.Short_Write)
	testing.expect_value(t, len(l.took), 10)
}

// A stream that takes fewer bytes than it was given and names no error.
silent_stream :: proc() -> io.Stream {
	return {
		procedure = proc(data: rawptr, mode: io.Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From) -> (i64, io.Error) {
			return 1 if mode == .Write else 0, nil if mode == .Write else .Empty
		},
	}
}

@(test)
stream_taking_fewer_bytes_with_no_error_is_a_short_write :: proc(t: ^testing.T) {
	spill: [write.ROOM_MAX]u8 = ---
	out: write.Out
	write.init(&out, &spill, stream = silent_stream())
	put_pieces(&out, 1, 50)
	_, err := write.finish(&out)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.Write_Failed)
	testing.expect_value(t, err.cause, io.Error.Short_Write)
}

@(test)
refused_allocation_gives_no_bytes :: proc(t: ^testing.T) {
	storage: [8192]u8
	arena: mem.Arena
	mem.arena_init(&arena, storage[:])
	spill: [write.ROOM_MAX]u8 = ---
	out: write.Out
	write.init(&out, &spill, mem.arena_allocator(&arena))
	put_pieces(&out, 1000, 100)
	data, err := write.finish(&out)
	testing.expect(t, data == nil)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.Out_Of_Memory)
}

@(test)
write_kinds_render_without_a_position :: proc(t: ^testing.T) {
	kinds := [?]struct {
		kind:    core.Typed_Error_Kind,
		code:    string,
		message: string,
	} {
		{.Bad_Utf8, "typed.bad_utf8", "String is not valid UTF-8"},
		{.Non_Finite, "typed.non_finite", "Number is not finite"},
		{.Too_Deep, "typed.too_deep", "Value nests past the depth limit"},
		{.Cycle, "typed.cycle", "Value refers to itself"},
		{.Bad_Raw, "typed.bad_raw", "Text is not one value of the format"},
		{.Unwritable, "typed.unwritable", "Value cannot be written in the format"},
		{.Write_Failed, "typed.write_failed", "Output refused the bytes"},
	}
	for k in kinds {
		e := core.Typed_Error{kind = k.kind, at = 7}
		b: strings.Builder
		defer strings.builder_destroy(&b)
		core.render(strings.to_writer(&b), transmute([]u8)string("abc\ndef"), e)
		testing.expect_value(t, strings.to_string(b), k.message)
		strings.builder_reset(&b)
		core.write_code(strings.to_writer(&b), e)
		testing.expect_value(t, strings.to_string(b), k.code)
	}
}

@(test)
write_failed_renders_its_cause :: proc(t: ^testing.T) {
	b: strings.Builder
	defer strings.builder_destroy(&b)
	core.render(strings.to_writer(&b), nil, core.Typed_Error{kind = .Write_Failed, cause = .Closed})
	testing.expect_value(t, strings.to_string(b), "Output refused the bytes (Closed)")
}

@(test)
write_kinds_render_their_path :: proc(t: ^testing.T) {
	e := core.Typed_Error{kind = .Non_Finite, n_steps = 2}
	e.steps[0] = core.Name("price")
	e.steps[1] = core.Index(3)
	b: strings.Builder
	defer strings.builder_destroy(&b)
	core.render(strings.to_writer(&b), nil, e)
	testing.expect_value(t, strings.to_string(b), "Number is not finite at .price[3]")
}
