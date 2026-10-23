package core

import "core:io"
import "core:mem"

// The bytes a streamed reader (`records_from`) asks of its `io.Reader` at a time, unless `chunk` says otherwise.
READER_CHUNK :: 64 * 1024

// The bytes of a stream held in memory: `buf[:hi]` is what is read and not yet dropped, and `base` is the
// stream offset of `buf[0]`. The buffer is `allocator`'s, grown by doubling.
Stream_Window :: struct {
	reader:    io.Reader,
	allocator: mem.Allocator,
	// The bytes asked of the reader at a read.
	chunk:     int,
	buf:       []byte,
	hi:        int,
	base:      u64,
	eof:       bool,
	// The reader's failure other than `.EOF` (`.No_Progress` for a read of no bytes and no error). The bytes
	// read before it stay in the window.
	read_err:  io.Error,
}

// Drop `buf[:keep]`: the bytes after it move to the front.
window_drop :: proc(w: ^Stream_Window, keep: int) {
	w.hi = copy(w.buf, w.buf[keep:w.hi])
	w.base += u64(keep)
}

// Make room for a chunk (doubling the buffer if need be) and read once. `progress` is false once the read
// failed without handing over a byte, or `err` is `.Out_Of_Memory` at the stream offset where the buffer could
// not grow.
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
