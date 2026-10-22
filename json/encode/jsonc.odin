package encode

// A JSONC document's comments written where they are attached, by one printer the library's writers and the
// command line share. The printer places comments only: its caller walks the values (rows, or the CLI's
// values), writes keys and scalars, and orders keys. It hands each entry's own comments (`c.Fact`s, sorted by
// place) to the procedures below at the points of its walk they name.
// A comment sits where it was attached: a `.Lead` on the line before its entry, an `.Inline` between the key
// and the value, a `.Trail` after its entry and its comma, a `.Foot` on the line before its container's
// close. Compact output ends each line comment with a newline, the one place it keeps a line break, and
// a line comment that ends an output ends its line, pretty or compact.

import c "../../core"

// How the printer lays comments out: `src` is the text the comments are spans of, and `ascii` escapes each
// comment's characters past U+007F as it is written, for a caller that does not reescape its whole output.
Comment_Layout :: struct {
	src:    []byte,
	pretty: bool,
	indent: Indent,
	ascii:  bool,
}

// The comments before an entry, `.Lead` (and, at the `root` of an output, which has no key, `.Inline`),
// each on its own line `depth` levels in.
put_leads :: proc(buf: ^[dynamic]u8, cl: ^Comment_Layout, own: []c.Fact, depth: int, root := false) -> Encode_Error {
	for f in own {
		if f.place == .Lead || root && f.place == .Inline {
			put_comment(buf, cl, f) or_return
			put_line_break(buf, cl, depth) or_return
		}
	}
	return .None
}

// The comments between a member's key (and its colon) and its value: a line comment ends its line, a block
// comment is followed by a space when pretty.
put_inlines :: proc(buf: ^[dynamic]u8, cl: ^Comment_Layout, own: []c.Fact, depth: int) -> Encode_Error {
	for f in own {
		if f.place != .Inline {
			continue
		}
		put_comment(buf, cl, f) or_return
		if is_line_comment(cl.src[f.lo:f.hi]) {
			put_line_break(buf, cl, depth) or_return
		} else if cl.pretty {
			put_byte(buf, ' ') or_return
		}
	}
	return .None
}

// The comments after an entry and its comma, on its line. A line comment runs to the end of its line, so a
// trailing comment after one starts the next. At the `root` of an output, a line comment last ends the
// output's line itself, pretty or compact, so whatever follows the output is not read into it.
put_trails :: proc(buf: ^[dynamic]u8, cl: ^Comment_Layout, own: []c.Fact, depth: int, root := false) -> Encode_Error {
	after_line := false
	for f in own {
		if f.place != .Trail {
			continue
		}
		if after_line {
			put_line_break(buf, cl, depth) or_return
		} else if cl.pretty {
			put_byte(buf, ' ') or_return
		}
		put_comment(buf, cl, f) or_return
		after_line = is_line_comment(cl.src[f.lo:f.hi])
	}
	if root && after_line && cl.pretty {
		return put_byte(buf, '\n')
	}
	return .None
}

// The comments of a container `depth` levels in after its last entry, each on its own line one level in, and whether there were any. The caller breaks the line before the close.
put_feet :: proc(buf: ^[dynamic]u8, cl: ^Comment_Layout, own: []c.Fact, depth: int) -> (wrote: bool, err: Encode_Error) {
	for f in own {
		if f.place == .Foot {
			put_line_break(buf, cl, depth + 1) or_return
			put_comment(buf, cl, f) or_return
			wrote = true
		}
	}
	return
}

// A line break indented to `depth` when pretty, nothing when compact.
put_line_break :: proc(buf: ^[dynamic]u8, cl: ^Comment_Layout, depth: int) -> Encode_Error {
	if !cl.pretty {
		return .None
	}
	return put_newline(buf, u32(depth), &cl.indent)
}

// A comment's text, markers and all. Compact output ends a line comment with the newline it needs.
@(private = "file")
put_comment :: proc(buf: ^[dynamic]u8, cl: ^Comment_Layout, f: c.Fact) -> Encode_Error {
	mark := len(buf)
	put_bytes(buf, string(cl.src[f.lo:f.hi])) or_return
	if cl.ascii {
		reescape_tail(buf, mark, {.Non_Ascii}) or_return
	}
	if !cl.pretty && is_line_comment(cl.src[f.lo:f.hi]) {
		return put_byte(buf, '\n')
	}
	return .None
}

is_line_comment :: #force_inline proc(text: []byte) -> bool {
	return text[1] == '/'
}

// A JSONC document's rows written back with their comments. Keys, scalars and comments are source spans,
// copied. Punctuation and whitespace are re-made as `encode_rows` makes them, and a trailing comma is not
// kept. `trailing_newline` adds none after a line comment that ends the output, which ended its line.
// `ascii_only` and `escape_html` rewrite a comment's characters as they do a string's, as literal text.
// `.Bad_State` when `nodes` is not one whole document. `comments` must be sorted by node, then place.
encode_rows_jsonc :: proc(
	src: []byte,
	nodes: []c.Row,
	comments: []c.Fact,
	opts: Encode_Opts,
	allocator := context.allocator,
) -> (
	out: []byte,
	err: Encode_Error,
) {
	if len(nodes) == 0 || nodes[0].subtree_size != u32(len(nodes)) {
		return nil, .Bad_State
	}
	w := Jsonc_Writer{nodes = nodes, comments = comments, cl = {src = src, pretty = opts.pretty, indent = indent_of(opts)}}
	w.buf = make([dynamic]u8, 0, int(nodes[0].hi - nodes[0].lo) + 64, allocator)
	_, err = jsonc_entry(&w, 0, 0, true)
	if err == .None && opts.trailing_newline && (len(w.buf) == 0 || w.buf[len(w.buf) - 1] != '\n') {
		err = put_byte(&w.buf, '\n')
	}
	if flags := reescape_of(opts); flags != {} && err == .None {
		err = reescape_tail(&w.buf, 0, flags)
	}
	if err != .None {
		delete(w.buf)
		return nil, err
	}
	return w.buf[:], .None
}

@(private = "file")
Jsonc_Writer :: struct {
	buf:      [dynamic]u8,
	nodes:    []c.Row,
	comments: []c.Fact,
	next:     int, // the first comment not yet written
	cl:       Comment_Layout,
}

// Row `i` and its subtree at `depth`, with its comma when it is not the `last` of its container. Returns the row
// after its subtree.
@(private = "file")
jsonc_entry :: proc(w: ^Jsonc_Writer, i, depth: int, last: bool) -> (next: int, err: Encode_Error) {
	nd := w.nodes[i]
	lo := w.next
	for w.next < len(w.comments) && int(w.comments[w.next].node) == i {
		w.next += 1
	}
	own := w.comments[lo:w.next]
	buf, cl := &w.buf, &w.cl
	put_leads(buf, cl, own, depth) or_return
	if nd.key_lo != c.NO_KEY {
		put_bytes(buf, string(cl.src[nd.key_lo:nd.key_hi])) or_return
		put_colon(buf, cl.pretty) or_return
		put_inlines(buf, cl, own, depth) or_return
	}
	next = i + 1
	if nd.kind < .Array {
		put_bytes(buf, string(cl.src[nd.lo:nd.hi])) or_return
	} else {
		put_byte(buf, '[' if nd.kind == .Array else '{') or_return
		end := i + int(nd.subtree_size)
		opened := next < end
		for next < end {
			put_line_break(buf, cl, depth + 1) or_return
			next = jsonc_entry(w, next, depth + 1, next + int(w.nodes[next].subtree_size) == end) or_return
		}
		if put_feet(buf, cl, own, depth) or_return {
			opened = true
		}
		if opened {
			put_line_break(buf, cl, depth) or_return
		}
		put_byte(buf, ']' if nd.kind == .Array else '}') or_return
	}
	if !last {
		put_byte(buf, ',') or_return
	}
	put_trails(buf, cl, own, depth, root = i == 0) or_return
	return
}
