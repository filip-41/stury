package core

import "core:io"
import "core:mem"

// The default bytes per read that a streamed reader (`records_from`) requests from its `io.Reader`; `chunk`
// overrides it.
READER_CHUNK :: 64 * 1024

// Stream_Window holds part of a stream in memory. `buf[:hi]` is read and not yet dropped, and `base` is the
// stream offset of `buf[0]`. The buffer is allocated with `allocator` and grows by doubling.
Stream_Window :: struct {
	reader:    io.Reader,
	allocator: mem.Allocator,
	// The bytes requested from the reader per read.
	chunk:     int,
	buf:       []byte,
	hi:        int,
	base:      u64,
	eof:       bool,
	// The reader's error other than `.EOF`; `.No_Progress` for a read that returned no bytes and no error. Bytes
	// read before the error stay in the window.
	read_err:  io.Error,
}

// Drops `buf[:keep]` and moves the remaining bytes to the front.
window_drop :: proc(w: ^Stream_Window, keep: int) {
	w.hi = copy(w.buf, w.buf[keep:w.hi])
	w.base += u64(keep)
}

// Makes room for a chunk, doubling the buffer if needed, and reads once. `progress` is false when the read failed
// without returning a byte. `err` is `.Out_Of_Memory`, at the stream offset where the buffer could not grow.
window_fill :: proc(w: ^Stream_Window) -> (progress: bool, err: Maybe(Error)) {
	chunk := max(w.chunk, 1)
	if len(w.buf) - w.hi < chunk {
		grown, aerr := mem.alloc_bytes_non_zeroed(max(2 * len(w.buf), w.hi + chunk), allocator = w.allocator)
		if aerr != nil {
			return false, Error{kind = .Out_Of_Memory, offset = w.base + u64(w.hi)}
		}
		copy(grown, w.buf[:w.hi])
		delete(w.buf, w.allocator)
		w.buf = grown
	}
	n, rerr := io.read(w.reader, w.buf[w.hi:])
	w.hi += n
	switch {
	case rerr == .EOF:
		w.eof = true
	case rerr == nil && n == 0:
		w.read_err = .No_Progress
	case rerr != nil:
		w.read_err = rerr
	}
	return n > 0 || w.eof, nil
}
