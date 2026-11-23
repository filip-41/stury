package tape

import "base:runtime"

// A text that arrives in pieces is read one piece at a time through `Options.pieces`: each read takes a window of the
// text, stops at the end of the bytes it has and leaves in its `Pieces` what the next read continues from. Offsets stay
// those of the whole text.

// The state of a read of a text in pieces, which the caller holds from the first piece to the last and frees with
// `destroy`. The caller sets `from` and `last` before each read, and the read sets the rest. It holds no pointer into a
// piece of text.
Pieces :: struct {
	// The offset in the whole text of the window's first byte, at most `keep`. The window reaches at least `at`.
	from:      u64,
	last:      bool, // the window ends the text
	// With `build` and `scan`, each read that stops at the end of its window gives the document of the value or the
	// answers so far, its open containers closed at the cut. Without it such a read gives an empty document.
	so_far:    bool,
	// Set by the read: the text ended inside its root value, or before the read could judge that it had ended, so the
	// next piece continues from here. False once a read of the last piece, or a stop, ended the read.
	more:      bool,
	at:        u64, // one past the bytes read, where the next window's new bytes start
	keep:      u64, // the lowest offset the next read needs, before which the caller may drop the text
	// The path from the root to the value the text ended inside: the key or index of each open container, then the
	// key whose value was being read. Its names are the read's, valid until its next read.
	open:      []Step,
	// With `find`, the bytes of the answer, copied out of the window it closed in, as the answer gives offsets only.
	text:      []u8,
	allocator: runtime.Allocator, // what the read holds between pieces is in, the context's when unset
	// The state the read carries from one piece to the next, which only the format's reads touch, in a block of its
	// own from the first read to `destroy`, which frees it through `release`.
	state:     rawptr,
	release:   proc(p: ^Pieces),
}

// Frees what a read of a text in pieces holds and leaves it zero.
destroy_pieces :: proc(p: ^Pieces) {
	if p.state != nil {
		p.release(p)
	}
	delete(p.text, p.allocator)
	p^ = {}
}

// The error of a read whose window does not hold the bytes the read needs: it starts past `keep`, or ends before `at`.
Piece_Gap :: struct {
	keep, at: u64, // what the window had to hold
	from, to: u64, // what it held
}

// The offset past the window `src` of the text in pieces `p`, or `Piece_Gap` when the window starts past what the last
// read keeps, or ends before where it read to.
piece_window :: #force_inline proc "contextless" (p: ^Pieces, src: []u8) -> (to: u64, err: Error) {
	to = p.from + u64(len(src))
	if p.from > p.keep || to < p.at {
		return to, Piece_Gap{p.keep, p.at, p.from, to}
	}
	return to, nil
}

// The bytes of the window of `src` taken at offset `from`, as a slice that its tokens' offsets in the whole text index.
// Its bytes before `from` are not to be read: a read starts at or past `keep`, which no window starts past, and a
// hook reads only tokens of that read or bytes its `keep` holds. Its base, the window's address less `from`, is
// computed in integers and only added to, with no bounds, so it may wrap below zero with no effect on an index past it.
piece_src :: #force_inline proc "contextless" (src: []u8, from: u64) -> []u8 {
	return ([^]u8)(uintptr(raw_data(src)) - uintptr(from))[:from + u64(len(src))]
}
