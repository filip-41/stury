package json

import "base:intrinsics"
import "base:runtime"
import "core:io"
import "core:simd"
import core "../core"
import kernel "../core/kernel"
import write "../core/write"

// The document writer. A document walks its node rows in `rows_run`, which holds the common case, calls nothing, and
// closes a container where its subtree ends. `rare_row` and `rare_close` write what it does not: a reservation that does
// not hold, a token that needs another spelling, a line deeper than the room for it. A string and a number that were read
// keep their source spelling and are copied from the source. The punctuation and the whitespace are made again.

// The longest token `copy_token` moves. A longer one is copied by the system's copy, which is faster past this.
@(private)
TOKEN_LONG :: 256

// The bytes `copy_token` always moves.
@(private)
COPY_MIN :: 32

// The room past a token: a comma, a line break and its indent, what a block copy may store past its end, quotes, and a
// key's colon and space.
@(private)
NODE_ROOM :: write.LINE_ROOM + 64
#assert(NODE_ROOM <= write.ROOM_MAX)

// The most one row writes in `rows_run`, as a power of two: a token and what comes after it, and for a container the line
// of its close.
@(private)
ROW_ROOM_SHIFT :: 12
#assert(TOKEN_LONG + write.LINE_ROOM + NODE_ROOM <= 1 << ROW_ROOM_SHIFT && 1 << ROW_ROOM_SHIFT <= write.ROOM_MAX)

// The largest source `write_text` copies, and the room it leaves past its end, which a row's block copy and string test read.
@(private)
SRC_COPY :: 1 << 10
@(private)
COPY_ROOM :: COPY_MIN + 16

// An open container: the node its subtree ends before, and its close bracket.
@(private)
Open :: struct {
	end:   u32,
	close: u32,
}

// Where a write stands. A loop that holds a `Cursor` as a local keeps all of it in registers.
@(private)
Cursor :: struct {
	p:     [^]u8, // the next byte of the output
	safe:  uintptr, // a token of `n` bytes fits when `p + n` is not past this. 0 while every token takes the rare path
	src:   [^]u8,
	stack: [^]Open,
	top:   int,
	limit: int, // the deepest level the common case opens
	unit:  int, // the indent's bytes per level
	end:   u32, // the node the innermost container ends before, in `rows_run` no later than `stop`
	after: u32, // 0 at the start and after a key, 1 after an open bracket, 2 after a value or a close
	stop:  u32, // the row `rows_run` stops at
	head:  V, // a line break and 15 bytes of fill
	comma: V, // a comma, a line break and 14 bytes of fill
	bytes: int, // `top * unit` in `rows_run`
	fill:  V,
}

// What a written text is made of. Only `c` changes while it is written.
@(private)
Emit :: struct {
	c:       Cursor,
	out:     ^write.Out,
	src:     []u8,
	doc:     ^core.Document,
	opts:    core.Write_Options,
	cap:     int, // the deepest level the stack holds
	line_at: int, // the deepest level whose line fits `NODE_ROOM`
	copy:    bool, // a string is copied as it was read. False when `ascii`, `escape_html` or `respell_strings` ask for another spelling
	hi:      V, // with `copy` false, the bytes from which a string is written by the rare path: DEL under `ascii`, else 0xFF
	html:    [4]V, // with `copy` false, more such bytes: `<`, `>`, `&` and 0xE2 under `escape_html`, else a backslash
}

@(private)
put_start :: proc(e: ^Emit, out: ^write.Out, src: []u8, doc: ^core.Document, opts: core.Write_Options, local: []Open, depth_cap: int) -> bool {
	e.out, e.src, e.doc, e.opts, e.cap = out, src, doc, opts, depth_cap
	stack := raw_data(local)
	if depth_cap >= len(local) {
		wide, failed := make([]Open, depth_cap + 1, out.allocator)
		if failed != nil {
			return false
		}
		stack = raw_data(wide)
	}
	e.copy = copies_strings(opts)
	e.hi = V(0x7f) if opts.ascii else V(0xFF)
	e.html = {V('\\'), V('\\'), V('\\'), V('\\')}
	if opts.escape_html {
		e.html = {V('<'), V('>'), V('&'), V(0xE2)}
	}
	fill := V(0x20)
	e.c.unit = int(opts.indent)
	if opts.tab {
		fill, e.c.unit = V(0x09), 1
	}
	line := transmute([16]u8)fill
	line[0] = '\n'
	e.c.fill, e.c.head = fill, transmute(V)line
	line[0], line[1] = ',', '\n'
	e.c.comma = transmute(V)line
	e.c.src, e.c.stack = raw_data(src), stack
	stack[0].end = max(u32)
	e.c.end = max(u32)
	e.line_at = write.LINE_ROOM / e.c.unit if opts.pretty && e.c.unit > 0 else max(int)
	e.c.limit = min(e.line_at, depth_cap)
	resume(e)
	return true
}

// Frees the stack of a document nested past `MAX_DEPTH`.
@(private)
put_end :: proc(e: ^Emit) {
	if e.cap > core.MAX_DEPTH {
		free(e.c.stack, e.out.allocator)
	}
}

// Sets the cursor from the output after a rare step, with `NODE_ROOM` free at it.
@(private)
resume :: proc(e: ^Emit) {
	out := e.out
	e.c.p = write.room(out, NODE_ROOM)
	e.c.safe = 0
	if e.c.top <= e.line_at {
		e.c.safe = uintptr(out.buf) + uintptr(out.size) - NODE_ROOM
	}
}

// Moves the output's cursor to where the common case stopped.
@(private)
settle :: proc(e: ^Emit) {
	e.out.cursor = int(uintptr(e.c.p) - uintptr(e.out.buf))
}

// Writes a line break and `n - 1` bytes of indent, and stores up to 15 more bytes past them.
@(private)
put_line :: #force_inline proc "contextless" (c: ^Cursor, p: [^]u8, n: int) -> [^]u8 #no_bounds_check {
	intrinsics.unaligned_store((^V)(p), c.head)
	for k := 16; k < n; k += 16 {
		intrinsics.unaligned_store((^V)(p[k:]), c.fill)
	}
	return p[n:]
}

// Copies the `n` bytes of a token and returns true, or returns false past `TOKEN_LONG` with `dst` unspecified. A token
// of up to `COPY_MIN` bytes takes one branch whatever its length. It loads and stores up to `COPY_MIN` bytes past the end,
// and a caller keeps the last bytes of the source away from here.
@(private)
copy_token :: #force_inline proc "contextless" (dst, src: [^]u8, n: u32) -> bool #no_bounds_check {
	block :: #force_inline proc "contextless" (dst, src: [^]u8, k: u32) #no_bounds_check {
		intrinsics.unaligned_store((^V)(dst[k:]), intrinsics.unaligned_load((^V)(src[k:])))
	}
	block(dst, src, 0)
	block(dst, src, 16)
	if n <= COPY_MIN {
		return true
	}
	if n > TOKEN_LONG {
		return false
	}
	// Blocks from both ends overlap, so a length within a class takes no branch: a run of tokens of mixed length would
	// mispredict a loop's exit on each.
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

// Whether the `n` bytes at `src`, a string with its quotes, hold none of the bytes that `ascii` or `escape_html` write
// another way. It reads up to 15 bytes past the string, which `copy_token` already does, and a stop there only sends the
// string to the rare path.
@(private)
plain_string :: #force_inline proc "contextless" (e: ^Emit, src: [^]u8, n: u32) -> bool #no_bounds_check {
	for k := u32(0); k < n; k += 16 {
		v := intrinsics.unaligned_load((^V)(src[k:]))
		m := simd.lanes_ge(v, e.hi) | simd.lanes_eq(v, V('\\')) | simd.lanes_eq(v, e.html[0]) | simd.lanes_eq(v, e.html[1]) |
			simd.lanes_eq(v, e.html[2]) | simd.lanes_eq(v, e.html[3])
		if kernel.any_lane16(m) {
			return false
		}
	}
	return true
}

// Copies row `t` if it is a string or number past `TOKEN_LONG`, `rows_run` having stopped at it with nothing owed before
// it, and `NODE_ROOM` still holds after it. The system's copy beats the blocks past `TOKEN_LONG`, and a call there would
// cost every short row.
@(private)
copy_long :: proc "contextless" (e: ^Emit, t: core.Token) -> bool {
	c := &e.c
	if !e.copy || t.n <= TOKEN_LONG || t.kind > .String || t.role == .Key || t.spelling & core.SPELLING_LAX != 0 || c.safe == 0 || c.after != 0 {
		return false
	}
	quoted := u32(t.kind == .String)
	n := int(t.n + 2 * quoted)
	if int(uintptr(e.out.buf)) + e.out.size - int(uintptr(c.p)) < n + NODE_ROOM {
		return false
	}
	intrinsics.mem_copy_non_overlapping(c.p, c.src[t.lo - u64(quoted):], n)
	c.p = c.p[n:]
	c.after = 2
	return true
}

// A container's open bracket. Its close bracket is two past it, in ASCII.
@(private)
open_bracket :: #force_inline proc "contextless" (k: core.Kind) -> u8 {
	return '[' | u8(k != .Array) << 5
}

// Enters the container `t` at row `i` once its open bracket is written, the byte `open`.
@(private)
push :: #force_inline proc "contextless" (c: ^Cursor, t: ^core.Token, i: u32, open: u8) #no_bounds_check {
	c.top += 1
	c.end = i + t.n
	c.stack[c.top] = {c.end, u32(open) + 2}
	c.after = 1
}

// Leaves the innermost container.
@(private)
pop :: #force_inline proc "contextless" (c: ^Cursor) #no_bounds_check {
	c.top -= 1
	c.end = c.stack[c.top].end
	c.after = 2
}

// The close of `rows_run` with no limit on the room or the depth.
@(private, cold)
rare_close :: proc(e: ^Emit) {
	settle(e)
	c := &e.c
	if c.after == 2 {
		write.put_line(e.out, e.opts, c.top - 1)
	}
	write.put_byte(e.out, u8(c.stack[c.top].close))
	pop(c)
	resume(e)
}

// A row of `rows_run` with no limit on the room or the depth, and every spelling. Returns the kind that refused the token, `.None`
// for a written one.
@(private, cold)
rare_row :: proc(e: ^Emit, t: core.Token, i: u32) -> core.Typed_Error_Kind {
	t := t
	c := &e.c
	k := t.kind
	if k >= .Array && c.top == e.cap {
		return .Too_Deep
	}
	settle(e)
	out := e.out
	if c.after == 2 {
		write.put_byte(out, ',')
	}
	if c.after != 0 {
		write.put_line(out, e.opts, c.top)
	}
	if k >= .Array {
		write.put_byte(out, open_bracket(k))
		push(c, &t, i, open_bracket(k))
	} else {
		if kind := put_token(out, e.src, e.doc, core.Node_Index(i), t, e.opts, true, e.copy); kind != .None {
			return kind
		}
		c.after = 2
		if t.role == .Key {
			write.put_text(out, ": " if e.opts.pretty else ":")
			c.after = 0
		}
	}
	resume(e)
	return .None
}

// A token at the output's cursor, in whatever spelling it takes: copied in pieces, spelled again, or a `Plain` cell. `own`
// says the token is JSON's, and `copy` that a string is written as it was authored.
@(private)
put_token :: proc(out: ^write.Out, src: []u8, doc: ^core.Document, i: core.Node_Index, t: core.Token, opts: core.Write_Options, own, copy: bool) -> core.Typed_Error_Kind {
	#partial switch t.kind {
	case .Null:
		write.put_text(out, "null")
	case .False:
		write.put_text(out, "false")
	case .True:
		write.put_text(out, "true")
	case .Number:
		write.put_text(out, string(src[t.lo:t.lo + u64(t.n)]))
	case:
		return put_token_string(out, src, doc, i, t, opts, own, copy)
	}
	return .None
}

// A string or a key: copied as authored when `copy` allows, else decoded and written by `put_string`.
@(private)
put_token_string :: proc(out: ^write.Out, src: []u8, doc: ^core.Document, i: core.Node_Index, t: core.Token, opts: core.Write_Options, own, copy: bool) -> core.Typed_Error_Kind {
	if copy && t.spelling & core.SPELLING_LAX == 0 {
		lo, hi := core.scalar_ends(t)
		write.put_text(out, string(src[lo:hi]))
		return .None
	}
	if own && t.spelling & core.SPELLING_DECODE == 0 {
		return put_string(out, string(src[t.lo:t.lo + u64(t.n)]), opts)
	}
	s, ok := core.text_clone(doc, i)
	if !ok {
		return .Out_Of_Memory
	}
	defer delete(s)
	return put_string(out, s, opts)
}

// Whether a string read from a source is written as it was authored under `opts`.
@(private)
copies_strings :: #force_inline proc "contextless" (opts: core.Write_Options) -> bool {
	return !opts.ascii && !opts.escape_html && !opts.respell_strings
}

// The handle of JSON of spec `spec` read with `opts`. As the target of `core.write`, `.Json` drops a document's comments,
// `.Jsonc` and `.Json5` keep them, and a JSON5 document is spelled again unless the target is `.Json5`. `dropped` counts
// the facts of `doc` that the target cannot hold, as `commit` does, and is not an error: a document of another format
// drops all its facts. A document read as JSON or JSONC keeps the spelling of its numbers and strings, and the bytes
// between them are made again: no whitespace in compact text, and the write options' in pretty text. A document of
// another format is written through its `text`, each cell what `core.resolve` reads it as. A partial document is written
// from the nodes its read kept: the text holds only what the read reached, an array's elements stand next to each other
// whatever their positions were, and an element that two paths reached through a ring of negative indexes is written
// once for each. A partial document keeps no comments. A document nested past `MAX_DEPTH` was built under a raised `max_depth` and is
// written, except one with comments, shared keys or `sort_keys` past 4096 levels, which is `.Too_Deep`.
as :: proc "contextless" (spec: Spec, opts := Options{}) -> core.As {
	return {spelling = &SPELLING, max_depth = opts.max_depth, spec = u8(spec), tolerate = transmute(u8)opts.tolerate}
}

// The size to ask the output for: the source, and for pretty text what eight levels of indent make on each node.
@(private)
document_hint :: proc(src, nodes: int, opts: core.Write_Options) -> int {
	hint := src + write.ROOM_MAX
	if opts.pretty {
		hint += nodes * (3 + 8 * (1 if opts.tab else int(opts.indent)))
	}
	return hint
}

// The spelling's `write`: node `node` of `doc`, which `core.write` checked is a value the document holds, as the spec
// `as` names.
@(private)
write_text :: proc(doc: ^core.Document, opts: core.Write_Options, as: core.As, node: core.Node_Index, stream: io.Stream, allocator: runtime.Allocator) -> (text: []u8, dropped: int, err: core.Typed_Error) {
	// The source bytes and the nodes the write covers. A partial document's node holds no span of its own text, so its
	// output grows from the least room.
	src, count := doc.src, len(doc.nodes)
	if node != core.ROOT {
		t := doc.nodes[node]
		src, count = nil if doc.partial else core.span(doc, node), 1 if t.kind < .Array else int(t.n)
	}
	hint := document_hint(len(src), count, opts)
	own := doc.spelling == &SPELLING
	if doc.partial || document_cold(doc, opts, own, node) {
		return write_tree(doc, opts, stream, allocator, .Json if doc.partial else Spec(as.spec), node, hint)
	}
	spill: [write.ROOM_MAX]u8 = ---
	out: write.Out
	write.init(&out, &spill, allocator, stream, hint)
	if dense_route(doc, opts, src, count) {
		write_dense(&out, src)
		text, err = write.finish((^write.Out)(rawptr(&out)))
		return
	}
	// The stack holds the open containers and the sentinel under them.
	local: [core.MAX_DEPTH + 1]Open = ---
	// A small source is copied to room past its end, so no row is near enough to the end to take the rare path.
	copied: [SRC_COPY + COPY_ROOM]u8 = ---
	read := doc.src
	if len(read) <= SRC_COPY {
		copy(copied[:], read)
		intrinsics.mem_zero(raw_data(copied[len(read):]), COPY_ROOM)
		read = copied[:len(read) + COPY_ROOM]
	}
	e: Emit
	if !put_start(&e, &out, read, doc, opts, local[:], core.reserve_depth(doc.as.max_depth, len(doc.nodes))) {
		write.destroy(&out)
		return nil, 0, {kind = .Out_Of_Memory}
	}
	defer put_end(&e)
	if kind := rows(&e, doc, u32(node)); kind != .None {
		write.destroy(&out)
		return nil, 0, {kind = kind}
	}
	settle(&e)
	text, err = write.finish((^write.Out)(rawptr(&out)))
	return
}

// The first row `rows_run` leaves to the rare path because a block copy of it or a later row would load past the source.
// Scalar rows are in source order, so one that fits has only fitting rows before it.
@(private)
rows_stop :: proc(doc: ^core.Document, room: int) -> u32 {
	stop := len(doc.nodes)
	for ; stop > 0; stop -= 1 {
		t := &doc.nodes[stop - 1]
		if t.kind < .Array && t.role != .Key && t.lo + max(u64(t.n), COPY_MIN) + 16 <= u64(room) {
			break
		}
	}
	return u32(stop)
}

// Writes the rows of the subtree at `node`: `rows_run` over chunks of them that the output's room holds, and by the rare
// path each row it stops at.
// A chunk's room counts every row at `1 << ROW_ROOM_SHIFT` and the closes of the containers open at its start, so no row tests room.
// A chunk starts on a row inside the innermost container, the one state `rows_run` can stop in and account for: the close
// of a container that ends at `i`, an empty one the rare path opened among them, is `rare_close`'s.
@(private)
rows :: proc(e: ^Emit, doc: ^core.Document, node: u32) -> core.Typed_Error_Kind {
	count := u32(len(doc.nodes))
	// No chunk runs past the subtree, since `rows_run` writes on past the close of the container it entered first.
	stop := min(rows_stop(doc, len(e.src)), node + (1 if doc.nodes[node].kind < .Array else doc.nodes[node].n))
	c := &e.c
	if kind := rare_row(e, doc.nodes[node], node); kind != .None {
		return kind
	}
	i := node + 1
	for c.top > 0 {
		if c.safe != 0 && i < stop && c.stack[c.top].end != i {
			free := int(uintptr(e.out.buf) + uintptr(e.out.size) - uintptr(c.p)) - c.top * (c.top * c.unit + 2)
			if chunk := free >> ROW_ROOM_SHIFT; chunk > 0 {
				c.stop = u32(min(int(i) + chunk, int(stop)))
				// A chunk ends on a value, since a key's value is written with its key.
				if doc.nodes[c.stop - 1].role == .Key {
					c.stop += 1
				}
				c.bytes = c.top * c.unit
				c.end = min(c.stack[c.top].end, c.stop)
				// What is owed before row `i`, as `after` says.
				pretty := e.opts.pretty
				if c.after == 2 {
					_ = past_value(c, i, true) if pretty else past_value(c, i, false)
				} else if c.after == 1 && pretty {
					c.p = put_line(c, c.p, 1 + c.bytes)
				}
				c.after = 0
				next: u32
				switch {
				case pretty && e.copy:
					next = rows_run(e, i, true, false)
				case pretty:
					next = rows_run(e, i, true, true)
				case e.copy:
					next = rows_run(e, i, false, false)
				case:
					next = rows_run(e, i, false, true)
				}
				if next != i {
					i = next
					continue
				}
			}
		}
		if c.stack[c.top].end == i {
			rare_close(e)
		} else if i == count {
			break
		} else {
			if !copy_long(e, doc.nodes[i]) {
				if kind := rare_row(e, doc.nodes[i], i); kind != .None {
					return kind
				}
			}
			i += 1
		}
	}
	return .None
}

// Closes every container that ends before row `i` and writes what comes before that row. Returns false with `after` set
// when `i` is where the chunk stops. `c.end` is held at `c.stop`, so this is the one test a row takes.
@(private)
past_value :: #force_inline proc "contextless" (c: ^Cursor, i: u32, $P: bool) -> bool #no_bounds_check {
	p := c.p
	for c.end == i {
		if i >= c.stop {
			c.p = p
			c.after = 2
			return false
		}
		when P {
			c.bytes -= c.unit
			p = put_line(c, p, 1 + c.bytes)
		}
		p[0] = u8(c.stack[c.top].close)
		p = p[1:]
		c.top -= 1
		c.end = min(c.stack[c.top].end, c.stop)
	}
	when P {
		n := 2 + c.bytes
		intrinsics.unaligned_store((^V)(p), c.comma)
		for k := 16; k < n; k += 16 {
			intrinsics.unaligned_store((^V)(p[k:]), c.fill)
		}
		c.p = p[n:]
	} else {
		p[0] = ','
		c.p = p[1:]
	}
	return true
}

// The rows from row `i`, with nothing owed before it, up to `c.stop`, a row and its key at a time. A value is written
// with its key, with no test between. Returns the row it stopped at, and `after` says what is owed before it. It calls
// nothing and holds the cursor in a local, so the loop keeps every value in a register. The entry is apart from the loop
// because a second inlined `past_value` joins the loop's head to it, and the constants are made again on every row.
@(private)
rows_run :: #force_no_inline proc "contextless" (e: ^Emit, i: u32, $P, $O: bool) -> u32 #no_bounds_check {
	// `kind`, `role` and `spelling` are one word of a token, and a key is always a string.
	KEY_MASK :: u32(0xFFFF) | u32(core.SPELLING_LAX) << 16
	KEY_WORD :: u32(core.Kind.String) | u32(core.Role.Key) << 8
	#assert(offset_of(core.Token, role) == offset_of(core.Token, kind) + 1)
	#assert(offset_of(core.Token, spelling) == offset_of(core.Token, kind) + 2)
	c := e.c
	nodes := raw_data(e.doc.nodes)
	src := c.src
	i := i
	loop: {
		p := c.p
		for {
			t := &nodes[i]
			w := (^u32)(&t.kind)^
			if w & KEY_MASK == KEY_WORD {
				n := t.n + 2
				when O {
					if !plain_string(e, src[t.lo - 1:], n) {
						break
					}
				}
				if !copy_token(p, src[t.lo - 1:], n) {
					break
				}
				p = p[n:]
				when P {
					intrinsics.unaligned_store((^u16)(p), u16(':') | u16(' ') << 8)
					p = p[2:]
				} else {
					p[0] = ':'
					p = p[1:]
				}
				i += 1
				t = &nodes[i]
				w = (^u32)(&t.kind)^
			}
			// A string's quotes are the bytes around its span. One branch takes a container and a string with an
			// ill-formed sequence, the kinds past `Plain` being the two with both of these bits.
			#assert(u8(core.Kind.String) == 4 && u8(core.Kind.Number) < 4 && u8(core.Kind.Plain) == 5 && u8(core.Kind.Array) == 6 && u8(core.Kind.Map) == 7)
			quoted := (w >> 2) & 1
			if ((w & 0xFF) + 2) >> 3 | (quoted & (w >> 18)) != 0 {
				k := t.kind
				if k < .Array {
					break
				}
				open := open_bracket(k)
				p[0] = open
				if t.n == 1 {
					p[1] = open + 2
					p = p[2:]
				} else {
					if c.top >= c.limit {
						break
					}
					end := i + t.n
					c.top += 1
					c.stack[c.top] = {end, u32(open) + 2}
					c.end = min(end, c.stop)
					i += 1
					p = p[1:]
					when P {
						c.bytes += c.unit
						p = put_line(&c, p, 1 + c.bytes)
					}
					if i >= c.stop {
						break
					}
					continue
				}
			} else {
				n := t.n + 2 * quoted
				when O {
					if quoted != 0 && !plain_string(e, src[t.lo - 1:], n) {
						break
					}
				}
				if !copy_token(p, src[t.lo - u64(quoted):], n) {
					break
				}
				p = p[n:]
			}
			i += 1
			c.p = p
			if !past_value(&c, i, P) {
				break loop
			}
			p = c.p
		}
		c.p = p
	}
	e.c = c
	return i
}

// Reads `src` as spec `S` and writes it in `S` as `opts` says. A string and a number keep their source spelling.
// `read.max_depth` bounds the nesting, and a tolerated ill-formed string is written as the reading decodes it. The text is
// built into a document and written as `core.write` writes it. A text that is not a document of `S` is refused as `.Walk`,
// with the fault in `inner`.
format :: proc(src: []u8, $S: Spec, opts := core.Write_Options{}, read := Options{}, allocator := context.allocator) -> ([]u8, core.Typed_Error) {
	doc, err := build_spec(src, S, read, false, allocator)
	if err.kind != .None {
		return nil, {kind = .Walk if err.kind == .Walk else .Out_Of_Memory, at = err.at, inner = err.inner}
	}
	defer core.destroy(&doc)
	text, _, werr := write_text(&doc, opts, {spec = u8(S)}, core.ROOT, {}, allocator)
	return text, werr
}
