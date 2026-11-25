package write

import "base:intrinsics"
import "base:runtime"
import "core:io"
import "stury:lib/core/tape"

// The output a writer spells into: a buffer from the caller's allocator that doubles as it fills, or a buffer of
// `SINK_BYTES` written to the caller's sink whenever it fills. A writer asks `room` for bytes, writes them and moves
// `cursor`, and the one branch in `room` leads to the cold proc that grows or flushes.

// The most bytes one `room` call may ask for. A writer with more writes them in pieces.
ROOM_MAX :: 4096

// The buffer a sink's output holds before it writes to the sink.
SINK_BYTES :: 64 * 1024

// An output, which is not copied once `out_start` returns. After a refused allocation or a failed sink, `room` hands
// back the start of the buffer it holds, whose bytes nobody reads, so a writer checks `err` only where it can stop.
Out :: struct {
	buf:       [^]u8,
	size:      int, // the bytes `buf` holds
	cursor:    int, // the bytes written into `buf` and not yet flushed
	sink:      io.Writer, // a nil procedure for a buffer output
	allocator: runtime.Allocator,
	err:       Error, // the first failure, kept
}

// The format's write of value `opts.node` of `doc` as a text of `spec` into `out`, returning the fact kinds dropped.
Write_Out :: #type proc(out: ^Out, doc: ^tape.Document, spec: u8, opts: Options, allocator: runtime.Allocator) -> (tape.Facts, Error)

// Writes by the format's `write_out` in a buffer from `allocator` that the caller owns and frees with it, which a
// format's `write` forwards to. On an error there is no text and no fact is dropped.
to_buffer :: proc(doc: ^tape.Document, spec: u8, opts: Options, allocator: runtime.Allocator, write_out: Write_Out) -> (text: []u8, dropped: tape.Facts, err: Error) {
	out: Out
	if e := out_start(&out, allocator, {}, size_hint(doc, opts)); e != nil {
		return nil, {}, e
	}
	if dropped, err = write_out(&out, doc, spec, opts, allocator); err != nil {
		out_drop(&out)
		return nil, {}, err
	}
	if text, err = out_finish(&out); err != nil {
		dropped = {}
	}
	return
}

// `to_buffer` into `sink`, through a buffer of `SINK_BYTES` from `allocator`, which a format's `write_to` forwards to.
// A sink with no procedure is `Bad_Option{"sink"}`. On a refusal or a failed sink the sink may hold a prefix of the
// text.
to_sink :: proc(sink: io.Writer, doc: ^tape.Document, spec: u8, opts: Options, allocator: runtime.Allocator, write_out: Write_Out) -> (dropped: tape.Facts, err: Error) {
	if sink.procedure == nil {
		return {}, tape.Bad_Option{"sink"}
	}
	out: Out
	if e := out_start(&out, allocator, sink, 0); e != nil {
		return {}, e
	}
	if dropped, err = write_out(&out, doc, spec, opts, allocator); err != nil {
		out_drop(&out)
		return {}, err
	}
	if _, err = out_finish(&out); err != nil {
		dropped = {}
	}
	return
}

// Starts an output into a buffer of at least `hint` bytes, or into `sink` when it has a procedure. It allocates its
// buffer here, so a refusal is the error and no writer runs.
out_start :: proc(out: ^Out, allocator: runtime.Allocator, sink: io.Writer, hint: int) -> runtime.Allocator_Error {
	out^ = {sink = sink, allocator = allocator}
	size := SINK_BYTES if sink.procedure != nil else max(hint, ROOM_MAX)
	raw := alloc_bytes(size, 1, allocator) or_return
	out.buf, out.size = raw_data(raw), size
	return nil
}

// `size` bytes from `allocator`, not zeroed, `.Out_Of_Memory` from an allocator that gives fewer.
@(private)
alloc_bytes :: proc(size, align: int, allocator: runtime.Allocator) -> ([]u8, runtime.Allocator_Error) {
	raw, err := runtime.mem_alloc_non_zeroed(size, align, allocator)
	if err == nil && (raw_data(raw) == nil || len(raw) < size) {
		err = .Out_Of_Memory
	}
	return raw, err
}

// Doubles `stack`, of `held` items, of which the first `inline` are the caller's own and stay unfreed. False with
// `err` set when memory is refused.
@(cold)
grow_stack :: #force_no_inline proc(stack: ^[^]$T, held: ^int, inline: int, allocator: runtime.Allocator, err: ^Error) -> bool {
	raw, e := alloc_bytes(2 * held^ * size_of(T), align_of(T), allocator)
	if e != nil {
		err^ = e
		return false
	}
	grown := ([^]T)(raw_data(raw))
	intrinsics.mem_copy_non_overlapping(grown, stack^, held^ * size_of(T))
	free_stack(stack^, held^, inline, allocator)
	stack^, held^ = grown, 2 * held^
	return true
}

// Frees a stack `grow_stack` grew past the caller's own `inline` items.
free_stack :: proc(stack: [^]$T, held, inline: int, allocator: runtime.Allocator) {
	if held > inline {
		runtime.mem_free_with_size(stack, held * size_of(T), allocator)
	}
}

// At least `n` free bytes at the cursor, `n` at most `ROOM_MAX`. The caller writes up to `n` bytes there and moves
// `cursor` past them.
room :: #force_inline proc(out: ^Out, n: int) -> [^]u8 #no_bounds_check {
	if out.size - out.cursor < n {
		return refill(out, n)
	}
	return out.buf[out.cursor:]
}

// Writes `b`, of any length, at the cursor.
put :: #force_inline proc(out: ^Out, b: []u8) #no_bounds_check {
	if len(b) <= ROOM_MAX {
		p := room(out, len(b))
		intrinsics.mem_copy_non_overlapping(p, raw_data(b), len(b))
		out.cursor += len(b)
		return
	}
	put_long(out, b)
}

// Writes the byte `c` at the cursor.
put_byte :: #force_inline proc(out: ^Out, c: u8) #no_bounds_check {
	room(out, 1)[0] = c
	out.cursor += 1
}

// Writes what a sink output holds to the sink now, so a writer that sizes its runs by the room left starts them in a
// whole buffer. A buffer output is untouched.
drain :: proc(out: ^Out) {
	if out.sink.procedure != nil && out.err == nil && out.cursor > 0 {
		flush(out)
	}
}

// Ends the output. A buffer output returns its bytes, which the caller owns and frees with the allocator it gave, or
// nil and the error. A sink output writes what it holds to the sink and returns no bytes. Either frees what it holds
// and is not used again.
out_finish :: proc(out: ^Out) -> (text: []u8, err: Error) {
	if out.sink.procedure != nil {
		if out.err == nil && out.cursor > 0 {
			flush(out)
		}
		runtime.mem_free_with_size(out.buf, out.size, out.allocator)
		return nil, out.err
	}
	if out.err != nil {
		runtime.mem_free_with_size(out.buf, out.size, out.allocator)
		return nil, out.err
	}
	return out.buf[:out.cursor], nil
}

// Frees an output that `out_finish` did not end, for a writer that stops on a refusal.
out_drop :: proc(out: ^Out) {
	runtime.mem_free_with_size(out.buf, out.size, out.allocator)
	out^ = {}
}

@(private)
put_long :: #force_no_inline proc(out: ^Out, b: []u8) {
	for at := 0; at < len(b); at += ROOM_MAX {
		k := min(ROOM_MAX, len(b) - at)
		intrinsics.mem_copy_non_overlapping(room(out, k), raw_data(b[at:]), k)
		out.cursor += k
	}
}

// The cold side of `room`: the buffer is written to the sink, or else doubled. After a failure the buffer is scratch.
@(private, cold)
refill :: #force_no_inline proc(out: ^Out, n: int) -> [^]u8 {
	assert(n <= ROOM_MAX, "room asked for more than ROOM_MAX")
	if out.err != nil {
		out.cursor = 0
		return out.buf
	}
	if out.sink.procedure != nil {
		flush(out)
		return out.buf
	}
	size := max(2 * out.size, out.cursor + n)
	raw, err := runtime.non_zero_mem_resize(out.buf, out.size, size, 1, out.allocator)
	if err == nil && (raw_data(raw) == nil || len(raw) < size) {
		err = .Out_Of_Memory
	}
	if err != nil {
		out.err = err
		out.cursor = 0
		return out.buf
	}
	out.buf, out.size = raw_data(raw), size
	return out.buf[out.cursor:]
}

// Writes the buffer to the sink and empties it, again from where the sink stopped while it takes bytes. A sink that
// takes none and names no error is `.Short_Write`, and one that says it took more than it was given `.Invalid_Write`.
@(private)
flush :: proc(out: ^Out) {
	left := out.buf[:out.cursor]
	out.cursor = 0
	for len(left) > 0 {
		wrote, err := io.write(out.sink, left)
		if err == .None && wrote <= 0 {
			err = .Short_Write
		}
		if err == .None && wrote > len(left) {
			err = .Invalid_Write
		}
		if err != .None {
			out.err = err
			return
		}
		left = left[wrote:]
	}
}
