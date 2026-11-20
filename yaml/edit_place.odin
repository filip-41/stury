package yaml

// Where an edit's text goes. A text is placed at its site: a one-line text where the old value stood, a block
// collection on the lines under its key at the indentation the file uses, or after a dash in compact form, a block
// scalar with its header where the old value stood, and in a flow collection one flow value. A text's lines after its
// first are column 0 text, indented to the site. A member or element added to a block collection is a line at its
// indentation, one removed goes with its lines and its head comments, and in a flow collection either goes with one
// separator.

import "core:bytes"
import "core:encoding/endian"
import "core:slice"
import kernel "../core/kernel"
import core "../core"
import compose "../core/compose"
import write "../core/write"

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

// The text `t` takes inside a flow collection, or as the flow collection `at`: itself, or a block text or a plain scalar
// that holds a flow indicator written again as one flow value. A line break it holds ends a comment, and the line after
// it stands past the indentation of the line the outermost flow collection around `at` opens on, as a flow collection
// in a block needs.
@(private)
flow_text :: proc(cx: ^Cx, at: u32, t: []u8, sh: Text_Shape) -> []u8 {
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
	text = bytes.trim_right(text, transmute([]u8)string(" \t"))
	if bytes.index_byte(text, '\n') < 0 {
		return text
	}
	top := at
	for p := cx.parent[top]; p != NIL && (.Flow in cx.flags[p]); p = cx.parent[p] {
		top = p
	}
	from := compose.line_start(cx.src, cx.lo[top])
	ind := 0
	for cx.src[from + u64(ind)] == ' ' {
		ind += 1
	}
	b := make([dynamic]u8, cx.a)
	put_lines(cx, &b, text, ind + 2)
	if text[len(text) - 1] == '\n' {
		put_spaces_to(&b, ind + 2)
	}
	return b[:]
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
	if lo == hi && lo > 0 && !kernel.is_ws(src[lo - 1]) && bytes.index_byte(transmute([]u8)string(",[{"), src[lo - 1]) < 0 {
		compose.puts(&b, " ")
	}
	append(&b, ..spelled)
	if hi > lo && src[hi - 1] == '\n' {
		compose.puts(&b, cx.eol)
	}
	add(cx, lo, hi, b[:])
	return true
}

@(private)
set_value :: proc(cx: ^Cx, v: u32, text: []u8, value: core.Value) -> bool {
	t := trim_break(text)
	if s, is_text := value.(string); is_text {
		t = spelled_as_before(cx, v, s, t)
	}
	place(cx, v, t, shape_text(cx, t))
	return true
}

// The spelling of string `s` that replaces node `v`, `t` as the writer spelled it: in `v`'s quotes or folded block when
// they hold `s`, as a renamed key keeps its quotes. A `t` in double quotes holds an escape, which it keeps.
@(private = "file")
spelled_as_before :: proc(cx: ^Cx, v: u32, s: string, t: []u8) -> []u8 {
	nd := cx.doc.nodes[v]
	style := style_of(nd.spelling)
	if nd.kind != .String || len(t) == 0 || t[0] == '"' {
		return t
	}
	if style == .Block && cx.src[nd.lo] == '>' {
		return folded_as_before(cx, s, t)
	}
	if style != .Single && style != .Double {
		return t
	}
	quote: u8 = '\'' if style == .Single else '"'
	spelled, ok := spell_scalar(s, {flow = .Flow in cx.flags[v], keeps = style}, cx.a)
	if !ok || len(spelled) == 0 || spelled[0] != quote {
		return t
	}
	return spelled
}

// `s` as a folded block in place of `t`, the writer's literal block, at the indentation of `t`'s lines, or `t` when a
// folded block does not hold `s`. A folded block doubles each line break inside the text, which a literal block spells
// as it is, so only one line of text is folded.
@(private = "file")
folded_as_before :: proc(cx: ^Cx, s: string, t: []u8) -> []u8 {
	body := transmute([]u8)s
	for len(body) > 0 && body[len(body) - 1] == '\n' {
		body = body[:len(body) - 1]
	}
	nl := bytes.index_byte(t, '\n')
	if t[0] != '|' || nl < 0 || bytes.index_byte(body, '\n') >= 0 {
		return t
	}
	if shape, _ := shape_of(s, {block = true, keeps = .Block, folded = true}); shape != .Folded {
		return t
	}
	ind := 0
	for nl + 1 + ind < len(t) && t[nl + 1 + ind] == ' ' {
		ind += 1
	}
	spill: [write.ROOM_MAX]u8 = ---
	out: write.Out
	write.init(&out, &spill, cx.a)
	put_block(&out, s, .Folded, ind)
	spelled, err := write.finish(&out)
	return trim_break(spelled) if err.kind == .None else t
}

@(private)
place :: proc(cx: ^Cx, v: u32, t: []u8, sh: Text_Shape) {
	src := cx.src
	lo, hi := cx.lo[v], cx.hi[v]
	p := cx.parent[v]
	b := make([dynamic]u8, cx.a)
	// An empty node after its properties takes a value on their line past a space.
	if .After_Props in cx.flags[v] && sh.form != .Block {
		compose.puts(&b, " ")
	}
	if p != NIL && .Flow in cx.flags[p] {
		if pair, ok := pair_text(cx, v, t); ok {
			append(&b, ..pair)
		} else {
			append(&b, ..flow_text(cx, v, t, sh))
		}
		add(cx, lo, hi, b[:])
		return
	}
	if sh.form == .Block && .Bracket in cx.flags[v] {
		place(cx, v, bytes.trim_right(flow_text(cx, v, t, sh), transmute([]u8)string(" \r\n")), {form = .Inline})
		return
	}
	from := lo
	first := compose.first_on_line(src, lo)
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
			compose.puts(&b, cx.eol)
		}
		put_lines(cx, &b, t, col)
	case cx.doc.nodes[p].kind == .Object:
		done: bool
		if from, done = place_value(cx, &b, v, t, sh); done {
			return
		}
	case sh.form != .Block:
		if lo > 0 && src[lo - 1] == '-' {
			compose.puts(&b, " ")
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
			compose.puts(&b, " ")
			col = column_of(src, from) + 1
		} else {
			compose.puts(&b, cx.eol)
			put_spaces_to(&b, col)
		}
		put_lines(cx, &b, t, col)
	}
	if hi > lo && src[hi - 1] == '\n' {
		compose.puts(&b, cx.eol)
	}
	add(cx, from, hi, b[:])
}

// Where the spaces that indent the line before `p` end: at its first tab, which no block collection may be indented
// by, or at `p`.
@(private = "file")
indent_end :: proc(src: []u8, p: u64) -> u64 {
	if i := bytes.index_byte(src[compose.line_start(src, p):p], '\t'); i >= 0 {
		return compose.line_start(src, p) + u64(i)
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
	explicit := src[ks] == '?' && (ks + 1 == u64(len(src)) || kernel.is_ws(src[ks + 1]))
	// An explicit key without a value takes one on a line of its own.
	if explicit && (colon == u64(len(src)) || src[colon] != ':') {
		compose.puts(b, cx.eol)
		put_spaces_to(b, kcol)
		compose.puts(b, ": ")
		put_lines(cx, b, t, kcol + 2)
		return lo, false
	}
	if sh.form == .Block {
		// On its own line, or compact after the colon of an explicit key, the collection keeps the old value's column.
		if compose.first_on_line(src, lo) {
			from = indent_end(src, lo)
			put_spaces_to(b, int(lo - from))
			put_lines(cx, b, t, column_of(src, lo))
			return from, false
		}
		if explicit && compose.first_on_line(src, colon) && compose.line_start(src, colon) == compose.line_start(src, lo) && lead_end(src, lo) == colon + 1 {
			put_lines(cx, b, t, column_of(src, lo))
			return lo, false
		}
		learn_layout(cx)
		bcol := kcol + (cx.seq_off if sh.seq else cx.step)
		body := t
		if sh.head > 0 {
			compose.puts(b, " ")
			append(b, ..t[:sh.head])
			body = t[min(len(t), bytes.index_byte(t, '\n') + 1):]
		}
		// A comment after the old value stays on the key's line, above the lines that now hold the value.
		if hi < u64(len(src)) && src[hi - 1] != '\n' && rest_is_blank(src, hi) && bytes.index_byte(src[hi:content_end(src, hi)], '#') >= 0 {
			add(cx, lead_end(src, lo), hi, b[:])
			nl := compose.next_line(src, hi)
			lines := make([dynamic]u8, cx.a)
			if nl == u64(len(src)) && src[nl - 1] != '\n' {
				compose.puts(&lines, cx.eol)
			}
			put_spaces_to(&lines, bcol)
			put_lines(cx, &lines, body, bcol)
			if nl < u64(len(src)) || src[nl - 1] == '\n' {
				compose.puts(&lines, cx.eol)
			}
			add(cx, nl, nl, lines[:])
			return hi, true
		}
		compose.puts(b, cx.eol)
		put_spaces_to(b, bcol)
		put_lines(cx, b, body, bcol)
		return lead_end(src, lo), false
	}
	if !is_block(cx, v) {
		if lo == colon + 1 {
			compose.puts(b, " ")
		}
		put_lines(cx, b, t, kcol)
		return lo, false
	}
	// A block collection gives way to a value on the key's line, which keeps the properties and the comment it holds.
	from = colon + 1
	comment: []u8
	for f in core.all_facts(cx.doc, core.Node_Index(v)) {
		if compose.line_start(src, f.lo) != compose.line_start(src, colon) {
			continue
		}
		#partial switch f.role {
		case .Tag, .Anchor:
			from = max(from, f.lo + u64(f.n))
		case .Comment_Inline:
			comment = src[f.lo:f.lo + u64(f.n)]
		}
	}
	compose.puts(b, " ")
	if nl := bytes.index_byte(t, '\n'); sh.form == .Literal && comment != nil && nl >= 0 {
		append(b, ..trim_break(t[:nl + 1]))
		compose.puts(b, " ", string(comment))
		put_lines(cx, b, t[nl:], kcol)
		return from, false
	}
	put_lines(cx, b, t, kcol)
	if comment != nil {
		compose.puts(b, " ", string(comment))
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
	order := g.order if len(items) > 0 else nil
	if order != nil {
		if e := compose.order_check(order, removed, len(g.inserts), cx.a); e.kind != .None {
			cx.err = e
			return false
		}
		if names_cross(cx, items, removed, order) {
			return refuse_edit(cx, c, .Reordered)
		}
	}
	if .Bracket in cx.flags[c] {
		return regroup_flow(cx, c, items, removed, g.inserts[:], order)
	}
	if order != nil {
		return reorder_block(cx, c, items, g.inserts[:], order)
	}
	return regroup_block(cx, c, items, removed, g.inserts[:])
}

// Whether `order` puts two members of a collection that `removed` keeps out of their source order where both hold an
// anchor or an alias of one name, when the text holds an alias: an alias reads the last anchor of its name before it.
@(private = "file")
names_cross :: proc(cx: ^Cx, items: []Item, removed: []bool, order: []u8) -> bool {
	doc := cx.doc
	aliased := false
	for f in doc.facts {
		aliased ||= f.role == .Alias
	}
	if !aliased {
		return false
	}
	Named :: struct {
		place: int,
		names: [dynamic]string,
	}
	named := make([dynamic]Named, cx.a)
	place := make([]int, len(items), cx.a)
	for p in 0 ..< len(order) / 4 {
		if k := order_at(order, p); k < len(items) {
			place[k] = p
		}
	}
	for it, k in items {
		if removed[k] {
			continue
		}
		names := make([dynamic]string, cx.a)
		first := it.key if it.key != NIL else it.value
		for i in first ..< it.value + u32(core.subtree_size(doc, core.Node_Index(it.value))) {
			for f in core.all_facts(doc, core.Node_Index(i)) {
				if f.role == .Anchor || f.role == .Alias {
					name := cx.src[f.lo:f.lo + u64(f.n)]
					append(&names, string(name[1:] if len(name) > 0 && (name[0] == '&' || name[0] == '*') else name))
				}
			}
		}
		if len(names) > 0 {
			append(&named, Named{place[k], names})
		}
	}
	for a, i in named {
		for b in named[i + 1:] {
			if b.place > a.place {
				continue
			}
			for x in a.names {
				if slice.contains(b.names[:], x) {
					return true
				}
			}
		}
	}
	return false
}

@(private = "file")
order_at :: #force_inline proc(order: []u8, p: int) -> int {
	return int(endian.unchecked_get_u32le(order[4 * p:]))
}

// Writes the members of a block collection in `order`: a member's position, or `len(items) + k` for `inserts[k]`. A
// member keeps its lines, from its head comments through the lines of its value, and the blank lines before each
// place stay there. A compact first member's place takes a member without its indent, and refuses one with head
// comments, which would stand above the line the collection shares.
@(private = "file")
reorder_block :: proc(cx: ^Cx, c: u32, items: []Item, inserts: []core.Edit, order: []u8) -> bool {
	src := cx.src
	n := len(items)
	object := cx.doc.nodes[c].kind == .Object
	col := column_of(src, items[0].start)
	compact := !compose.first_on_line(src, items[0].start)
	lo := make([]u64, n, cx.a)
	hi := make([]u64, n, cx.a)
	for j := n - 1; j >= 0; j -= 1 {
		switch {
		case j > 0:
			lo[j] = compose.line_start(src, head_of(cx, items, j))
		case compact:
			lo[j] = items[0].start
		case:
			h := items[0].start
			for f in core.all_facts(cx.doc, core.Node_Index(items[0].value)) {
				if f.role == .Comment && f.lo < h && compose.first_on_line(src, f.lo) {
					h = f.lo
				}
			}
			lo[j] = compose.line_start(src, h)
		}
		hi[j] = member_end(cx, items[j], col)
		if j + 1 < n {
			hi[j] = min(hi[j], lo[j + 1])
		}
	}
	// A text whose last member ends with no line end gives that member one where it moves up, and takes the line end
	// from the member that moves last.
	end := hi[n - 1]
	open_end := end > 0 && src[end - 1] != '\n'
	count := len(order) / 4
	moves := make([dynamic]compose.Move, 0, 3 * count, cx.a)
	for p in 0 ..< count {
		if p > 0 && p < n && hi[p - 1] < lo[p] {
			append(&moves, compose.Move{text = src[hi[p - 1]:lo[p]], written = true})
		}
		last := p == count - 1
		k := order_at(order, p)
		if k >= n {
			m, ok := member_text(cx, inserts[k - n], object, col)
			if !ok {
				return false
			}
			b := make([dynamic]u8, cx.a)
			if !(compact && p == 0) {
				put_spaces_to(&b, col)
			}
			append(&b, ..m)
			if !(last && open_end) {
				compose.puts(&b, cx.eol)
			}
			append(&moves, compose.Move{text = b[:], written = true})
			continue
		}
		from, to := lo[k], hi[k]
		if compact && p == 0 && k != 0 {
			if compose.line_start(src, from) != compose.line_start(src, items[k].start) {
				return refuse_edit(cx, items[k].value, .No_Line)
			}
			from = items[k].start
		}
		if compact && p != 0 && k == 0 {
			b := make([dynamic]u8, cx.a)
			put_spaces_to(&b, col)
			append(&moves, compose.Move{text = b[:], written = true})
		}
		if open_end && last && k != n - 1 {
			to -= 1
			if to > from && src[to - 1] == '\r' {
				to -= 1
			}
		}
		append(&moves, compose.Move{lo = from, hi = to})
		if open_end && !last && k == n - 1 {
			append(&moves, compose.Move{text = transmute([]u8)cx.eol, written = true})
		}
	}
	append(&cx.splices, compose.Splice{lo = lo[0], hi = end, moves = moves[:], seq = len(cx.splices)})
	return true
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
	compact := !compose.first_on_line(src, items[0].start)
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
			compose.puts(&b, cx.eol)
			put_spaces_to(&b, col)
			add(cx, items[0].start, items[0].start, b[:])
			continue
		}
		if at == 0 && compact {
			at = 1
		}
		pos := slot_at(cx, items, at, compact)
		if pos == u64(len(src)) && (pos == 0 || src[pos - 1] != '\n') {
			compose.puts(&b, cx.eol)
			put_spaces_to(&b, col)
			append(&b, ..m)
		} else {
			put_spaces_to(&b, col)
			append(&b, ..m)
			compose.puts(&b, cx.eol)
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
		return items[0].start if compact else compose.line_start(cx.src, items[0].start)
	case j < len(items):
		return compose.line_start(cx.src, head_of(cx, items, j))
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
		q = compose.next_line(src, q)
	}
	for {
		r := q
		for r < u64(len(src)) && compose.blank_line(src, r) {
			r = compose.next_line(src, r)
		}
		ccol, comment := comment_line(src, r)
		if r >= u64(len(src)) || !comment || ccol <= col {
			return q
		}
		q = compose.next_line(src, r)
	}
}

// The text of an inserted member or element of a block collection at column `col`, without its line end.
@(private = "file")
member_text :: proc(cx: ^Cx, e: core.Edit, object: bool, col: int) -> ([]u8, bool) {
	t := trim_break(e.text)
	sh := shape_text(cx, t)
	b := make([dynamic]u8, cx.a)
	if !object {
		compose.puts(&b, "- ")
		put_lines(cx, &b, t, col + 2 if sh.form == .Block else col)
		return b[:], true
	}
	k, ok := spell_key(string(e.key), false, cx.a)
	if !ok {
		return nil, refuse_edit(cx, u32(e.node), .Long_Key)
	}
	append(&b, ..k)
	if sh.form != .Block {
		compose.puts(&b, ": ")
		put_lines(cx, &b, t, col)
		return b[:], true
	}
	learn_layout(cx)
	bcol := col + (cx.seq_off if sh.seq else cx.step)
	body := t
	if sh.head > 0 {
		compose.puts(&b, ": ")
		append(&b, ..t[:sh.head])
		body = t[bytes.index_byte(t, '\n') + 1:]
	} else {
		compose.puts(&b, ":")
	}
	compose.puts(&b, cx.eol)
	put_spaces_to(&b, bcol)
	put_lines(cx, &b, body, bcol)
	return b[:], true
}

@(private = "file")
regroup_flow :: proc(cx: ^Cx, c: u32, items: []Item, removed: []bool, inserts: []core.Edit, order: []u8) -> bool {
	object := cx.doc.nodes[c].kind == .Object
	texts := make([]compose.Flow_Insert, len(inserts), cx.a)
	for e, k in inserts {
		t := trim_break(e.text)
		m := make([dynamic]u8, cx.a)
		if object {
			key, ok := spell_key(string(e.key), true, cx.a)
			if !ok {
				return refuse_edit(cx, c, .Long_Key)
			}
			append(&m, ..key)
			compose.puts(&m, ": ")
		}
		append(&m, ..flow_text(cx, c, t, shape_text(cx, t)))
		texts[k] = {int(e.at), m[:]}
	}
	if order != nil {
		spelled := make([][]u8, len(texts), cx.a)
		for t, k in texts {
			spelled[k] = t.text
		}
		return compose.flow_order(&cx.splices, cx.src, items, order, spelled, cx.eol, cx.a) || refuse_edit(cx, c, .Flow_Comment)
	}
	compose.flow_splices(&cx.splices, cx.src, items, removed, texts, cx.lo[c] + 1, cx.hi[c] - 1, cx.eol, false, cx.a)
	return true
}
