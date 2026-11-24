package json

import "base:intrinsics"
import "core:simd"
import "stury:lib/base/kernel"
import "stury:lib/core/tape"
import "stury:lib/ops/write"

// The write of a document read whole as JSON or JSONC, with no fact the target writes and no table: its rows in
// document order, each container closed where its subtree ends, on a stack of its own. `rows_run` holds the common
// case, calls nothing, and copies each token from the source in 16-byte blocks over chunks of rows the output's room
// holds. `rows_rare` and `rows_close` write each row it stops at: a string with an escape spelled another way, a long
// token, a deep line, a row whose block copy would read past the source.

// The longest token `rows_run` copies.
@(private)
ROW_TOKEN :: 256

// The most indent bytes a line of `rows_run` holds, at least one level of the widest indent.
@(private)
ROW_INDENT :: 1024
#assert(ROW_INDENT / 255 >= 1)

// The levels past the depth its chunk starts at that `rows_run` opens, which bound the indent of a row's lines and so
// the room a row of indented text takes: a separator line, a key and a value of `ROW_TOKEN` bytes, the line of a
// container it opens and of that container's close, and the block a copy or a line stores past its end, within
// `ROOM_MAX` at `ROW_INDENT` bytes of indent.
@(private)
ROW_HEADROOM :: 16
#assert(3 * (ROW_INDENT + 18) + 2 * (ROW_TOKEN + 32) + 8 <= write.ROOM_MAX)

// The room a row of compact text takes, which has no lines: a key and a value, and the bytes of a container that opens
// and closes on the row and of the comma.
@(private)
ROW_ROOM_COMPACT :: 2 * (ROW_TOKEN + 32) + 16

// The fewest rows a chunk is worth starting with, before a sink's buffer is written out to give it room.
@(private)
ROW_CHUNK_MIN :: 16

// The levels the stack of `write_rows` holds in itself. Past them it comes from the write's allocator.
@(private)
ROW_LEVELS :: 1024
#assert(ROW_LEVELS > 0, "the stack doubles as it grows")

// An open container: the node its subtree ends before, and its close bracket.
@(private)
Open_Container :: struct {
	end:   tape.Node_Index,
	close: u32,
}

// Where a write of rows stands. `rows_run` holds it in a local, so it keeps all of it in registers.
@(private)
Rows :: struct {
	p:     [^]u8, // the next byte of the output, in `rows_run`
	stack: [^]Open_Container, // the open containers, over a sentinel that ends at no node
	top:   int,
	limit: int, // the deepest level `rows_run` opens
	end:   tape.Node_Index, // the node the innermost container ends before, in `rows_run` no later than `stop`
	stop:  tape.Node_Index, // the row `rows_run` stops at
	bytes: int, // the indent of level `top`, in `rows_run`
	width: int, // the indent's bytes a level
	after: u32, // 0 at the start and after a key or a separator, 1 after an open bracket, 2 after a value or a close
	head:  #simd[16]u8, // a line end and 15 bytes of indent
	comma: #simd[16]u8, // a comma, a line end and 14 bytes of indent
	fill:  #simd[16]u8, // 16 bytes of indent
}

// The first node whose token a block copy may read past the source, so `rows_run` leaves it and every later row to
// the rare path: a token is copied in blocks of 16 bytes, at least 32 bytes, from the byte before its span, and
// `short_escapes` reads 32 bytes past a string.
@(private)
rows_copy_end :: proc "contextless" (doc: ^tape.Document) -> tape.Node_Index {
	for i := len(doc.nodes); i > 0; i -= 1 {
		t := doc.nodes[i - 1]
		if t.kind < .Array && t.lo + max(u64(t.n), 32) + 32 <= u64(len(doc.src)) {
			return tape.Node_Index(i)
		}
	}
	return 0
}

// Writes the value the walk `w` starts at: `rows_run` over chunks of rows the output's room holds, counting each row at
// the room it takes at most past the closes of the containers open at the chunk's start, so no row tests the room, and
// the rare path for each row it stops at. A chunk starts on a row inside the innermost container. A JSON or JSONC
// document's scalars spell the same in every target, so the rare path writes them as JSON's.
@(private)
write_rows :: proc(out: ^write.Out, w: ^write.Tree, l: ^Layout, $PRETTY: bool, $WIDTH: int) #no_bounds_check {
	local: [ROW_LEVELS]Open_Container = ---
	r: Rows
	r.stack = &local[0]
	r.stack[0].end = max(tape.Node_Index)
	held := ROW_LEVELS
	defer write.free_stack(r.stack, held, ROW_LEVELS, w.allocator)
	width := WIDTH if WIDTH > 0 else l.width
	r.width = width
	when PRETTY {
		lanes := transmute([16]u8)[2]u64{l.fill, l.fill}
		r.fill = transmute(#simd[16]u8)lanes
		lanes[0] = '\n'
		r.head = transmute(#simd[16]u8)lanes
		lanes[0], lanes[1] = ',', '\n'
		r.comma = transmute(#simd[16]u8)lanes
		line_at := ROW_INDENT / width
	} else {
		line_at := max(int)
		row_room :: ROW_ROOM_COMPACT
	}
	r.limit = min(line_at, held - 1)
	nodes, src := w.nodes, raw_data(w.doc.src)
	stop := min(rows_copy_end(w.doc), w.end)
	i := w.i
	if !rows_rare(out, w, l, &r, &held, i, PRETTY) {
		return
	}
	i += 1
	for r.top > 0 && out.err == nil {
		if r.stack[r.top].end != i && i < stop && r.top <= line_at {
			when PRETTY {
				r.limit = min(r.top + ROW_HEADROOM, line_at, held - 1)
				row_room := 3 * (r.limit * width + 18) + 2 * (ROW_TOKEN + 32) + 8
				owed := r.top * (r.top * width + 18)
			} else {
				owed := r.top
			}
			write.room(out, row_room)
			chunk := (out.size - out.cursor - owed) / row_room
			if chunk < ROW_CHUNK_MIN && owed + ROW_CHUNK_MIN * row_room <= out.size {
				// A sink's buffer nearly full would take runs of a few rows each, so it is written out first, unless
				// even an empty one would not hold a chunk.
				write.drain(out)
				chunk = (out.size - out.cursor - owed) / row_room
			}
			if chunk > 0 {
				r.stop = tape.Node_Index(min(int(i) + chunk, int(stop)))
				// A chunk ends on a value, since a key is written with its value.
				if nodes[r.stop - 1].role == .Key {
					r.stop -= 1
				}
				if r.stop > i {
					r.p = out.buf[out.cursor:]
					r.end = min(r.stack[r.top].end, r.stop)
					r.bytes = r.top * width
					// What is owed before row `i`, as `after` says.
					when PRETTY {
						if r.after == 2 {
							r.p = line_start(r.p, r.comma, r.fill, 2 + r.bytes)
						} else if r.after == 1 {
							r.p = line_start(r.p, r.head, r.fill, 1 + r.bytes)
						}
					} else {
						r.p[0] = ','
						r.p = r.p[int(r.after == 2):]
					}
					r.after = 0
					next := rows_run(&r, nodes, src, i, PRETTY, WIDTH)
					out.cursor = int(intrinsics.ptr_sub(r.p, out.buf))
					// A run that stops inside its chunk with nothing owed stops before a row it does not write, and
					// would stop there again.
					stuck := r.after == 0 && next < r.stop
					i = next
					if !stuck {
						continue
					}
				}
			}
		}
		if r.stack[r.top].end == i {
			rows_close(out, l, &r, PRETTY)
		} else {
			if !rows_rare(out, w, l, &r, &held, i, PRETTY) {
				return
			}
			i += 1
		}
	}
}

// The rows from row `i`, with nothing owed before it, up to `c.stop`, a row and its key at a time. A value is written
// with its key, with no test between. Returns the row it stopped at, and `after` says what is owed before it. It calls
// nothing and holds the cursor in a local, so the loop keeps every value in a register.
@(private)
rows_run :: #force_no_inline proc "contextless" (r: ^Rows, nodes: [^]tape.Node, src: [^]u8, i: tape.Node_Index, $PRETTY: bool, $WIDTH: int) -> tape.Node_Index #no_bounds_check {
	// `kind`, `role` and `spelling` are one word of a node, and a JSON key is a string.
	KEY_MASK :: u32(0xFFFF) | u32(tape.SPELLING_DECODE) << 16
	KEY_WORD :: u32(tape.Kind.String) | u32(tape.Role.Key) << 8
	#assert(offset_of(tape.Node, role) == offset_of(tape.Node, kind) + 1)
	#assert(offset_of(tape.Node, spelling) == offset_of(tape.Node, kind) + 2)
	#assert(u8('[') + 2 == u8(']') && u8('[') | 1 << 5 == u8('{'))
	// Past `Plain` a kind is a container, and one more has bit 3 set.
	#assert(tape.Kind.Plain + tape.Kind(1) == .Array && u8(tape.Kind.Array) + 1 == 8 && u8(tape.Kind.Object) + 1 < 16)
	c := r^
	i := i
	loop: {
		p := c.p
		for {
			t := &nodes[i]
			word := (^u32)(&t.kind)^
			if word & KEY_MASK == KEY_WORD {
				n := t.n + 2
				if !copy_token(p, src[t.lo - 1:], n) {
					break
				}
				p = p[n:]
				when PRETTY {
					intrinsics.unaligned_store((^u16)(p), u16(':') | u16(' ') << 8)
					p = p[2:]
				} else {
					p[0] = ':'
					p = p[1:]
				}
				i += 1
				t = &nodes[i]
				word = (^u32)(&t.kind)^
			}
			// A string's quotes are the bytes around its span, and of a JSON document's kinds only a string has bit 2.
			// One test takes a container and a string with an escape: a kind past `Plain`, or a quoted kind's escape
			// bit.
			quoted := (word >> 2) & 1
			if ((word & 0xFF) + 1) >> 3 | (quoted & (word >> 16)) != 0 {
				// An escaped string is rarer than a container, and its scan laid out between them delays every open.
				if intrinsics.expect(word & 0xFF < u32(tape.Kind.Array), false) {
					if t.role == .Key || t.n > ROW_TOKEN || !short_escapes(src[t.lo:], t.n) {
						break
					}
					copy_token(p, src[t.lo - 1:], t.n + 2)
					p = p[t.n + 2:]
				} else {
					// A container a read kept part of is refused on the rare path.
					if word >> 16 & u32(tape.CONTAINER_PARTIAL) != 0 {
						break
					}
					open := '[' | u8(word & 0xFF == u32(tape.Kind.Object)) << 5
					p[0] = open
					if t.n == 1 {
						p[1] = open + 2
						p = p[2:]
					} else {
						if c.top >= c.limit {
							break
						}
						end := i + tape.Node_Index(t.n)
						c.top += 1
						c.stack[c.top] = {end, u32(open) + 2}
						c.end = min(end, c.stop)
						i += 1
						p = p[1:]
						when PRETTY {
							c.bytes += WIDTH if WIDTH > 0 else c.width
							p = line_start(p, c.head, c.fill, 1 + c.bytes)
						}
						if i >= c.stop {
							break
						}
						continue
					}
				}
			} else {
				n := t.n + 2 * quoted
				if !copy_token(p, src[t.lo - u64(quoted):], n) {
					break
				}
				p = p[n:]
			}
			i += 1
			c.p = p
			if !before_row(&c, i, PRETTY, WIDTH) {
				break loop
			}
			p = c.p
		}
		c.p = p
	}
	r^ = c
	return i
}

// Closes every container that ends before row `i` and writes the separator before that row. Returns false with
// `after` set when `i` is where the chunk stops. `c.end` is held at `c.stop`, so this is the one test a row takes.
@(private)
before_row :: #force_inline proc "contextless" (c: ^Rows, i: tape.Node_Index, $PRETTY: bool, $WIDTH: int) -> bool #no_bounds_check {
	p := c.p
	for c.end == i {
		if i >= c.stop {
			c.p = p
			c.after = 2
			return false
		}
		when PRETTY {
			c.bytes -= WIDTH if WIDTH > 0 else c.width
			p = line_start(p, c.head, c.fill, 1 + c.bytes)
		}
		p[0] = u8(c.stack[c.top].close)
		p = p[1:]
		c.top -= 1
		c.end = min(c.stack[c.top].end, c.stop)
	}
	when PRETTY {
		c.p = line_start(p, c.comma, c.fill, 2 + c.bytes)
	} else {
		p[0] = ','
		c.p = p[1:]
	}
	return true
}

// Writes row `i` with what is owed before it, with no limit on the room, the depth or the spelling. False with
// `w.err` set when it cannot.
@(private, cold)
rows_rare :: #force_no_inline proc(out: ^write.Out, w: ^write.Tree, l: ^Layout, r: ^Rows, held: ^int, i: tape.Node_Index, $PRETTY: bool) -> bool {
	t := w.nodes[i]
	if t.kind >= .Array && r.top + 1 == held^ && !write.grow_stack(&r.stack, held, ROW_LEVELS, w.allocator, &w.err) {
		return false
	}
	if r.after == 2 {
		write.put_byte(out, ',')
	}
	when PRETTY {
		if r.after != 0 {
			line_indent(out, l, r.top)
		}
	}
	if t.kind >= .Array {
		if t.spelling & tape.CONTAINER_PARTIAL != 0 {
			w.err = write.Refused{i, .Partial}
			return false
		}
		open := bracket_of(t.kind)
		write.put_byte(out, open)
		r.top += 1
		r.stack[r.top] = {i + tape.Node_Index(t.n), u32(open) + 2}
		r.after = 1
		return true
	}
	src := w.doc.src
	// A string with escapes is its source text respelled where `respell_escapes` may read past it.
	copied := t.kind == .String && t.spelling & (tape.SPELLING_DECODE | tape.SPELLING_LAX) == tape.SPELLING_DECODE && t.lo + u64(t.n) + 64 <= u64(len(src)) && put_respelled(out, src[t.lo - 1:][:t.n + 2])
	if t.role == .Key {
		if !copied && !put_key(out, w, l, i, .Json) {
			return false
		}
		put_colon(out, PRETTY)
		r.after = 0
		return true
	}
	r.after = 2
	return copied || put_scalar(out, w, l, i, .Json)
}

// Writes `text`, a string of a strict text with its quotes, respelled by `respell_escapes` in pieces that each end
// past an escape. False when an escape at the start of a piece does not read, which a strict text's string never holds,
// with the pieces before it written.
@(private)
put_respelled :: proc(out: ^write.Out, text: []u8) -> bool #no_bounds_check {
	for at := 0; at < len(text); {
		n := min(len(text) - at, write.ROOM_MAX - 64)
		wrote, read := respell_escapes(write.room(out, n + 64), raw_data(text)[at:], n)
		if read == 0 {
			return false
		}
		out.cursor += wrote
		at += read
	}
	return true
}

// Writes the close of the innermost container, with the line before it.
@(private, cold)
rows_close :: #force_no_inline proc(out: ^write.Out, l: ^Layout, r: ^Rows, $PRETTY: bool) {
	when PRETTY {
		if r.after == 2 {
			line_indent(out, l, r.top - 1)
		}
	}
	write.put_byte(out, u8(r.stack[r.top].close))
	r.top -= 1
	r.after = 2
}

// Whether the `n` bytes at `s`, a string's escaped text, hold only escapes `put_escaped` spells the same, so no unicode
// escape and no escaped solidus: no backslash before a `u` or a slash. An escaped backslash before a `u` also says
// false, which only sends the string to the rare path. A block of 32 bytes takes one test for a backslash, and one that
// holds one a test of the bytes after them. It reads up to 32 bytes past the string.
@(private)
short_escapes :: #force_inline proc "contextless" (s: [^]u8, n: u32) -> bool #no_bounds_check {
	V :: #simd[16]u8
	for k := u32(0); k < n; k += 32 {
		a := simd.lanes_eq(kernel.load16(s[k:]), V('\\'))
		b := simd.lanes_eq(kernel.load16(s[k + 16:]), V('\\'))
		if !kernel.any_lane16(a | b) {
			continue
		}
		next_a, next_b := kernel.load16(s[k + 1:]), kernel.load16(s[k + 17:])
		a &= simd.lanes_eq(next_a, V('u')) | simd.lanes_eq(next_a, V('/'))
		b &= simd.lanes_eq(next_b, V('u')) | simd.lanes_eq(next_b, V('/'))
		left := int(n - k)
		if kernel.any_lane16(a & kernel.live16(min(left, 16)) | b & kernel.live16(clamp(left - 16, 0, 16))) {
			return false
		}
	}
	return true
}

// A line end and `n - 1` bytes of indent at `p`, from `v`, a block that opens with the line end, and `fill`. Stores up
// to 15 bytes past them.
@(private)
line_start :: #force_inline proc "contextless" (p: [^]u8, v, fill: #simd[16]u8, n: int) -> [^]u8 #no_bounds_check {
	kernel.store16(p, v)
	for k := 16; k < n; k += 16 {
		kernel.store16(p[k:], fill)
	}
	return p[n:]
}

// Copies the `n` bytes of a token from `src` to `dst` in 16-byte blocks and returns true, or returns false past
// `ROW_TOKEN` with `dst` unspecified. It reads and stores up to 31 bytes past them. Blocks from both ends overlap, so a
// length within a class takes no branch.
@(private)
copy_token :: #force_inline proc "contextless" (dst, src: [^]u8, n: u32) -> bool #no_bounds_check {
	block :: #force_inline proc "contextless" (dst, src: [^]u8, k: u32) {
		kernel.store16(dst[k:], kernel.load16(src[k:]))
	}
	block(dst, src, 0)
	block(dst, src, 16)
	if n <= 32 {
		return true
	}
	if n > ROW_TOKEN {
		return false
	}
	if n <= 64 {
		block(dst, src, n - 32)
		block(dst, src, n - 16)
		return true
	}
	block(dst, src, 32)
	block(dst, src, 48)
	if n <= 128 {
		block(dst, src, n - 64)
		block(dst, src, n - 48)
		block(dst, src, n - 32)
		block(dst, src, n - 16)
		return true
	}
	for k := u32(64); k < n; k += 16 {
		block(dst, src, k)
	}
	return true
}
