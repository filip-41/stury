// The output a written text goes into: a buffer that grows, or a buffer that is flushed to a stream whenever it fills.
// A stream costs the hot path nothing, since `room` has one branch and it leads to the cold proc that does either.
package write

import "base:runtime"
import "core:io"
import core "../"

// The most bytes one `room` call may ask for. A caller with more writes it in pieces.
ROOM_MAX :: 4096

// The buffer size of a stream's output unless `init` is given another.
STREAM_BUFFER :: 64 * 1024

// An output is not copied after `init`: a failed one writes into the `spill` its creator gave, which outlives it.
Out :: struct {
	buf:       [^]u8,
	size:      int, // the bytes `buf` holds
	cursor:    int, // the bytes written into `buf` and not yet flushed
	flushed:   int, // the bytes the stream took
	stream:    io.Stream, // a nil procedure means a buffer output
	allocator: runtime.Allocator,
	err:       core.Typed_Error_Kind, // `.No_Memory` or `.Write_Failed`, set once and kept
	cause:     io.Error, // what the stream answered, for `.Write_Failed`
	hint:      int, // a buffer output's first allocation, in bytes
	spill:     ^[ROOM_MAX]u8,
}

// Starts an output. A stream with no procedure writes into a buffer that `finish` returns, otherwise bytes go to
// `stream` through a buffer of `STREAM_BUFFER` bytes. Either allocates at its first `room`. A buffer output allocates
// `hint` bytes there when it is more than a `ROOM_MAX`, so a writer that knows its text's size from its source never
// regrows. Past the hint the buffer doubles. `spill` is where a failed output writes, bytes nobody reads. Outputs may
// share one.
init :: proc(out: ^Out, spill: ^[ROOM_MAX]u8, allocator := context.allocator, stream := io.Stream{}, hint := 0) {
	out.buf, out.size, out.cursor, out.flushed, out.err, out.cause, out.spill = nil, 0, 0, 0, .None, .None, spill
	out.stream, out.allocator, out.hint = stream, allocator, hint
}

// Returns a pointer to at least `n` free bytes at the cursor, `n` at most `ROOM_MAX`. The caller writes up to `n`
// bytes there and moves `cursor` past them. Once `err` is set the bytes go to a scratch that later calls discard.
room :: #force_inline proc(out: ^Out, n: int) -> [^]u8 #no_bounds_check {
	if out.size - out.cursor < n {
		return refill(out, n)
	}
	return out.buf[out.cursor:]
}

// Ends the output and returns its error. A buffer output also returns its bytes, which the caller owns, or nil when it
// failed. A stream output flushes what it holds and returns no bytes. Neither is usable afterwards. A `refused` write
// frees the output and returns `refused` with the stream's cause.
finish :: proc(out: ^Out, refused := core.Typed_Refusal{}) -> (bytes: []u8, err: core.Typed_Refusal) {
	if refused.kind != .None {
		destroy(out)
		err = refused
		err.cause = out.cause
		return
	}
	if out.stream.procedure != nil {
		if out.err == .None && out.cursor > 0 {
			if cause := flush(out); cause != .None {
				fail(out, .Write_Failed, cause)
			}
		}
		destroy(out)
		return nil, core.Typed_Refusal{kind = out.err, cause = out.cause}
	}
	bytes = out.buf[:out.cursor] if out.err == .None else nil
	if out.err == .None {
		out.buf, out.size, out.cursor = nil, 0, 0
	}
	return bytes, core.Typed_Refusal{kind = out.err}
}

// Frees what an output holds that `finish` did not hand over.
destroy :: proc(out: ^Out) {
	if out.err == .None {
		runtime.mem_free(rawptr(out.buf), out.allocator)
	}
	out.buf, out.size, out.cursor = nil, 0, 0
}

// The cold side of `room`: the buffer is flushed to the stream when there is one, else grown.
@(private)
refill :: #force_no_inline proc(out: ^Out, n: int) -> [^]u8 {
	assert(n <= ROOM_MAX, "room asked for more than ROOM_MAX")
	if out.err != .None {
		out.cursor = 0
		return out.buf
	}
	size := out.size
	if out.stream.procedure != nil {
		if out.buf != nil {
			cause := flush(out)
			if cause == .None {
				return out.buf
			}
			return fail(out, .Write_Failed, cause)
		}
		size = STREAM_BUFFER
	} else {
		size = max(2 * out.size, out.cursor + n, ROOM_MAX, out.hint)
	}
	next, err := runtime.non_zero_mem_resize(rawptr(out.buf), out.size, size, 1, out.allocator)
	if err != nil {
		return fail(out, .No_Memory)
	}
	out.buf, out.size = raw_data(next), size
	return out.buf[out.cursor:]
}

// Writes the buffer to the stream and empties it, again from where the stream stopped while it takes bytes without an
// error. Returns what the stream answered, `.Short_Write` when it took none of what was left and named no error.
@(private)
flush :: proc(out: ^Out) -> io.Error {
	left := out.buf[:out.cursor]
	out.cursor = 0
	for len(left) > 0 {
		wrote, err := io.write(out.stream, left)
		out.flushed += wrote
		if err != .None {
			return err
		}
		if wrote <= 0 {
			return .Short_Write
		}
		left = left[wrote:]
	}
	return .None
}

// Records `kind` and `cause`, frees the buffer, and points the output at its scratch.
@(private)
fail :: proc(out: ^Out, kind: core.Typed_Error_Kind, cause := io.Error.None) -> [^]u8 {
	destroy(out)
	out.err, out.cause = kind, cause
	out.buf, out.size = raw_data(out.spill[:]), ROOM_MAX
	return out.buf
}
