package yaml

// The fact edits of a YAML text. A tag or an anchor is written before its node, on the key's line for a block
// collection under a key and on a line of its own above one at a dash or the root, and an alias takes the place of its
// node's bytes. A comment is a line above its node's line, a comment after its value on the line, or a line after a
// block collection's last.

import "core:bytes"
import core "../core"
import compose "../core/compose"

@(private)
fact_edit :: proc(cx: ^Cx, e: core.Edit) -> bool {
	if core.is_property(e.role) {
		return property_edit(cx, e)
	}
	v := u32(e.node)
	if .Flow in cx.flags[v] && (e.role != .Comment_Inline || cx.parent[v] != NIL && .Flow in cx.flags[cx.parent[v]]) {
		return refuse_edit(cx, v, .Flow_Comment)
	}
	lines := compose.fact_lines(e, cx.a)
	existing := compose.role_facts(cx.doc, e, cx.a)
	for f, k in existing {
		if k > 0 || len(lines) == 0 {
			cut_comment(cx, f)
		}
	}
	if len(lines) == 0 {
		return true
	}
	src := cx.src
	b := make([dynamic]u8, cx.a)
	#partial switch e.role {
	case .Comment_Inline:
		if is_block(cx, v) || cx.doc.nodes[v].kind == .String && style_of(cx.doc.nodes[v].spelling) == .Block {
			return refuse_edit(cx, v, .Block_Comment)
		}
		if len(lines) > 1 {
			return refuse_edit(cx, v, .No_Line)
		}
		put_comment(&b, lines[0], e.padded)
		if len(existing) > 0 {
			add(cx, existing[0].lo, existing[0].lo + u64(existing[0].n), b[:])
			return true
		}
		if !rest_is_blank(src, cx.hi[v]) || bytes.index_byte(src[cx.hi[v]:content_end(src, cx.hi[v])], '#') >= 0 {
			return refuse_edit(cx, v, .No_Line)
		}
		inject_at(&b, 0, u8(' '))
		add(cx, cx.hi[v], cx.hi[v], b[:])
	case .Comment:
		if len(existing) > 0 {
			put_comment_lines(cx, &b, lines[:], e.padded, column_of(src, existing[0].lo), false)
			add(cx, existing[0].lo, existing[0].lo + u64(existing[0].n), b[:])
			return true
		}
		start := member_start(cx, v)
		if !first_on_line(src, start) {
			return refuse_edit(cx, v, .No_Line)
		}
		put_spaces_to(&b, column_of(src, start))
		put_comment_lines(cx, &b, lines[:], e.padded, column_of(src, start), true)
		ls := compose.line_start(src, start)
		add(cx, ls, ls, b[:])
	case .Comment_Foot:
		if !is_block(cx, v) {
			return refuse_edit(cx, v, .No_Line)
		}
		col := column_of(src, cx.lo[v])
		if len(existing) > 0 {
			put_comment_lines(cx, &b, lines[:], e.padded, column_of(src, existing[0].lo), false)
			add(cx, existing[0].lo, existing[0].lo + u64(existing[0].n), b[:])
			return true
		}
		q := cx.hi[v]
		if !(q > 0 && src[q - 1] == '\n') {
			q = next_line(src, q)
		}
		if q == u64(len(src)) && (q == 0 || src[q - 1] != '\n') {
			compose.puts(&b, cx.eol)
			put_spaces_to(&b, col)
			put_comment_lines(cx, &b, lines[:], e.padded, col, false)
		} else {
			put_spaces_to(&b, col)
			put_comment_lines(cx, &b, lines[:], e.padded, col, true)
		}
		add(cx, q, q, b[:])
	case:
		return refuse_edit(cx, v, .No_Line)
	}
	return true
}

// Where node `v` starts as a member: its key, its dash, or for the root its first byte.
@(private = "file")
member_start :: proc(cx: ^Cx, v: u32) -> u64 {
	p := cx.parent[v]
	if p == NIL {
		return props_lo(cx.doc, v, cx.lo[v])
	}
	for it in items_of(cx, p) {
		if it.value == v {
			return it.start
		}
	}
	return cx.lo[v]
}

@(private = "file")
put_comment :: proc(b: ^[dynamic]u8, body: []u8, padded: bool) {
	compose.puts(b, "# " if padded else "#")
	append(b, ..body)
}

// Writes comment lines, each after the first at column `col`, with a line end after the last when `ended`.
@(private = "file")
put_comment_lines :: proc(cx: ^Cx, b: ^[dynamic]u8, lines: [][]u8, padded: bool, col: int, ended: bool) {
	for line, k in lines {
		if k > 0 {
			compose.puts(b, cx.eol)
			put_spaces_to(b, col)
		}
		put_comment(b, line, padded)
	}
	if ended {
		compose.puts(b, cx.eol)
	}
}

// Removes comment `f`: its line when it stands alone on it, else the comment and the spaces before it.
@(private = "file")
cut_comment :: proc(cx: ^Cx, f: core.Fact) {
	lo, hi := f.lo, f.lo + u64(f.n)
	if first_on_line(cx.src, lo) {
		add(cx, compose.line_start(cx.src, lo), next_line(cx.src, hi), nil)
	} else {
		add(cx, lead_end(cx.src, lo), hi, nil)
	}
}

@(private = "file")
property_edit :: proc(cx: ^Cx, e: core.Edit) -> bool {
	v := u32(e.node)
	prefix := make([dynamic]u8, cx.a)
	if e.op == .Set_Fact {
		edit_prefix(cx.doc, e.role, e.text, &prefix)
	}
	if .Alias in cx.flags[v] {
		if e.role != .Alias || e.op == .Remove_Fact {
			return refuse_edit(cx, v, .Alias_Node)
		}
		add(cx, cx.lo[v], cx.hi[v], prefix[:])
		return true
	}
	if e.role == .Alias {
		if e.op == .Set_Fact {
			place(cx, v, prefix[:], {form = .Inline})
		}
		return true
	}
	for f in core.all_facts(cx.doc, e.node) {
		if f.role != e.role {
			continue
		}
		if e.op == .Set_Fact {
			add(cx, f.lo, f.lo + u64(f.n), prefix[:])
		} else {
			cut_property(cx, f)
		}
		return true
	}
	if e.op == .Remove_Fact {
		return true
	}
	src := cx.src
	b := make([dynamic]u8, cx.a)
	if at := props_lo(cx.doc, v, cx.lo[v]); at < cx.lo[v] {
		append(&b, ..prefix[:])
		compose.puts(&b, " ")
		add(cx, at, at, b[:])
		return true
	}
	lo := cx.lo[v]
	p := cx.parent[v]
	switch {
	case !is_block(cx, v):
		empty := cx.doc.nodes[v].kind <= .Plain && cx.doc.nodes[v].n == 0
		if empty && lo > 0 && (src[lo - 1] == ':' || src[lo - 1] == '-') {
			compose.puts(&b, " ")
		}
		append(&b, ..prefix[:])
		if !empty {
			compose.puts(&b, " ")
		}
		add(cx, lo, lo, b[:])
	case p != NIL && cx.doc.nodes[p].kind == .Object:
		compose.puts(&b, " ")
		append(&b, ..prefix[:])
		colon := colon_after(src, cx.hi[v - 1])
		add(cx, colon + 1, colon + 1, b[:])
	case:
		append(&b, ..prefix[:])
		compose.puts(&b, cx.eol)
		put_spaces_to(&b, column_of(src, lo))
		add(cx, lo, lo, b[:])
	}
	return true
}

// Removes the property `f` with the spaces after it, and its line when nothing else is left on it.
@(private = "file")
cut_property :: proc(cx: ^Cx, f: core.Fact) {
	src := cx.src
	lo, hi := f.lo, f.lo + u64(f.n)
	for hi < u64(len(src)) && (src[hi] == ' ' || src[hi] == '\t') {
		hi += 1
	}
	if hi < u64(len(src)) && src[hi] != '\n' && src[hi] != '\r' {
		add(cx, lo, hi, nil)
		return
	}
	if first_on_line(src, lo) {
		add(cx, compose.line_start(src, lo), next_line(src, hi), nil)
		return
	}
	add(cx, lead_end(src, lo), hi, nil)
}
