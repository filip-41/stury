package encode

// Writing to an `io.Writer`: a writer that streams keeps a buffer of about SINK_FLUSH_AT bytes and hands
// it to the writer whenever it fills, so the output is never held whole. Only bytes no later write will
// change are handed over.

import "core:io"
import "core:mem"

// Where a streaming writer's bytes go: `w`, re-escaped as `reescape` says.
Sink :: struct {
	w:        io.Writer,
	reescape: Reescape,
}

// Write `text`, re-escaped when the sink says so. Returns the count of `text` consumed. Re-escaping stops before
// a UTF-8 sequence cut off at the end, which the caller keeps for the next write.
@(private)
sink_write :: proc(s: ^Sink, text: []u8) -> (int, Marshal_Error) #no_bounds_check {
	if s.reescape == {} {
		if _, err := io.write_full(s.w, text); err != nil {
			return 0, .Write_Failed
		}
		return len(text), .None
	}
	// The worst rewrite is six bytes for one (`<` as `\u003c`).
	CHUNK :: 4096
	out: [6 * CHUNK]u8 = ---
	n := utf8_whole_len(text)
	for at := 0; at < n; {
		end := min(at + CHUNK, n)
		for end < n && text[end] & 0xC0 == 0x80 {
			end -= 1
		}
		w := reescape_into(&out[0], text[at:end], s.reescape)
		if _, err := io.write_full(s.w, out[:w]); err != nil {
			return 0, .Write_Failed
		}
		at = end
	}
	return n, .None
}

// Write `buf`'s bytes and empty it, keeping what `sink_write` left.
sink_drain :: proc(s: ^Sink, buf: ^[dynamic]u8) -> Marshal_Error {
	n := sink_write(s, buf[:]) or_return
	remove_range(buf, 0, n)
	return .None
}

// A streaming document walk's output buffer and where it goes.
@(private)
Doc_Sink :: struct {
	sink:      Sink,
	buf:       []byte,
	allocator: mem.Allocator,
}

// Hand `k.buf[:w]` to the writer. What it left (a cut UTF-8 sequence) moves to the front, and its length is
// the new write offset.
@(private)
sink_flush :: proc(k: ^Doc_Sink, w: int) -> (left: int, err: Marshal_Error) {
	done := sink_write(&k.sink, k.buf[:w]) or_return
	copy(k.buf, k.buf[done:w])
	return w - done, .None
}

// The write offset after making room for `need` bytes from `w`: flushed when the buffer is short, then grown
// when it is still short.
@(private)
sink_room :: #force_no_inline proc(k: ^Doc_Sink, w, need: int) -> (at: int, err: Marshal_Error) {
	at = sink_flush(k, w) or_return
	if at + need > len(k.buf) {
		grown, aerr := mem.resize_bytes_non_zeroed(k.buf, at + need, allocator = k.allocator)
		if aerr != nil {
			return at, .Out_Of_Memory
		}
		k.buf = grown
	}
	return at, .None
}
