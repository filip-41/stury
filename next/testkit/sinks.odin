package testkit

import "core:io"

// A sink that takes at most `limit` bytes of each write, which a writer that streams must go on writing from where it
// stopped, and keeps what it took.
Chunked :: struct {
	limit: int,
	taken: [dynamic]u8,
	calls: int,
}

// The writer of `c`, which takes at most `limit` bytes a call.
chunked_sink :: proc(c: ^Chunked, limit: int, allocator := context.allocator) -> io.Writer {
	c^ = {limit = limit}
	c.taken.allocator = allocator
	return {chunked_proc, c}
}

// Frees what `c` kept.
chunked_destroy :: proc(c: ^Chunked) {
	delete(c.taken)
}

@(private)
chunked_proc :: proc(data: rawptr, mode: io.Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From) -> (n: i64, err: io.Error) {
	c := (^Chunked)(data)
	#partial switch mode {
	case .Write:
		c.calls += 1
		k := min(len(p), c.limit)
		if _, e := append(&c.taken, ..p[:k]); e != nil {
			return 0, .Unknown
		}
		return i64(k), nil
	case .Query:
		return io.query_utility({.Write, .Query})
	}
	return 0, .Empty
}
