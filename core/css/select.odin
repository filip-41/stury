package css

import "base:runtime"
import spell "../spell"
import kernel "../kernel"
import core ".."

// Matching walks the elements of a value in preorder, keeping the chain of elements open above the one it is at as
// frames, and tests each against the selector from its last compound leftward through the frames its combinators
// reach. An element is a member whose key is not `#text`: of an object node of a markup document, each in document
// order, and of a built object, as an edit leaves one, each member in order, or each item of a member that is an
// array, which is how a repeated name reads.

// An element the match can reach: its key and value nodes, its parent's frame, -1 for a member of the walk's root,
// and its place among its parent's elements, from 1. A member of a built object has a key of `BUILT` or more, past
// which is its place in the array its member is, from 1, or 0 for none, and its value is its member's slot in the
// parent's object. A walk reads the nodes of one document.
@(private)
Frame :: struct {
	key, value: core.Node_Index,
	parent:     i32,
	index:      u32,
}

@(private)
BUILT :: core.Node_Index(1 << 31)

// The elements of a value being read: an object node's pairs, or a built object's members and the items of the one
// that is an array.
@(private)
Children :: struct {
	pairs: core.Pair_Iter,
	obj:   ^core.Object,
	i, j:  u32,
}

// An object being walked: its elements, the frame of its element, and the frame count its children's frames start at.
@(private)
Level :: struct {
	children: Children,
	frame:    i32,
	top:      int,
	count:    u32,
}

@(private)
Matcher :: struct {
	doc:    ^core.Document,
	sel:    ^Selector,
	root:   core.Value,
	frames: [dynamic]Frame,
	levels: [dynamic]Level,
	fold:   bool,
	err:    runtime.Allocator_Error,
}

// The value nodes of the elements of `doc` that `sel` matches, in document order, in `allocator`: the descendants of
// node `from`, an element's value or the root, matched within the whole document, as `querySelectorAll` matches. A
// document of a format with no attributes, and a `from` with no child elements, has none. Under the document's
// `Readers.fold_names`, as HTML's, names compare ASCII case-insensitively. An attribute value compares as written
// unless the selector's `i` flag says otherwise.
//
// The walk reads each element once and allocates only for its frames. `:has` walks the element's subtree, or its
// following siblings' for `+` and `~`, `~` and the counts of `:nth-last-*` and `*-of-type` read the element's
// siblings, and a decode of an attribute value longer than 256 bytes is made in the temp allocator.
select :: proc(doc: ^core.Document, sel: ^Selector, from := core.ROOT, allocator := context.allocator) -> (found: []core.Node_Index, err: runtime.Allocator_Error) {
	if !core.is_markup(doc) || int(from) >= len(doc.nodes) || doc.nodes[from].kind != .Object {
		return nil, nil
	}
	m := Matcher{doc = doc, sel = sel, root = core.Node_Ref{doc, core.ROOT}, fold = doc.readers.fold_names}
	defer delete(m.frames)
	defer delete(m.levels)
	out := make([dynamic]core.Node_Index, allocator)
	start(&m, doc, from)
	for f in walk_next(&m, 0, false) {
		if !match_list(&m, sel.list, f, -1) {
			continue
		}
		if _, e := append(&out, m.frames[f].value); e != nil {
			m.err = e
			break
		}
	}
	if m.err != nil {
		delete(out)
		return nil, m.err
	}
	return out[:], nil
}

// An element `select_value` matched: its value, and the path to it from the value read, each step a name, then the
// element's index when its name reads as an array.
Match :: struct {
	value: core.Value,
	path:  []core.Value,
}

// `select` of the elements of value `v`, in `allocator`: the descendants of an element of a markup document within the
// whole document, or of a built object, as an edit of one leaves it, within it. The elements of a built object are
// those its members read as, so a built member's comments and attributes are those written on it. `fold` says names
// compare ASCII case-insensitively, as `Readers.fold_names` says for a document, whose own is used for a node. Each
// match's path is left nil unless `paths` asks for it, which reads the members of each element's name in its parent.
select_value :: proc(v: core.Value, sel: ^Selector, fold: bool, paths: bool, allocator := context.allocator) -> (found: []Match, err: runtime.Allocator_Error) {
	m := Matcher{sel = sel, root = v, fold = fold}
	defer delete(m.frames)
	defer delete(m.levels)
	base := i32(-1)
	if r, is_ref := core.plain(v).(core.Node_Ref); is_ref {
		if !core.is_markup(r.doc) || r.doc.nodes[r.node].kind != .Object {
			return nil, nil
		}
		m.doc, m.root, m.fold = r.doc, core.Node_Ref{r.doc, core.ROOT}, r.doc.readers.fold_names
		base = start(&m, r.doc, r.node)
	} else if core.kind(v) == .Object {
		append(&m.levels, Level{children = children_of(&m, v), frame = -1})
	}
	out := make([dynamic]Match, allocator)
	for f in walk_next(&m, 0, true) {
		if !match_list(&m, sel.list, f, -1) {
			continue
		}
		path: []core.Value
		e: runtime.Allocator_Error
		if paths {
			path, e = path_of(&m, f, base, allocator)
		}
		if e == nil {
			_, e = append(&out, Match{value = frame_value(&m, m.frames[f]), path = path})
		}
		if e != nil {
			m.err = e
			break
		}
	}
	if m.err != nil {
		delete(out)
		return nil, m.err
	}
	return out[:], nil
}

// Opens the walk of node `from` of `doc` with the frames of its ancestors, and returns the frame of its element, -1
// for the root.
@(private)
start :: proc(m: ^Matcher, doc: ^core.Document, from: core.Node_Index) -> i32 {
	top, element := ancestors(m, doc, from)
	if element {
		append(&m.levels, Level{children = {pairs = core.pairs(doc, from)}, frame = top, top = len(m.frames)})
	}
	return top
}

// The steps from frame `base`'s element, -1 for the root, down to frame `f`'s, in `allocator`.
@(private)
path_of :: proc(m: ^Matcher, f, base: i32, allocator: runtime.Allocator) -> (path: []core.Value, err: runtime.Allocator_Error) {
	steps := make([dynamic]core.Value, allocator) or_return
	for g := f; g != base && g >= 0; g = m.frames[g].parent {
		at := m.frames[g]
		name: string
		if at.key >= BUILT {
			if item := at.key - BUILT; item > 0 {
				append(&steps, f64(item - 1)) or_return
			}
			name = core.plain(parent_value(m, at)).(^core.Object).keys[at.value]
		} else {
			parent := core.plain(parent_value(m, at)).(core.Node_Ref)
			name, _ = core.token_text(m.doc.readers, &m.doc.view, m.doc.nodes[at.key], allocator)
			same := core.members_named(m.doc, parent.node, name)
			index, count := 0, 0
			for node in core.member_next(&same) {
				index = count if node == at.value else index
				count += 1
			}
			if count > 1 {
				append(&steps, f64(index)) or_return
			}
		}
		append(&steps, name) or_return
	}
	for i in 0 ..< len(steps) / 2 {
		steps[i], steps[len(steps) - 1 - i] = steps[len(steps) - 1 - i], steps[i]
	}
	return steps[:], nil
}

// The frames of the elements from the root's member down to the one whose value is `from`, and the last one's,
// -1 for the root. False when `from` is no element's value.
@(private)
ancestors :: proc(m: ^Matcher, doc: ^core.Document, from: core.Node_Index) -> (frame: i32, element: bool) {
	frame = -1
	at := core.ROOT
	for at != from {
		it := core.pairs(doc, at)
		count: u32
		inside := false
		for k, v in core.pair_next(&it) {
			if !is_element(doc, k) {
				continue
			}
			count += 1
			if from >= v && int(from) < int(v) + core.subtree_size(doc, v) {
				push_frame(m, {key = k, value = v, parent = frame, index = count}) or_return
				frame, at, inside = i32(len(m.frames) - 1), v, true
				break
			}
		}
		if !inside {
			return -1, false
		}
	}
	return frame, true
}

// Whether key `k` names an element, not a run of text.
@(private)
is_element :: #force_inline proc(doc: ^core.Document, k: core.Node_Index) -> bool {
	t := doc.nodes[k]
	return t.spelling & core.SPELLING_SYNTHETIC != core.SPELLING_SYNTHETIC || !doc.readers.key_equals(&doc.view, t, core.MARKUP_TEXT)
}

// The elements of `v`, an object node's or a built object's, none for any other value.
@(private)
children_of :: proc(m: ^Matcher, v: core.Value) -> Children {
	#partial switch x in core.plain(v) {
	case core.Node_Ref:
		if x.doc.nodes[x.node].kind == .Object {
			m.doc = x.doc
			return {pairs = core.pairs(x.doc, x.node)}
		}
	case ^core.Object:
		return {obj = x}
	}
	return {}
}

// The next element of `it`, its parent and index unset.
@(private)
next_element :: #force_inline proc(m: ^Matcher, it: ^Children) -> (Frame, bool) {
	if it.obj == nil {
		return next_node(m, it)
	}
	return next_built(it)
}

@(private)
next_node :: #force_inline proc(m: ^Matcher, it: ^Children) -> (Frame, bool) {
	for k, v in core.pair_next(&it.pairs) {
		if is_element(m.doc, k) {
			return {key = k, value = v}, true
		}
	}
	return {}, false
}

@(private)
next_built :: proc(it: ^Children) -> (Frame, bool) {
	for int(it.i) < len(it.obj.keys) {
		if _, _, is_attribute := core.member_attribute(it.obj.keys[it.i], it.obj.vals[it.i]); is_attribute || it.obj.keys[it.i] == core.MARKUP_TEXT {
			it.i += 1
			continue
		}
		a, is_array := core.plain(it.obj.vals[it.i]).(^core.Array)
		if !is_array {
			it.i += 1
			return {key = BUILT, value = core.Node_Index(it.i - 1)}, true
		}
		if int(it.j) < len(a.items) {
			it.j += 1
			return {key = BUILT + core.Node_Index(it.j), value = core.Node_Index(it.i)}, true
		}
		it.i, it.j = it.i + 1, 0
	}
	return {}, false
}

@(private)
frame_value :: #force_inline proc(m: ^Matcher, f: Frame) -> core.Value {
	if f.key < BUILT {
		return core.Node_Ref{m.doc, f.value}
	}
	v := core.plain(parent_value(m, f)).(^core.Object).vals[f.value]
	if item := f.key - BUILT; item > 0 {
		return core.plain(v).(^core.Array).items[item - 1]
	}
	return v
}

// The name of frame `f`'s element, decoded into `buf`, or into the temp allocator when `buf` is short.
@(private)
frame_name :: #force_inline proc(m: ^Matcher, f: Frame, buf: []u8) -> string {
	if f.key >= BUILT {
		return core.plain(parent_value(m, f)).(^core.Object).keys[f.value]
	}
	return token_string(m.doc, m.doc.nodes[f.key], buf)
}

@(private)
frame_children :: #force_inline proc(m: ^Matcher, f: Frame) -> Children {
	if f.key < BUILT {
		return {pairs = core.pairs(m.doc, f.value)}
	}
	return children_of(m, frame_value(m, f))
}

// Whether frame `f`'s element holds elements.
@(private)
is_object :: #force_inline proc(m: ^Matcher, f: Frame) -> bool {
	if f.key < BUILT {
		return m.doc.nodes[f.value].kind == .Object
	}
	return core.kind(frame_value(m, f)) == .Object
}

@(private)
push_frame :: proc(m: ^Matcher, f: Frame) -> bool {
	if _, err := append(&m.frames, f); err != nil {
		m.err = err
		return false
	}
	return true
}

// The frame of the next element in preorder of the levels past `base`, which it leaves when they are walked. Without
// `BUILT` every level is an object node's.
@(private)
walk_next :: proc(m: ^Matcher, base: int, $BUILT: bool) -> (frame: i32, ok: bool) {
	for len(m.levels) > base && m.err == nil {
		lv := &m.levels[len(m.levels) - 1]
		f: Frame
		more: bool
		when BUILT {
			f, more = next_element(m, &lv.children)
		} else {
			f, more = next_node(m, &lv.children)
		}
		if !more {
			pop(&m.levels)
			continue
		}
		lv.count += 1
		f.parent, f.index = lv.frame, lv.count
		resize(&m.frames, lv.top)
		push_frame(m, f) or_break
		frame = i32(len(m.frames) - 1)
		if is_object(m, f) when BUILT else m.doc.nodes[f.value].kind == .Object {
			children := frame_children(m, f) when BUILT else Children{pairs = core.pairs(m.doc, f.value)}
			if _, err := append(&m.levels, Level{children = children, frame = frame, top = len(m.frames)}); err != nil {
				m.err = err
				break
			}
		}
		return frame, true
	}
	return -1, false
}

@(private)
match_list :: proc(m: ^Matcher, list: Run, f: i32, anchor: i32) -> bool {
	for c in m.sel.complexes[list.lo:][:list.n] {
		if match_at(m, c, int(c.compounds.n) - 1, f, anchor) {
			return true
		}
	}
	return false
}

// Whether compound `j` of `c` matches frame `f` and what stands left of it matches the frames its combinators reach.
// `anchor` is the frame of the element `:has` tests, which the first compound of a relative selector relates to, or
// -1.
@(private)
match_at :: proc(m: ^Matcher, c: Complex, j: int, f: i32, anchor: i32) -> bool {
	compound := m.sel.compounds[int(c.compounds.lo) + j]
	for t in m.sel.tests[compound.tests.lo:][:compound.tests.n] {
		if !test(m, t, f) {
			return false
		}
	}
	if j == 0 && !c.relative {
		return true
	}
	switch compound.combinator {
	case .Child:
		parent := m.frames[f].parent
		return parent >= 0 && left_of(m, c, j, parent, anchor)
	case .Descendant:
		for up := m.frames[f].parent; up >= 0; up = m.frames[up].parent {
			if left_of(m, c, j, up, anchor) {
				return true
			}
		}
		return false
	case .Next, .Subsequent:
		at := m.frames[f]
		it := children_of(m, parent_value(m, at))
		before := Frame{parent = at.parent}
		for g in next_element(m, &it) {
			if before.index + 1 == at.index {
				break
			}
			before = {key = g.key, value = g.value, parent = at.parent, index = before.index + 1}
			if compound.combinator == .Subsequent && sibling_left_of(m, c, j, before, anchor) {
				return true
			}
		}
		return compound.combinator == .Next && before.index > 0 && sibling_left_of(m, c, j, before, anchor)
	}
	return false
}

// Whether frame `g` matches what stands left of compound `j`: compound `j - 1`, or for the first compound of a
// relative selector the anchor, the element with the anchor's parent and place.
@(private)
left_of :: proc(m: ^Matcher, c: Complex, j: int, g: i32, anchor: i32) -> bool {
	if j == 0 {
		return anchor >= 0 && m.frames[g].parent == m.frames[anchor].parent && m.frames[g].index == m.frames[anchor].index
	}
	return match_at(m, c, j - 1, g, anchor)
}

// `left_of` for a sibling, which has a frame only while it is tested.
@(private)
sibling_left_of :: proc(m: ^Matcher, c: Complex, j: int, sibling: Frame, anchor: i32) -> bool {
	n := len(m.frames)
	push_frame(m, sibling) or_return
	ok := left_of(m, c, j, i32(n), anchor)
	resize(&m.frames, n)
	return ok
}

// The value of the parent of frame `f`'s element, the walk's root for a member of it.
@(private)
parent_value :: #force_inline proc(m: ^Matcher, f: Frame) -> core.Value {
	return frame_value(m, m.frames[f.parent]) if f.parent >= 0 else m.root
}

@(private)
test :: proc(m: ^Matcher, t: Test, f: i32) -> bool {
	switch t.kind {
	case .Type:
		buf: [64]u8
		return names_equal(m.fold, frame_name(m, m.frames[f], buf[:]), text(m, t.name))
	case .Attribute:
		return attribute(m, t, m.frames[f])
	case .Is:
		return match_list(m, t.list, f, -1)
	case .Not:
		return !match_list(m, t.list, f, -1)
	case .Has:
		return has(m, t.list, f)
	case .Root:
		if m.frames[f].parent >= 0 {
			return false
		}
		it := children_of(m, m.root)
		elements := 0
		for _ in next_element(m, &it) {
			elements += 1
		}
		return elements == 1
	case .Empty:
		#partial switch v in core.plain(frame_value(m, m.frames[f])) {
		case core.Node_Ref:
			n := v.doc.nodes[v.node]
			if n.kind != .Plain || n.n == 0 {
				return n.kind == .Plain
			}
			buf: [256]u8
			return n.spelling & core.SPELLING_DECODE != 0 && len(token_string(v.doc, n, buf[:])) == 0
		case ^core.Object:
			for k, i in v.keys {
				if _, _, is_attribute := core.member_attribute(k, v.vals[i]); !is_attribute {
					return false
				}
			}
			return true
		case string:
			return len(v) == 0
		case nil:
			return true
		}
		return false
	case .Nth:
		return nth(t.a, t.b, position(m, t, f))
	}
	return false
}

@(private)
text :: #force_inline proc(m: ^Matcher, r: Run) -> string {
	return string(m.sel.text[r.lo:][:r.n])
}

// The text of token `t`: its span, or its decode into `buf`, or into the temp allocator when `buf` is short.
@(private)
token_string :: proc(doc: ^core.Document, t: core.Token, buf: []u8) -> string {
	if t.spelling & core.SPELLING_DECODE == 0 {
		return string(doc.src[t.lo:][:t.n])
	}
	room := core.view_room(doc.readers, &doc.view, t)
	s, _ := doc.readers.text(&doc.view, t, buf if room <= len(buf) else make([]u8, room, context.temp_allocator))
	return s
}

@(private)
names_equal :: #force_inline proc(fold_case: bool, a, b: string) -> bool {
	return spell.ascii_fold_equal(a, b) if fold_case else a == b
}

// Whether the element whose value is `v` has the attribute `t` names with a value its operator takes.
@(private)
attribute :: proc(m: ^Matcher, t: Test, f: Frame) -> bool {
	want := text(m, t.name)
	v: core.Value = core.Node_Ref{m.doc, f.value}
	if f.key >= BUILT {
		v = frame_value(m, f)
	}
	context.allocator = context.temp_allocator
	if written, rebuilt := core.rebuilt_attributes(v); rebuilt {
		if written == nil {
			return false
		}
		for name, i in written.keys {
			if names_equal(m.fold, name, want) {
				have, _ := written.vals[i].(string)
				return t.op == .Exists || value_matches(t, have, text(m, t.value))
			}
		}
		return false
	}
	if o, is_built := core.plain(v).(^core.Object); is_built {
		for k, i in o.keys {
			if name, have, is_attribute := core.member_attribute(k, o.vals[i]); is_attribute && names_equal(m.fold, name, want) {
				return t.op == .Exists || value_matches(t, have, text(m, t.value))
			}
		}
		return false
	}
	r, is_ref := core.plain(v).(core.Node_Ref)
	if !is_ref {
		return false
	}
	it := core.attributes_of(r.doc, r.node)
	for name, value in core.attribute_next(&it) {
		name_buf: [64]u8
		if !names_equal(m.fold, token_string(r.doc, name, name_buf[:]), want) {
			continue
		}
		if t.op == .Exists {
			return true
		}
		value_buf: [256]u8
		return value_matches(t, token_string(r.doc, value, value_buf[:]), text(m, t.value))
	}
	return false
}

@(private)
value_matches :: proc(t: Test, have, want: string) -> bool {
	switch t.op {
	case .Exists:
		return true
	case .Equals:
		return names_equal(t.fold, have, want)
	case .Dash:
		return names_equal(t.fold, have, want) || len(have) > len(want) && have[len(want)] == '-' && names_equal(t.fold, have[:len(want)], want)
	case .Prefix:
		return len(want) > 0 && len(have) >= len(want) && names_equal(t.fold, have[:len(want)], want)
	case .Suffix:
		return len(want) > 0 && len(have) >= len(want) && names_equal(t.fold, have[len(have) - len(want):], want)
	case .Substring:
		if len(want) == 0 {
			return false
		}
		for i in 0 ..= len(have) - len(want) {
			if names_equal(t.fold, have[i:][:len(want)], want) {
				return true
			}
		}
		return false
	case .Includes:
		if len(want) == 0 {
			return false
		}
		for i := 0; i < len(have); {
			for i < len(have) && kernel.is_markup_ws(have[i]) {
				i += 1
			}
			j := i
			for j < len(have) && !kernel.is_markup_ws(have[j]) {
				j += 1
			}
			if j > i && names_equal(t.fold, have[i:j], want) {
				return true
			}
			i = j
		}
		return false
	}
	return false
}

// Whether `p = a*n + b` for some `n >= 0`.
@(private)
nth :: proc(a, b, p: i64) -> bool {
	if a == 0 {
		return p == b
	}
	return (p - b) % a == 0 && (p - b) / a >= 0
}

// The position of frame `f`'s element among its siblings as `:nth` test `t` counts them, from 1: from the first or
// the last, among those of its name or those that match `t.list`. An element `t.list` does not match has none. The
// count stops past `b` when no larger position can match.
@(private)
position :: proc(m: ^Matcher, t: Test, f: i32) -> i64 {
	at := m.frames[f]
	if !t.last && !t.of_type && t.list.n == 0 {
		return i64(at.index)
	}
	if t.list.n > 0 && !match_list(m, t.list, f, -1) {
		return 0
	}
	name_buf: [64]u8
	name := frame_name(m, at, name_buf[:])
	it := children_of(m, parent_value(m, at))
	p, index := i64(1), u32(0)
	after := false
	for g in next_element(m, &it) {
		index += 1
		if index == at.index {
			if !t.last {
				break
			}
			after = true
			continue
		}
		if t.last && !after {
			continue
		}
		if t.of_type {
			buf: [64]u8
			if frame_name(m, {key = g.key, value = g.value, parent = at.parent}, buf[:]) != name {
				continue
			}
		}
		if t.list.n > 0 && !sibling_matches(m, t.list, {key = g.key, value = g.value, parent = at.parent, index = index}) {
			continue
		}
		p += 1
		if t.a <= 0 && p > t.b {
			break
		}
	}
	return p
}

@(private)
sibling_matches :: proc(m: ^Matcher, list: Run, sibling: Frame) -> bool {
	n := len(m.frames)
	push_frame(m, sibling) or_return
	ok := match_list(m, list, i32(n), -1)
	resize(&m.frames, n)
	return ok
}

// Whether a relative selector of `list` matches from frame `f`'s element: an element of its subtree, or for one that
// starts with `+` or `~`, its next sibling or a following one, or an element of their subtrees.
@(private)
has :: proc(m: ^Matcher, list: Run, f: i32) -> bool {
	at := m.frames[f]
	for c in m.sel.complexes[list.lo:][:list.n] {
		switch m.sel.compounds[c.compounds.lo].combinator {
		case .Descendant, .Child:
			if subtree_matches(m, c, f, f) {
				return true
			}
		case .Next, .Subsequent:
			it := children_of(m, parent_value(m, at))
			index := u32(0)
			for g in next_element(m, &it) {
				index += 1
				if index <= at.index {
					continue
				}
				n := len(m.frames)
				push_frame(m, {key = g.key, value = g.value, parent = at.parent, index = index}) or_return
				ok := match_at(m, c, int(c.compounds.n) - 1, i32(n), f) || subtree_matches(m, c, i32(n), f)
				resize(&m.frames, n)
				if ok {
					return true
				}
				if m.sel.compounds[c.compounds.lo].combinator == .Next {
					break
				}
			}
		}
	}
	return false
}

// Whether relative selector `c` matches an element in the subtree of frame `g`'s element, walked past the levels
// open now.
@(private)
subtree_matches :: proc(m: ^Matcher, c: Complex, g: i32, anchor: i32) -> bool {
	if !is_object(m, m.frames[g]) {
		return false
	}
	base, frames := len(m.levels), len(m.frames)
	if _, err := append(&m.levels, Level{children = frame_children(m, m.frames[g]), frame = g, top = frames}); err != nil {
		m.err = err
		return false
	}
	found := false
	for d in walk_next(m, base, true) {
		if match_at(m, c, int(c.compounds.n) - 1, d, anchor) {
			found = true
			break
		}
	}
	resize(&m.levels, base)
	resize(&m.frames, frames)
	return found
}
