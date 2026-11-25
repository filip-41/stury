package json

import "base:intrinsics"
import "stury:lib/base/kernel"
import "stury:lib/core/tape"
import "stury:lib/ops/write"

// The write of a document read whole as JSON, JSONC or JSON5, with no table: its rows in document order, each container
// closed where its subtree ends, on a stack of its own. `rows_run` holds the common case, calls nothing, and copies each
// token from the source in 16-byte blocks over chunks of rows the output's room holds. `rows_rare` and `rows_close`
// write each row it stops at: a long token, a deep line, a row whose block copy would read past the source, a string
// the target respells. A document with facts the target writes ends a chunk before each value that holds one, and
// before the close of each container that holds a foot or inline comment. `rows_fact_value` and `rows_fact_close`
// write those as the walk's layout loop does, with their comments.

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

// What a string of the document is to the rows route: `Json` a span between its quotes as written, `Ascii` that too
// where it is all ASCII, which sends any other to the rare path, and `Json5` a span between its own quotes, or a bare
// key, which a plain scalar is not.
@(private)
Rows_Text :: enum {
	Json,
	Ascii,
	Json5,
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
// the rare path: a token is copied in blocks of 16 bytes, at least 32 bytes, from the byte before its span.
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
// document's scalars spell the same in every target, so the rare path writes them as JSON's. With `facts` a chunk ends
// before each value that holds facts and the close of each container that writes some there, and the facts path of
// `spec` writes them.
@(private)
write_rows :: proc(out: ^write.Out, w: ^write.Tree, l: ^Layout, $PRETTY: bool, $WIDTH: int, $TEXT: Rows_Text, facts: bool, spec: Spec) #no_bounds_check {
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
	f := Rows_Facts{spec = spec}
	if facts {
		f.frames = make([dynamic]Fact_Container, w.allocator)
	}
	defer delete(f.frames)
	i := w.i
	f.row = write.fact_row(w, i) if facts else max(tape.Node_Index)
	ok: bool
	i, ok = rows_row(out, w, l, &r, &held, &f, i, PRETTY, TEXT)
	if !ok {
		return
	}
	for r.top > 0 && out.err == nil {
		if facts {
			f.row = write.fact_row(w, i)
		}
		if r.stack[r.top].end != i && i < stop && r.top <= line_at && l.pending == nil {
			when PRETTY {
				r.limit = min(r.top + ROW_HEADROOM, line_at, held - 1)
				row_room := 3 * (r.limit * width + 18) + 2 * (ROW_TOKEN + 32) + 8
				owed := r.top * (r.top * width + 18)
			} else {
				// The rare path grows the stack, so the limit follows it.
					r.limit = min(line_at, held - 1)
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
				if facts {
					r.stop = min(r.stop, f.row, fact_container_end(&f))
				}
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
					next := rows_run(&r, nodes, src, i, PRETTY, WIDTH, TEXT)
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
			if facts && (l.pending != nil || fact_container_closes(&f, r.top)) {
				rows_fact_close(out, w, l, &r, &f, PRETTY)
			} else {
				rows_close(out, l, &r, PRETTY)
			}
		} else {
			i, ok = rows_row(out, w, l, &r, &held, &f, i, PRETTY, TEXT)
			if !ok {
				return
			}
		}
	}
	if facts && out.err == nil {
		rows_fact_end(out, w, l, f.spec, PRETTY)
	}
}

// The rows from row `i`, with nothing owed before it, up to `c.stop`, a row and its key at a time. A value is written
// with its key, with no test between. Returns the row it stopped at, and `after` says what is owed before it. It calls
// nothing and holds the cursor in a local, so the loop keeps every value in a register.
@(private)
rows_run :: #force_no_inline proc "contextless" (r: ^Rows, nodes: [^]tape.Node, src: [^]u8, i: tape.Node_Index, $PRETTY: bool, $WIDTH: int, $TEXT: Rows_Text) -> tape.Node_Index #no_bounds_check {
	// `kind`, `role` and `spelling` are one word of a node, and a JSON key is a string. The route holds no string a
	// tolerance read, and under `ascii` a string with no ASCII mark goes to the rare path, which respells it.
	when TEXT == .Ascii {
		KEY_MASK :: u32(0xFFFF) | u32(tape.SPELLING_ASCII) << 16
		KEY_WORD :: u32(tape.Kind.String) | u32(tape.Role.Key) << 8 | u32(tape.SPELLING_ASCII) << 16
	} else {
		KEY_MASK :: u32(0xFFFF)
		KEY_WORD :: u32(tape.Kind.String) | u32(tape.Role.Key) << 8
	}
	#assert(tape.SPELLING_QUOTED == 2 && tape.SPELLING_ASCII == 16)
	#assert(tape.Kind.String == tape.Kind(5) && tape.Kind.Plain == tape.Kind(6))
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
				// A JSON5 key may be bare, with no quote on either side.
				head := (word >> 17) & 1 when TEXT == .Json5 else u32(1)
				n := t.n + 2 * head
				if !copy_token(p, src[t.lo - u64(head):], n) {
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
			// One test takes a container and a string the target must respell: a kind past `Plain`, or under `ascii` a
			// quoted kind with no ASCII mark, or in JSON5 a plain scalar, which is no quoted span.
			quoted := (word >> 2) & 1
			odd := u32(0)
			when TEXT == .Ascii {
				odd = quoted & ~(word >> 20)
			} else when TEXT == .Json5 {
				odd = quoted & (word >> 1)
			}
			if ((word & 0xFF) + 1) >> 3 | odd != 0 {
				// A lax string is rarer than a container, and its test laid out between them delays every open.
				// A container a read kept part of is refused on the rare path.
				if intrinsics.expect(word & 0xFF < u32(tape.Kind.Array) || word >> 16 & u32(tape.CONTAINER_PARTIAL) != 0, false) {
					break
				} else {
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
						}
						if i >= c.stop {
							// The line of the first child is owed.
							c.after = 1
							break
						}
						when PRETTY {
							p = line_start(p, c.head, c.fill, 1 + c.bytes)
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
rows_rare :: #force_no_inline proc(out: ^write.Out, w: ^write.Tree, l: ^Layout, r: ^Rows, held: ^int, i: tape.Node_Index, $PRETTY: bool, $SPEC: Spec) -> bool {
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
	if t.role == .Key {
		if !put_key(out, w, l, i, SPEC) {
			return false
		}
		put_colon(out, PRETTY)
		r.after = 0
		return true
	}
	r.after = 2
	return rows_scalar(out, w, l, i, SPEC)
}

// `put_scalar` of row `i`, out of line. Its number branch writes the token's span as written, through `tape.span_bytes`,
// whose two slice checks a build that checks bounds carries, and one copy serves every row the rare path writes rather
// than one per `rows_rare` instance. The span is in bounds by the document's own invariant: a node's `lo` and `n` name
// bytes of `w.doc.src` from its first byte, so `src[lo:][:n]` ends at `lo + n <= len(src)`, and its `lo` is at most the
// text's length, which `span_bytes` reads past only to compare.
@(private, cold)
rows_scalar :: #force_no_inline proc(out: ^write.Out, w: ^write.Tree, l: ^Layout, i: tape.Node_Index, $SPEC: Spec) -> bool {
	return put_scalar(out, w, l, i, SPEC)
}

// `step_value` of the facts path, out of line for the reason `rows_scalar` gives: `put_scalar` writes a number's span
// through `tape.span_bytes`, and the checks of its two slices belong in one copy of the step, not in each
// `rows_fact_value`. The scalar's span is in bounds as `rows_scalar` says.
@(private, cold)
rows_fact_step :: #force_no_inline proc(out: ^write.Out, w: ^write.Tree, l: ^Layout, s: write.Step, $T: Spec, $PRETTY: bool) -> bool {
	return step_value(out, w, l, s, T, true, false, PRETTY)
}

// A container with facts the rows route has open, whose facts are written at its close.
@(private)
Fact_Container :: struct {
	end:   tape.Node_Index,
	level: int, // its place on the stack of rows
	facts: []tape.Fact,
}

// What the rows route of a document with facts keeps beside its rows.
@(private)
Rows_Facts :: struct {
	spec:   Spec,
	row:    tape.Node_Index, // the first row from the one being written whose value holds facts, else the largest
	frames: [dynamic]Fact_Container, // the open containers with facts, the innermost last
}

// Where the innermost open container with facts ends, else the largest index.
@(private)
fact_container_end :: #force_inline proc "contextless" (f: ^Rows_Facts) -> tape.Node_Index {
	if n := len(f.frames); n > 0 {
		return f.frames[n - 1].end
	}
	return max(tape.Node_Index)
}

// Whether the container at `level` of the stack of rows has facts.
@(private)
fact_container_closes :: #force_inline proc "contextless" (f: ^Rows_Facts, level: int) -> bool {
	n := len(f.frames)
	return n > 0 && f.frames[n - 1].level == level
}

// Whether any of `facts` is a comment that follows its value on its line.
@(private)
holds_inline :: proc "contextless" (facts: []tape.Fact) -> bool {
	for f in facts {
		if f.kind == .Comment_Inline {
			return true
		}
	}
	return false
}

// Whether any of the facts of a container is written at its close: a foot comment, or an inline one after it. Its lead
// comments are written at its open, and its close is like any other's.
@(private)
writes_at_close :: proc "contextless" (facts: []tape.Fact) -> bool {
	for f in facts {
		if f.kind == .Comment_Inline || f.kind == .Comment_Foot {
			return true
		}
	}
	return false
}

// Writes row `i`, and a member's value with its key, and returns the row after. A row that holds facts, or that follows
// a value whose comments are owed, takes the facts path.
@(private)
rows_row :: proc(out: ^write.Out, w: ^write.Tree, l: ^Layout, r: ^Rows, held: ^int, f: ^Rows_Facts, i: tape.Node_Index, $PRETTY: bool, $TEXT: Rows_Text) -> (next: tape.Node_Index, ok: bool) {
	if i == f.row || l.pending != nil {
		return rows_fact_value(out, w, l, r, held, f, i, PRETTY)
	}
	return i + 1, rows_rare(out, w, l, r, held, i, PRETTY, Spec.Json5 when TEXT == .Json5 else Spec.Json)
}

// `rows_fact_value_as` for the spec of the write.
@(private, cold)
rows_fact_value :: #force_no_inline proc(out: ^write.Out, w: ^write.Tree, l: ^Layout, r: ^Rows, held: ^int, f: ^Rows_Facts, i: tape.Node_Index, $PRETTY: bool) -> (tape.Node_Index, bool) {
	if f.spec == .Jsonc {
		return rows_fact_value_as(out, w, l, r, held, f, i, .Jsonc, PRETTY)
	}
	return rows_fact_value_as(out, w, l, r, held, f, i, .Json5, PRETTY)
}

// Writes the value of row `i`, or the member whose key it is, as the layout loop of `write_tree` does, with the comments
// on it, and opens its container. Returns the row after, and false with `w.err` set when it cannot.
@(private)
rows_fact_value_as :: proc(out: ^write.Out, w: ^write.Tree, l: ^Layout, r: ^Rows, held: ^int, f: ^Rows_Facts, i: tape.Node_Index, $T: Spec, $PRETTY: bool) -> (tape.Node_Index, bool) {
	at, key := i, tape.NO_NODE
	if w.nodes[i].role == .Key {
		key, at = i, i + 1
	}
	t := w.nodes[at]
	if t.kind >= .Array {
		if t.spelling & tape.CONTAINER_PARTIAL != 0 {
			w.err = write.Refused{at, .Partial}
			return i, false
		}
		if r.top + 1 == held^ && !write.grow_stack(&r.stack, held, ROW_LEVELS, w.allocator, &w.err) {
			return i, false
		}
	}
	s := write.value_step(w, at, key, r.top, r.after != 2)
	l.line_value, l.wrote = r.after == 2, r.top > 0 || r.after != 0
	if !rows_fact_step(out, w, l, s, T, PRETTY) {
		return i, false
	}
	if t.kind < .Array {
		r.after = 2
		if !holds_inline(l.pending) {
			l.pending = nil
		}
		return at + 1, true
	}
	open := bracket_of(t.kind)
	r.top += 1
	r.stack[r.top] = {at + tape.Node_Index(t.n), u32(open) + 2}
	r.after = 1
	if writes_at_close(s.facts) {
		if _, err := append(&f.frames, Fact_Container{end = at + tape.Node_Index(t.n), level = r.top, facts = s.facts}); err != nil {
			w.err = err
			return i, false
		}
	}
	return at + 1, true
}

// `rows_fact_close_as` for the spec of the write.
@(private, cold)
rows_fact_close :: #force_no_inline proc(out: ^write.Out, w: ^write.Tree, l: ^Layout, r: ^Rows, f: ^Rows_Facts, $PRETTY: bool) {
	if f.spec == .Jsonc {
		rows_fact_close_as(out, w, l, r, f, .Jsonc, PRETTY)
	} else {
		rows_fact_close_as(out, w, l, r, f, .Json5, PRETTY)
	}
}

// Writes the close of the innermost container as the layout loop of `write_tree` does, with the comments before it, and
// its own after.
@(private)
rows_fact_close_as :: proc(out: ^write.Out, w: ^write.Tree, l: ^Layout, r: ^Rows, f: ^Rows_Facts, $T: Spec, $PRETTY: bool) {
	s := write.Step{depth = r.top - 1, kind = .Close, first = r.after == 1}
	if fact_container_closes(f, r.top) {
		s.facts = f.frames[len(f.frames) - 1].facts
		pop(&f.frames)
	}
	l.line_value, l.wrote = r.after == 2, true
	step_close(out, w, l, s, u8(r.stack[r.top].close), T, true, PRETTY)
	if !holds_inline(l.pending) {
		l.pending = nil
	}
	r.top -= 1
	r.after = 2
}

// The comments after the last value of the text, for the spec of the write.
@(private, cold)
rows_fact_end :: #force_no_inline proc(out: ^write.Out, w: ^write.Tree, l: ^Layout, spec: Spec, $PRETTY: bool) {
	if w.err != nil {
		return
	}
	if spec == .Jsonc {
		end_comments(out, w, l, .Jsonc, PRETTY)
	} else {
		end_comments(out, w, l, .Json5, PRETTY)
	}
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
