package yaml

// Where an edit's text goes. A text is placed at its site: a one-line text where the old value stood, a block
// collection on the lines under its key at the indentation the file uses, or after a dash in compact form, a block
// scalar with its header where the old value stood, and in a flow collection one flow value. A text's lines after its
// first are column 0 text, indented to the site. A member or element added to a block collection is a line at its
// indentation, one removed goes with its lines and its head comments, and in a flow collection either goes with one
// separator.

import "core:bytes"
import "core:slice"
import core "../core"

// How a text stands: on one line, a scalar or flow collection over lines, a block collection, or a block scalar.
@(private)
Text_Form :: enum u8 {
	Inline,
	Lines,
	Block,
	Literal,
}

// A text's form. `head` is the length of the line of properties a block collection starts with, 0 for none.
@(private)
Text_Shape :: struct {
	form: Text_Form,
	seq:  bool,
	head: int,
}

// `text` without its last line end.
@(private)
trim_break :: proc(text: []u8) -> []u8 {
	t := text
	if len(t) > 0 && t[len(t) - 1] == '\n' {
		t = t[:len(t) - 1]
		if len(t) > 0 && t[len(t) - 1] == '\r' {
			t = t[:len(t) - 1]
		}
	}
	return t
}

@(private)
shape_text :: proc(cx: ^Cx, t: []u8) -> Text_Shape {
	nl := bytes.index_byte(t, '\n')
	if nl < 0 && !may_be_block(t) {
		return {form = .Inline}
	}
	doc, value, offset, err := build_value(t, cx.doc.as, cx.a)
	defer core.destroy(&doc)
	if err.kind != .None {
		return {form = .Inline if nl < 0 else .Lines}
	}
	root := doc.nodes[value]
	switch {
	case is_container(root.kind) && !is_flow(&doc, root):
		head := 0
		if start := props_lo(&doc, u32(value) + 1, root.lo) if root.kind == .Object && root.n > 1 else root.lo; nl >= 0 && u64(nl) + offset < start {
			head = len(trim_break(t[:nl + 1]))
		}
		return {form = .Block, seq = root.kind == .Array, head = head}
	case root.kind == .String && style_of(root.spelling) == .Block:
		return {form = .Literal}
	}
	return {form = .Inline if nl < 0 else .Lines}
}

// Whether a one-line text may be a block collection or a block scalar, which only its read settles.
@(private = "file")
may_be_block :: proc(t: []u8) -> bool {
	if len(t) == 0 {
		return false
	}
	switch t[0] {
	case '-', '?', '|', '>', '!', '&':
		return true
	}
	return t[len(t) - 1] == ':' || bytes.contains(t, transmute([]u8)string(": ")) || bytes.contains(t, transmute([]u8)string(":\t"))
}

// The text `t` takes inside a flow collection: itself, or a block text or a plain scalar that holds a flow indicator
// written again as one flow value.
@(private)
flow_text :: proc(cx: ^Cx, t: []u8, sh: Text_Shape) -> []u8 {
	switch sh.form {
	case .Block, .Literal:
	case .Inline, .Lines:
		if len(t) == 0 || t[0] == '"' || t[0] == '\'' || t[0] == '[' || t[0] == '{' || t[0] == '*' || bytes.index_any(t, transmute([]u8)string(",[]{}")) < 0 {
			return t
		}
	}
	doc, err := build_as(t, cx.doc.as, false, cx.a)
	defer core.destroy(&doc)
	if err.kind != .None {
		return t
	}
	if root := doc.nodes[core.ROOT]; !is_container(root.kind) && spelling_resolve(&doc, core.ROOT) == .String && len(doc.facts) == 0 {
		name, _ := core.text_clone(&doc, core.ROOT, cx.a)
		if spelled, ok := spell_scalar(name, {flow = true}, cx.a); ok {
			return spelled
		}
	}
	text, _, werr := document_write(&doc, {}, doc.as, core.ROOT, {}, cx.a)
	if werr.kind != .None {
		return t
	}
	for len(text) > 0 && is_blank_byte(text[len(text) - 1]) {
		text = text[:len(text) - 1]
	}
	return text
}

// The byte of the colon after the key that ends at `p`: on the key's line, or after an explicit key on a later line
// past comments. Without one it is the first byte past `p` that is no space.
@(private)
colon_after :: proc(src: []u8, p: u64) -> u64 {
	i := p
	for i < u64(len(src)) && (src[i] == ' ' || src[i] == '\t') {
		i += 1
	}
	for j := i; j < u64(len(src)); {
		switch src[j] {
		case ' ', '\t', '\r', '\n':
			j += 1
		case '#':
			j = content_end(src, j)
		case ':':
			return j
		case:
			return i
		}
	}
	return i
}

// Renames key `k`, in its quotes when it has them, and keeps the line end a block scalar's bytes hold.
@(private)
set_key :: proc(cx: ^Cx, k: u32, name: string) -> bool {
	src := cx.src
	lo, hi := cx.lo[k], cx.hi[k]
	keeps: Maybe(Style)
	if nd := cx.doc.nodes[k]; nd.kind == .String && .Alias not_in cx.flags[k] {
		if style := style_of(nd.spelling); style == .Single || style == .Double {
			keeps = style
		}
	}
	spelled, ok := spell_key(name, .Flow in cx.flags[k], cx.a, keeps)
	if !ok {
		return refuse_edit(cx, k, .Long_Key)
	}
	b := make([dynamic]u8, cx.a)
	if lo == hi && lo > 0 && !is_blank_byte(src[lo - 1]) && bytes.index_byte(transmute([]u8)string(",[{"), src[lo - 1]) < 0 {
		puts(&b, " ")
	}
	append(&b, ..spelled)
	if hi > lo && src[hi - 1] == '\n' {
		puts(&b, cx.eol)
	}
	add(cx, lo, hi, b[:])
	return true
}

@(private)
set_value :: proc(cx: ^Cx, v: u32, text: []u8) -> bool {
	t := trim_break(text)
	place(cx, v, t, shape_text(cx, t))
	return true
}

// Puts `t` in node `v`'s place.
@(private)
place :: proc(cx: ^Cx, v: u32, t: []u8, sh: Text_Shape) {
	src := cx.src
	lo, hi := cx.lo[v], cx.hi[v]
	p := cx.parent[v]
	b := make([dynamic]u8, cx.a)
	// An empty node after its properties takes a value on their line past a space.
	if .After_Props in cx.flags[v] && sh.form != .Block {
		puts(&b, " ")
	}
	if p != NIL && .Flow in cx.flags[p] {
		if pair, ok := pair_text(cx, v, t); ok {
			append(&b, ..pair)
		} else {
			append(&b, ..flow_text(cx, t, sh))
		}
		add(cx, lo, hi, b[:])
		return
	}
	if sh.form == .Block && .Bracket in cx.flags[v] {
		place(cx, v, flow_text(cx, t, sh), {form = .Inline})
		return
	}
	from := lo
	first := first_on_line(src, lo)
	switch {
	case p == NIL:
		col := 0
		if sh.form == .Block && first {
			from = indent_end(src, lo)
			put_spaces_to(&b, int(lo - from))
			col = column_of(src, lo)
		}
		if sh.form == .Block && !first {
			from = lead_end(src, lo)
			puts(&b, cx.eol)
		}
		put_lines(cx, &b, t, col)
	case cx.doc.nodes[p].kind == .Object:
		done: bool
		if from, done = place_value(cx, &b, v, t, sh); done {
			return
		}
	case sh.form != .Block:
		if lo > 0 && src[lo - 1] == '-' {
			puts(&b, " ")
		}
		put_lines(cx, &b, t, column_of(src, cx.lo[p]))
	case first:
		from = indent_end(src, lo)
		put_spaces_to(&b, int(lo - from))
		put_lines(cx, &b, t, column_of(src, lo))
	case lead_end(src, lo) < lo && src[lead_end(src, lo) - 1] == '-' && bytes.index_byte(src[lead_end(src, lo):lo], '\t') < 0:
		put_lines(cx, &b, t, column_of(src, lo))
	case:
		// A block collection after a dash starts past one space, not a tab, and after properties on the lines under
		// them.
		from = lead_end(src, lo)
		col := column_of(src, cx.lo[p]) + 2
		if from > 0 && src[from - 1] == '-' {
			puts(&b, " ")
			col = column_of(src, from) + 1
		} else {
			puts(&b, cx.eol)
			put_spaces_to(&b, col)
		}
		put_lines(cx, &b, t, col)
	}
	if hi > lo && src[hi - 1] == '\n' {
		puts(&b, cx.eol)
	}
	add(cx, from, hi, b[:])
}

// Where the spaces that indent the line before `p` end: at its first tab, which no block collection may be indented
// by, or at `p`.
@(private = "file")
indent_end :: proc(src: []u8, p: u64) -> u64 {
	if i := bytes.index_byte(src[line_start(src, p):p], '\t'); i >= 0 {
		return line_start(src, p) + u64(i)
	}
	return p
}

// The text `t` in the place of node `v` when `v` is an implicit pair of a flow sequence: itself, or a flow mapping's
// one member, when that reads there as the single pair the text is.
@(private = "file")
pair_text :: proc(cx: ^Cx, v: u32, t: []u8) -> ([]u8, bool) {
	if cx.doc.nodes[v].kind != .Object || cx.flags[v] & {.Flow, .Bracket} != {.Flow} {
		return nil, false
	}
	pair, err := build_as(t, cx.doc.as, false, cx.a)
	defer core.destroy(&pair)
	if err.kind != .None || pair.nodes[core.ROOT].kind != .Object || core.length(&pair, core.ROOT) != 1 {
		return nil, false
	}
	inner := t
	if len(t) >= 2 && t[0] == '{' && t[len(t) - 1] == '}' {
		inner = bytes.trim_space(t[1:len(t) - 1])
	}
	wrapped := make([dynamic]u8, 0, len(inner) + 2, cx.a)
	append(&wrapped, '[')
	append(&wrapped, ..inner)
	append(&wrapped, ']')
	seq, serr := build_as(wrapped[:], cx.doc.as, false, cx.a)
	defer core.destroy(&seq)
	if serr.kind != .None || core.length(&seq, core.ROOT) != 1 {
		return nil, false
	}
	first, _ := core.child_at(&seq, core.ROOT, 0)
	return inner, core.equal(core.Node_Ref{&pair, core.ROOT}, core.Node_Ref{&seq, first})
}

// Writes `t` as the value of the block mapping member whose value is `v`, and returns where the bytes it replaces
// start: the old value's first byte, or the key's colon when the value moves to or from the key's line, or `done` when
// it has made its splices itself.
@(private = "file")
place_value :: proc(cx: ^Cx, b: ^[dynamic]u8, v: u32, t: []u8, sh: Text_Shape) -> (from: u64, done: bool) {
	src := cx.src
	lo, hi := cx.lo[v], cx.hi[v]
	key := v - 1
	kcol := column_of(src, cx.lo[cx.parent[v]])
	colon := colon_after(src, cx.hi[key])
	ks := key_start(cx.doc, src, key, cx.lo[key] if .Alias in cx.flags[key] else min(cx.lo[key], cx.doc.nodes[key].lo))
	explicit := src[ks] == '?' && (ks + 1 == u64(len(src)) || is_blank_byte(src[ks + 1]))
	// An explicit key without a value takes one on a line of its own.
	if explicit && (colon == u64(len(src)) || src[colon] != ':') {
		puts(b, cx.eol)
		put_spaces_to(b, kcol)
		puts(b, ": ")
		put_lines(cx, b, t, kcol + 2)
		return lo, false
	}
	if sh.form == .Block {
		// On its own line, or compact after the colon of an explicit key, the collection keeps the old value's column.
		if first_on_line(src, lo) {
			from = indent_end(src, lo)
			put_spaces_to(b, int(lo - from))
			put_lines(cx, b, t, column_of(src, lo))
			return from, false
		}
		if explicit && first_on_line(src, colon) && line_start(src, colon) == line_start(src, lo) && lead_end(src, lo) == colon + 1 {
			put_lines(cx, b, t, column_of(src, lo))
			return lo, false
		}
		learn_layout(cx)
		bcol := kcol + (cx.seq_off if sh.seq else cx.step)
		body := t
		if sh.head > 0 {
			puts(b, " ")
			append(b, ..t[:sh.head])
			body = t[min(len(t), bytes.index_byte(t, '\n') + 1):]
		}
		// A comment after the old value stays on the key's line, above the lines that now hold the value.
		if hi < u64(len(src)) && src[hi - 1] != '\n' && rest_is_blank(src, hi) && bytes.index_byte(src[hi:content_end(src, hi)], '#') >= 0 {
			add(cx, lead_end(src, lo), hi, b[:])
			nl := next_line(src, hi)
			lines := make([dynamic]u8, cx.a)
			if nl == u64(len(src)) && src[nl - 1] != '\n' {
				puts(&lines, cx.eol)
			}
			put_spaces_to(&lines, bcol)
			put_lines(cx, &lines, body, bcol)
			if nl < u64(len(src)) || src[nl - 1] == '\n' {
				puts(&lines, cx.eol)
			}
			add(cx, nl, nl, lines[:])
			return hi, true
		}
		puts(b, cx.eol)
		put_spaces_to(b, bcol)
		put_lines(cx, b, body, bcol)
		return lead_end(src, lo), false
	}
	if !is_block(cx, v) {
		if lo == colon + 1 {
			puts(b, " ")
		}
		put_lines(cx, b, t, kcol)
		return lo, false
	}
	// A block collection gives way to a value on the key's line, which keeps the properties and the comment it holds.
	from = colon + 1
	comment: []u8
	for f in core.all_facts(cx.doc, core.Node_Index(v)) {
		if line_start(src, f.lo) != line_start(src, colon) {
			continue
		}
		#partial switch f.role {
		case .Tag, .Anchor:
			from = max(from, f.lo + u64(f.n))
		case .Comment:
			comment = src[f.lo:f.lo + u64(f.n)]
		}
	}
	puts(b, " ")
	if nl := bytes.index_byte(t, '\n'); sh.form == .Literal && comment != nil && nl >= 0 {
		append(b, ..trim_break(t[:nl + 1]))
		puts(b, " ", string(comment))
		put_lines(cx, b, t[nl:], kcol)
		return from, false
	}
	put_lines(cx, b, t, kcol)
	if comment != nil {
		puts(b, " ", string(comment))
	}
	return from, false
}

// Adds and removes the members of container `c` its group names.
@(private)
regroup :: proc(cx: ^Cx, c: u32, g: ^Group) -> bool {
	if cx.flags[c] & {.Flow, .Bracket} == {.Flow} {
		return refuse_edit(cx, c, .Implicit_Pair)
	}
	items := items_of(cx, c)
	removed := make([]bool, len(items), cx.a)
	for k in g.removed {
		removed[k] = true
	}
	slice.stable_sort_by(g.inserts[:], proc(a, b: core.Edit) -> bool {return a.at < b.at})
	if .Bracket in cx.flags[c] {
		return regroup_flow(cx, c, items, removed, g.inserts[:])
	}
	return regroup_block(cx, c, items, removed, g.inserts[:])
}

@(private = "file")
regroup_block :: proc(cx: ^Cx, c: u32, items: []Item, removed: []bool, inserts: []core.Edit) -> bool {
	src := cx.src
	n := len(items)
	object := cx.doc.nodes[c].kind == .Object
	left := n
	for r in removed {
		left -= int(r)
	}
	if left == 0 && len(inserts) == 0 {
		place(cx, c, transmute([]u8)string("{}" if object else "[]"), {form = .Inline})
		return true
	}
	col := column_of(src, items[0].start)
	compact := !first_on_line(src, items[0].start)
	// A compact first member removed leaves its dash's line to the next member, or ends the line at the dash.
	joined := false
	if compact && removed[0] {
		joined = n > 1 && !removed[1] && head_of(cx, items, 1) == items[1].start && !inserts_at(inserts, 1)
		if joined {
			add(cx, items[0].start, items[1].start, nil)
		} else {
			q := items[0].end
			if q > 0 && src[q - 1] == '\n' {
				q -= 1
				if q > 0 && src[q - 1] == '\r' {
					q -= 1
				}
			} else {
				q = content_end(src, q)
			}
			add(cx, lead_end(src, items[0].start), q, nil)
		}
	}
	for j in 0 ..< n {
		if !removed[j] || j == 0 && compact {
			continue
		}
		add(cx, slot_at(cx, items, j, compact), slot_at(cx, items, j + 1, compact), nil)
	}
	for e in inserts {
		m, ok := member_text(cx, e, object, col)
		if !ok {
			return false
		}
		b := make([dynamic]u8, cx.a)
		at := int(e.at)
		if at == 0 && compact && (!removed[0] || joined) {
			append(&b, ..m)
			puts(&b, cx.eol)
			put_spaces_to(&b, col)
			add(cx, items[0].start, items[0].start, b[:])
			continue
		}
		if at == 0 && compact {
			at = 1
		}
		pos := slot_at(cx, items, at, compact)
		if pos == u64(len(src)) && (pos == 0 || src[pos - 1] != '\n') {
			puts(&b, cx.eol)
			put_spaces_to(&b, col)
			append(&b, ..m)
		} else {
			put_spaces_to(&b, col)
			append(&b, ..m)
			puts(&b, cx.eol)
		}
		add(cx, pos, pos, b[:])
	}
	return true
}

@(private = "file")
inserts_at :: proc(inserts: []core.Edit, at: u32) -> bool {
	for e in inserts {
		if e.at == at {
			return true
		}
	}
	return false
}

// Where member `j` of a block collection starts with its head comments, at a line start but for a compact first
// member, or for `j` past the last member where the last one's lines end.
@(private = "file")
slot_at :: proc(cx: ^Cx, items: []Item, j: int, compact: bool) -> u64 {
	switch {
	case j == 0:
		return items[0].start if compact else line_start(cx.src, items[0].start)
	case j < len(items):
		return line_start(cx.src, head_of(cx, items, j))
	}
	return member_end(cx, items[len(items) - 1], column_of(cx.src, items[0].start))
}

// The first byte of member `j`'s head comments, or its start when it has none.
@(private = "file")
head_of :: proc(cx: ^Cx, items: []Item, j: int) -> u64 {
	h := items[j].start
	for f in core.all_facts(cx.doc, core.Node_Index(items[j].value)) {
		if f.role == .Comment && f.lo < h && f.lo >= items[j - 1].end {
			h = f.lo
		}
	}
	return h
}

// The start of the line after the member's last, past the comment lines indented deeper than its collection's
// column `col`, which belong to the member's own content.
@(private = "file")
member_end :: proc(cx: ^Cx, it: Item, col: int) -> u64 {
	src := cx.src
	q := it.end
	if !(q > 0 && src[q - 1] == '\n') {
		q = next_line(src, q)
	}
	for {
		r := q
		for r < u64(len(src)) && blank_line(src, r) {
			r = next_line(src, r)
		}
		ccol, comment := comment_line(src, r)
		if r >= u64(len(src)) || !comment || ccol <= col {
			return q
		}
		q = next_line(src, r)
	}
}

// The text of an inserted member or element of a block collection at column `col`, without its line end.
@(private = "file")
member_text :: proc(cx: ^Cx, e: core.Edit, object: bool, col: int) -> ([]u8, bool) {
	t := trim_break(e.text)
	sh := shape_text(cx, t)
	b := make([dynamic]u8, cx.a)
	if !object {
		puts(&b, "- ")
		put_lines(cx, &b, t, col + 2 if sh.form == .Block else col)
		return b[:], true
	}
	k, ok := spell_key(string(e.key), false, cx.a)
	if !ok {
		return nil, refuse_edit(cx, u32(e.node), .Long_Key)
	}
	append(&b, ..k)
	if sh.form != .Block {
		puts(&b, ": ")
		put_lines(cx, &b, t, col)
		return b[:], true
	}
	learn_layout(cx)
	bcol := col + (cx.seq_off if sh.seq else cx.step)
	body := t
	if sh.head > 0 {
		puts(&b, ": ")
		append(&b, ..t[:sh.head])
		body = t[bytes.index_byte(t, '\n') + 1:]
	} else {
		puts(&b, ":")
	}
	puts(&b, cx.eol)
	put_spaces_to(&b, bcol)
	put_lines(cx, &b, body, bcol)
	return b[:], true
}

@(private = "file")
regroup_flow :: proc(cx: ^Cx, c: u32, items: []Item, removed: []bool, inserts: []core.Edit) -> bool {
	src := cx.src
	n := len(items)
	sep := ", "
	if n >= 2 {
		if gap := src[items[0].end:items[1].start]; bytes.index_byte(gap, '#') < 0 && bytes.index_byte(gap, ',') >= 0 {
			sep = string(gap)
		}
	}
	// Where each slot's inserts go, and whether they follow a member there or precede one.
	pos := make([]u64, n + 1, cx.a)
	follows := make([]bool, n + 1, cx.a)
	for it, j in items {
		pos[j] = it.start
	}
	pos[n], follows[n] = items[n - 1].end if n > 0 else cx.lo[c] + 1, n > 0
	empty := n == 0
	for j := 0; j < n; {
		if !removed[j] {
			j += 1
			continue
		}
		r := j
		for j < n && removed[j] {
			j += 1
		}
		s := j - 1
		switch {
		case s < n - 1:
			add(cx, items[r].start, items[s + 1].start, nil)
			for k in r + 1 ..= s {
				pos[k] = items[s + 1].start
			}
		case r > 0:
			add(cx, items[r - 1].end, items[s].end, nil)
			for k in r ..= n {
				pos[k], follows[k] = items[s].end, true
			}
		case:
			// With every member goes the separator the last one leaves.
			end := items[n - 1].end
			for q := end; q < u64(len(src)) && src[q] != ']' && src[q] != '}'; q += 1 {
				if src[q] == ',' {
					end = q + 1
					break
				}
			}
			add(cx, items[0].start, end, nil)
			for k in 0 ..= n {
				pos[k] = end
			}
			empty = true
		}
	}
	object := cx.doc.nodes[c].kind == .Object
	for e, k in inserts {
		t := trim_break(e.text)
		m := make([dynamic]u8, cx.a)
		if object {
			key, ok := spell_key(string(e.key), true, cx.a)
			if !ok {
				return refuse_edit(cx, c, .Long_Key)
			}
			append(&m, ..key)
			puts(&m, ": ")
		}
		append(&m, ..flow_text(cx, t, shape_text(cx, t)))
		b := make([dynamic]u8, cx.a)
		switch {
		case empty:
			if k > 0 {
				puts(&b, sep)
			}
			append(&b, ..m[:])
		case follows[e.at]:
			puts(&b, sep)
			append(&b, ..m[:])
		case:
			append(&b, ..m[:])
			puts(&b, sep)
		}
		add(cx, pos[e.at], pos[e.at], b[:])
	}
	return true
}
