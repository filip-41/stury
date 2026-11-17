package toml

// The token write of TOML. TOML fixes an order the calls cannot know, since a table's keys stand before the sections of
// its tables, so the calls write the value as an inline table, and `end` lays it out in one pass, `lay_out_inline`. A text
// that pass does not read is read back behind `r = ` and laid out as `write_document.odin` does. A write that stands at a site of a document is the inline text as it is. Null is a word
// TOML has no reading for, so a write that holds one is `.Unwritable`, and a write to a stream is `.Unsupported`, since
// `end` has the whole text to lay out only in a buffer.

import "base:runtime"
import "core:io"
import "core:strings"
import core "../core"
import typed "../core/typed"
import write "../core/write"

@(private)
TREE :: write.Tree {
	.Open_Object  = "{",
	.Close_Object = "}",
	.Open_Array   = "[",
	.Close_Array  = "]",
	.Comma        = ",",
	.Colon        = "=",
	.After_Colon  = " ",
	.Null         = "null",
	.True         = "true",
	.False        = "false",
	.Point_Zero   = ".0",
	.Inf          = "inf",
	.Neg_Inf      = "-inf",
	.Nan          = "nan",
	.Heads        = "",
	.Bytes_Tag    = "",
}

// The number spellings of TOML past JSON's.
@(private)
NUMBER_FORMS :: write.Number_Forms{.Hex, .Octal, .Binary, .Plus}

@(private, rodata)
TOKENS := write.Token_Spelling {
	tree = TREE,
	// A whole text is written behind a key that `end` puts at `mark`, after the root's comments, and lays out. `state`
	// records it.
	start = proc(t: ^write.Tokens, _: core.As) -> core.Typed_Error_Kind {
		// The text is laid out once it is whole, and a stream has taken its bytes by then.
		if t.out.stream.procedure != nil {
			return .Unsupported
		}
		// An inline table is one line, and the layout of the document is the writer's own, so the calls never indent.
		t.opts.pretty = false
		if !t.site.placed {
			t.state = rawptr(&TOKENS)
		}
		return .None
	},
	value = proc(t: ^write.Tokens, v: write.Scalar) -> core.Typed_Error_Kind {
		switch x in v {
		case string:
			return put_basic(t.out, x, t.opts)
		case typed.Bytes:
			stack: [512]u8
			text, ok := write.bytes_text(cast([]u8)x, stack[:])
			return put_basic(t.out, text, t.opts) if ok else .No_Memory
		case core.Number:
			return write.put_number(t.out, x, TREE)
		case write.Number_Literal:
			write.put_text(t.out, x.text)
		case write.Tagged_Text:
			// A tag that is no TOML type leaves a string, and so does another format's datetime that no TOML one spells.
			tag := DATETIME_TAGS[x.meaning] if x.meaning != .Own else x.tag
			if tag != "" && tag_datetime(tag) == .Own || x.meaning != .Own && text_datetime(x.text) != x.meaning {
				return put_basic(t.out, x.text, t.opts)
			}
			return put_datetime(t.out, x.text, tag)
		case write.Tree_Part:
			write.put_text(t.out, t.spell.tree[x])
		}
		return .None
	},
	end = proc(t: ^write.Tokens, bytes: []u8) -> ([]u8, core.Typed_Refusal) {
		if t.state == nil {
			if t.site.placed {
				return inline_text(bytes, t.base.allocator)
			}
			return bytes, {}
		}
		return lay_out_text(bytes, t.mark, t.opts, {}, t.base.allocator)
	},
	// The calls build an inline table that `end` reads back as TOML 1.1, whose inline table holds a comment on a line of
	// its own, and writes as a 1.0 text. An inline comment that follows one on the same item joins it.
	comment = proc(t: ^write.Tokens, role: core.Role, text: string) -> core.Typed_Error_Kind {
		if !write.comment_lines_ok(text) {
			return .Unwritable
		}
		if _, joins := write.inline_tail(t); joins && role == .Comment_Inline && strings.index_byte(text, '\n') < 0 {
			t.out.cursor -= 1
			write.put_text(t.out, " " if len(text) > 0 else "")
			write.put_text(t.out, text)
			write.put_byte(t.out, '\n')
			return .None
		}
		write.put_byte(t.out, ' ' if role == .Comment_Inline else '\n')
		write.put_comment(t.out, "#", text, true, 0)
		write.put_byte(t.out, '\n')
		if t.top == 0 && role == .Comment {
			t.mark = t.out.cursor
		}
		return .None
	},
}

@(private)
put_plain :: proc(out: ^write.Out, _: [^]u8, s: string, opts: ^core.Write_Options) -> core.Typed_Error_Kind {
	return put_basic(out, s, opts^)
}

@(private)
put_key_plain :: proc(out: ^write.Out, _: [^]u8, s: string, _: ^core.Write_Options) -> core.Typed_Error_Kind {
	return put_key(out, s)
}

// The plan's `marshal`: the value as an inline table on one line, with its keys as a section writes them, laid out as a
// document. A value that is no table is `.Unwritable`.
@(private)
marshal_text :: proc(plan: ^typed.Plan, value: rawptr, opts: core.Write_Options, stream: io.Stream, allocator: runtime.Allocator, omits: ^typed.Omits) -> ([]u8, core.Typed_Refusal) {
	line := opts
	line.pretty = false
	bytes, err := write.marshal_keyed(plan, value, line, {}, allocator, TREE, put_plain, put_plain, put_key_plain, omits)
	if err.kind != .None {
		return nil, err
	}
	return lay_out_text(bytes, 0, opts, stream, allocator)
}

// The value `bytes` holds, spelled as the inline value the document writer puts in a line: bare keys, a space inside
// the braces and after each comma.
@(private)
inline_text :: proc(bytes: []u8, allocator: runtime.Allocator) -> ([]u8, core.Typed_Refusal) {
	keyed, made := keyed_text(bytes, 0, allocator)
	if !made {
		return nil, {kind = .No_Memory}
	}
	defer delete(keyed, allocator)
	doc, berr := build_text(keyed, bound_as(.Toml_1_0), context.allocator)
	defer core.destroy(&doc)
	if berr.kind != .None {
		return nil, {kind = .Unwritable if berr.kind == .Walk else .No_Memory}
	}
	it := core.pairs(&doc, core.ROOT)
	_, value, found := core.pair_next(&it)
	if !found {
		return nil, {kind = .Unwritable}
	}
	spill: [write.ROOM_MAX]u8 = ---
	l := Layout{doc = &doc, own = true}
	l.arena.backing_allocator = context.allocator
	defer runtime.arena_destroy(&l.arena)
	l.path.allocator = runtime.arena_allocator(&l.arena)
	write.init(&l.out, &spill, allocator)
	kind := put_inline(&l, value)
	return write.finish(&l.out, {kind = kind})
}

// A section the one-pass layout has open: a table, whose header and lines go to segment `seg`, or an array of tables,
// whose elements open the next sections. `path` counts the keys of `Inline_Layout.path` that name it.
@(private)
Laid_Section :: struct {
	seg:    i32,
	path:   i32,
	headed: bool, // its header is written, or it has none
	opened: bool, // a section was opened inside it
	array:  bool,
}

// Whether a segment starts with a header, and whether a blank line it wrote stands before that.
@(private)
Laid_Segment :: struct {
	headed: bool,
	blank:  bool,
}

// Bytes `lo` to `hi` of the store, written while segment `seg` was the innermost open table's.
@(private)
Laid_Chunk :: struct {
	seg:    i32,
	lo, hi: int,
}

// The one-pass layout of an inline table. A segment is a table's header and lines, the bytes of the store written while
// it is the innermost open table, in more than one chunk when a line follows a section in its table. The segments
// stand in the text in the order they opened.
@(private)
Inline_Layout :: struct {
	store:  write.Out,
	src:    []u8,
	path:   ^[core.MAX_DEPTH]string,
	cur:    i32, // the segment being written
	lo:     int, // where its chunk began in the store
	last:   i32, // the latest segment a chunk was kept for
	moved:  bool, // a chunk was kept after one of a later segment, so the store is not in the text's order
	err:    core.Typed_Error_Kind,
	segs:   [dynamic]Laid_Segment,
	chunks: [dynamic]Laid_Chunk,
}

// Writes `src`, an inline table on one line with its keys as `put_key` writes them, as a TOML text laid out as
// `write_table_text` lays out a table, in one pass with no document. A text in a form it does not read, which a raw
// value, a comment, a null or an integer past 64 bits gives, is `declined`, and `src` is kept then.
@(private)
lay_out_inline :: proc(src: []u8, stream: io.Stream, allocator: runtime.Allocator) -> (text: []u8, err: core.Typed_Refusal, declined: bool) {
	if len(src) < 2 || src[0] != '{' {
		return nil, {}, true
	}
	spill: [write.ROOM_MAX]u8 = ---
	path: [core.MAX_DEPTH]string = ---
	open: [core.MAX_DEPTH]Laid_Section = ---
	l := Inline_Layout{src = src, path = &path}
	l.segs.allocator, l.chunks.allocator = context.allocator, context.allocator
	defer delete(l.segs)
	defer delete(l.chunks)
	direct := stream.procedure == nil
	write.init(&l.store, &spill, allocator if direct else context.allocator, hint = len(src) + len(src) / 4 + write.ROOM_MAX)
	if !lay_sections(&l, &open) {
		write.destroy(&l.store)
		return nil, {}, true
	}
	laid_chunk(&l, 0)
	if l.err != .None {
		write.destroy(&l.store)
		return nil, {kind = l.err}, false
	}
	if !l.moved && direct {
		text, err = write.finish(&l.store)
		return text, err, false
	}
	defer write.destroy(&l.store)
	out: write.Out
	write.init(&out, &spill, allocator, stream, l.store.cursor + write.ROOM_MAX)
	laid_join(&l, &out)
	text, err = write.finish(&out, {kind = l.err})
	return text, err, false
}

// Writes the sections of `l.src` from its root to the store. False when the text is in a form this layout does not read.
@(private)
lay_sections :: proc(l: ^Inline_Layout, open: ^[core.MAX_DEPTH]Laid_Section) -> bool {
	src := l.src
	laid_segment(l)
	open[0] = {headed = true}
	top := 0
	for i := 1; l.err == .None; {
		f := &open[top]
		c := peek(src, i)
		if f.array {
			if c == ']' {
				top -= 1
				laid_chunk(l, open[top].seg)
				i += 1
				continue
			}
			if c == ',' {
				i += 1
				c = peek(src, i)
			}
			if c != '{' || top + 1 == core.MAX_DEPTH {
				return false
			}
			top += 1
			open[top] = {seg = laid_segment(l), path = f.path, headed = true}
			laid_header(l, f.path, true)
			i += 1
			continue
		}
		if c == '}' {
			i += 1
			if !f.headed && !f.opened {
				laid_header(l, f.path, false)
			}
			if top == 0 {
				return i == len(src)
			}
			top -= 1
			if !open[top].array {
				laid_chunk(l, open[top].seg)
			}
			continue
		}
		if c == ',' {
			i += 1
		}
		key, after := laid_key(src, i)
		if after < 0 || peek(src, after) != '=' {
			return false
		}
		i = after + 1
		c = peek(src, i)
		if c == '{' || c == '[' && peek(src, i + 1) == '{' {
			if top + 1 == core.MAX_DEPTH {
				return false
			}
			f.opened = true
			l.path[f.path] = key
			top += 1
			open[top] = {path = f.path + 1, array = c == '['}
			if c == '{' {
				open[top].seg = laid_segment(l)
			}
			i += 1
			continue
		}
		if !f.headed {
			laid_header(l, f.path, false)
			f.headed = true
		}
		write.put_text(&l.store, key)
		write.put_text(&l.store, " = ")
		if i = laid_inline(l, i, top); i < 0 {
			return false
		}
		write.put_byte(&l.store, '\n')
	}
	return true
}

@(private)
peek :: #force_inline proc "contextless" (src: []u8, i: int) -> u8 {
	return src[i] if i < len(src) else 0
}

// Opens a segment and makes it the one written.
@(private)
laid_segment :: proc(l: ^Inline_Layout) -> i32 {
	seg := i32(len(l.segs))
	if _, failed := append(&l.segs, Laid_Segment{}); failed != nil {
		l.err = .No_Memory
	}
	laid_chunk(l, seg)
	return seg
}

// Keeps the chunk of the segment being written, if it holds a byte, and starts one of `seg`.
@(private)
laid_chunk :: proc(l: ^Inline_Layout, seg: i32) {
	if l.store.cursor > l.lo {
		l.moved ||= l.cur < l.last
		l.last = max(l.last, l.cur)
		if _, failed := append(&l.chunks, Laid_Chunk{l.cur, l.lo, l.store.cursor}); failed != nil {
			l.err = .No_Memory
		}
	}
	l.cur, l.lo = seg, l.store.cursor
}

// The header `[a.b]` or `[[a.b]]` of the first `depth` keys of the path, after a blank line unless it is the store's first.
@(private)
laid_header :: proc(l: ^Inline_Layout, depth: i32, element: bool) {
	if l.err != .None {
		return
	}
	seg := &l.segs[l.cur]
	seg.headed = true
	if l.store.cursor > 0 {
		write.put_byte(&l.store, '\n')
		seg.blank = true
	}
	write.put_text(&l.store, "[[" if element else "[")
	for k in 0 ..< depth {
		if k > 0 {
			write.put_byte(&l.store, '.')
		}
		write.put_text(&l.store, l.path[k])
	}
	write.put_text(&l.store, "]]\n" if element else "]\n")
}

// The key at `i` as `put_key` writes it, and the offset past it, -1 when it is no key this layout reads. A quoted key with
// no escape whose bytes are bare is bare.
@(private)
laid_key :: proc(src: []u8, i: int) -> (string, int) {
	if peek(src, i) != '"' {
		j := i
		for j < len(src) && bare_byte(src[j]) {
			j += 1
		}
		return string(src[i:j]), j if j > i else -1
	}
	bare := true
	j := i + 1
	for ; j < len(src) && src[j] != '"'; j += 1 {
		if src[j] == '\\' {
			return "", -1
		}
		bare &&= bare_byte(src[j])
	}
	if j == len(src) {
		return "", -1
	}
	if bare && j > i + 1 {
		return string(src[i + 1:j]), j + 1
	}
	return string(src[i:j + 1]), j + 1
}

// Writes the value at `i` in line, as `put_inline` spells it, and returns the offset past it, -1 when it is in a form this
// layout does not read. Its containers nest inside the `top` open sections.
@(private)
laid_inline :: proc(l: ^Inline_Layout, at: int, top: int) -> int {
	src, out := l.src, &l.store
	objects: [core.MAX_DEPTH]bool = ---
	depth := 0
	i := at
	for {
		switch c := peek(src, i); c {
		case '{', '[':
			if peek(src, i + 1) == c + 2 {
				write.put_text(out, "{}" if c == '{' else "[]")
				i += 2
				break
			}
			if top + depth + 1 >= core.MAX_DEPTH {
				return -1
			}
			objects[depth] = c == '{'
			depth += 1
			i += 1
			if c == '[' {
				write.put_byte(out, '[')
				continue
			}
			write.put_text(out, "{ ")
			if i = laid_member(l, i); i < 0 {
				return -1
			}
			continue
		case '"':
			end := laid_string_end(src, i)
			if end < 0 {
				return -1
			}
			write.put_text(out, string(src[i:end]))
			i = end
		case:
			end := i
			for end < len(src) && src[end] != ',' && src[end] != ']' && src[end] != '}' {
				end += 1
			}
			if !laid_scalar(out, string(src[i:end])) {
				return -1
			}
			i = end
		}
		// After a value: the closes of the containers it ends, then a comma and what follows it.
		for depth > 0 {
			c := peek(src, i)
			if c == ',' {
				write.put_text(out, ", ")
				i += 1
				if objects[depth - 1] {
					if i = laid_member(l, i); i < 0 {
						return -1
					}
				}
				break
			}
			if c != ('}' if objects[depth - 1] else ']') {
				return -1
			}
			write.put_text(out, " }" if c == '}' else "]")
			i += 1
			depth -= 1
		}
		if depth == 0 {
			return i
		}
	}
}

// Writes the key at `i` of an inline table and its ` = `, and returns the offset of its value, -1 when it is no key.
@(private)
laid_member :: proc(l: ^Inline_Layout, i: int) -> int {
	key, after := laid_key(l.src, i)
	if after < 0 || peek(l.src, after) != '=' {
		return -1
	}
	write.put_text(&l.store, key)
	write.put_text(&l.store, " = ")
	return after + 1
}

// The offset past the basic string at `i`, -1 when it does not end or holds an escape only TOML 1.1 reads.
@(private)
laid_string_end :: proc(src: []u8, i: int) -> int {
	for k := i + 1; k < len(src); {
		run := plain_run(src, k, '"')
		k += run
		if run == 16 {
			continue
		}
		switch src[k] {
		case '"':
			return k + 1
		case '\\':
			if next := peek(src, k + 1); next == 'e' || next == 'x' {
				return -1
			}
			k += 2
		case:
			k += 1
		}
	}
	return -1
}

// Writes a number, a boolean or a datetime written bare, a time with no seconds given `:00` as `put_datetime` gives it.
// False for null, an integer past 64 bits, and a byte no such scalar holds.
@(private)
laid_scalar :: proc(out: ^write.Out, s: string) -> bool {
	if len(s) == 0 || s == "null" {
		return false
	}
	colon := -1
	digits := true
	for b, k in transmute([]u8)s {
		switch b {
		case '0' ..= '9':
		case '-', '+':
			digits &&= k == 0
		case 'a' ..= 'z', 'A' ..= 'Z', '.', '_':
			digits = false
		case ':':
			digits = false
			colon = k if colon < 0 else colon
		case:
			return false
		}
	}
	if digits {
		n := s[1:] if s[0] == '-' || s[0] == '+' else s
		if len(n) > 19 || len(n) == 19 && n > ("9223372036854775808" if s[0] == '-' else "9223372036854775807") {
			return false
		}
	}
	if colon >= 0 && (colon + 3 >= len(s) || s[colon + 3] != ':') {
		write.put_text(out, s[:colon + 3])
		write.put_text(out, ":00")
		write.put_text(out, s[colon + 3:])
		return true
	}
	write.put_text(out, s)
	return true
}

// Writes the store's chunks to `out` in the order of their segments, a header after a blank line unless it is first.
@(private)
laid_join :: proc(l: ^Inline_Layout, out: ^write.Out) {
	firsts := make([]i32, len(l.segs) + 1, context.allocator)
	defer delete(firsts)
	order := make([]i32, len(l.chunks), context.allocator)
	defer delete(order)
	if firsts == nil || len(l.chunks) > 0 && order == nil {
		l.err = .No_Memory
		return
	}
	for c in l.chunks {
		firsts[c.seg + 1] += 1
	}
	for s in 1 ..< len(firsts) {
		firsts[s] += firsts[s - 1]
	}
	for c, k in l.chunks {
		order[firsts[c.seg]] = i32(k)
		firsts[c.seg] += 1
	}
	last := i32(-1)
	for k in order {
		c := l.chunks[k]
		bytes := string(l.store.buf[c.lo:c.hi])
		if c.seg != last && l.segs[c.seg].headed {
			wrote := out.flushed + out.cursor > 0
			if l.segs[c.seg].blank && !wrote {
				bytes = bytes[1:]
			} else if !l.segs[c.seg].blank && wrote {
				write.put_byte(out, '\n')
			}
		}
		last = c.seg
		write.put_text(out, bytes)
	}
}
