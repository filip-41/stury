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

// A stream that takes `taken` bytes of what it was given and names no error.
silent_stream :: proc(taken: ^i64) -> io.Stream {
	return {
		data = taken,
		procedure = proc(data: rawptr, mode: io.Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From) -> (i64, io.Error) {
			if mode != .Write {
				return 0, .Empty
			}
			return min(i64(len(p)), (^i64)(data)^), nil
		},
	}
}

// A stream that names no error and takes nothing is a short write, and one that takes a few bytes at a time is written whole.
@(test)
silent_streams :: proc(t: ^testing.T) {
	for taken, want in ([]i64{0, 7}) {
		spill: [write.ROOM_MAX]u8 = ---
		out: write.Out
		taken := taken
		write.init(&out, &spill, stream = silent_stream(&taken))
		put_pieces(&out, 1, 50)
		_, err := write.finish(&out)
		if want == 0 {
			testing.expect_value(t, err.kind, core.Typed_Error_Kind.Write_Failed)
			testing.expect_value(t, err.cause, io.Error.Short_Write)
		} else {
			testing.expect_value(t, err.kind, core.Typed_Error_Kind.None)
			testing.expect_value(t, out.flushed, 50)
		}
	}
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
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.No_Memory)
}

@(test)
write_kinds_render :: proc(t: ^testing.T) {
	Case :: struct {
		err:     core.Typed_Error,
		code:    string,
		message: string,
	}
	steps := core.Typed_Error{kind = .Non_Finite, n_steps = 2}
	steps.steps[0], steps.steps[1] = core.Name("price"), core.Index(3)
	cases := [?]Case {
		{{kind = .Invalid_Utf8, at = 7}, "typed.invalid_utf8", "Invalid UTF-8"},
		{{kind = .Non_Finite, at = 7}, "typed.non_finite", "Number is not finite"},
		{{kind = .Too_Deep, at = 7}, "typed.too_deep", "Exceeds the depth limit"},
		{{kind = .Cycle, at = 7}, "typed.cycle", "Value refers to itself"},
		{{kind = .Bad_Raw, at = 7}, "typed.bad_raw", "Not one value of the format"},
		{{kind = .Unwritable, at = 7}, "typed.unwritable", "Value cannot be written in the format"},
		{{kind = .Write_Failed, at = 7}, "typed.write_failed", "Output refused the bytes"},
		{{kind = .Write_Failed, cause = .Closed}, "typed.write_failed", "Output refused the bytes (Closed)"},
		{steps, "typed.non_finite", "Number is not finite at .price[3]"},
	}
	for c in cases {
		b: strings.Builder
		defer strings.builder_destroy(&b)
		core.render(strings.to_writer(&b), transmute([]u8)string("abc\ndef"), c.err)
		testing.expect_value(t, strings.to_string(b), c.message)
		strings.builder_reset(&b)
		core.write_code(strings.to_writer(&b), c.err)
		testing.expect_value(t, strings.to_string(b), c.code)
	}
}
