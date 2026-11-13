package css

import "base:runtime"
import core ".."

// Matching walks the elements of a document in preorder, keeping the chain of elements open above the one it is at
// as frames, and tests each against the selector from its last compound leftward through the frames its combinators
// reach. An element of a markup document is a member whose key is not `#text`, and its node is its value's.

// An element the match can reach: its key and value, its parent's frame, -1 for a member of the document's root, and
// its place among its parent's elements, from 1.
@(private)
Frame :: struct {
	key, value: core.Node_Index,
	parent:     i32,
	index:      u32,
}

// An object being walked: its members, the frame of its element, and the frame count its children's frames start at.
@(private)
Level :: struct {
	pairs: core.Pair_Iter,
	frame: i32,
	top:   int,
	count: u32,
}

@(private)
Matcher :: struct {
	doc:    ^core.Document,
	sel:    ^Selector,
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
	m := Matcher{doc = doc, sel = sel, fold = doc.readers.fold_names}
	defer delete(m.frames)
	defer delete(m.levels)
	out := make([dynamic]core.Node_Index, allocator)
	top, element := ancestors(&m, from)
	if element {
		append(&m.levels, Level{pairs = core.doc_pairs(doc, from), frame = top, top = len(m.frames)})
	}
	for f in walk_next(&m, 0) {
		if match_list(&m, sel.list, f, core.NO_NODE) {
			if _, e := append(&out, m.frames[f].value); e != nil {
				m.err = e
				break
			}
		}
	}
	if m.err != nil {
		delete(out)
		return nil, m.err
	}
	return out[:], nil
}

// The frames of the elements from the root's member down to the one whose value is `from`, and the last one's,
// -1 for the root. False when `from` is no element's value.
@(private)
ancestors :: proc(m: ^Matcher, from: core.Node_Index) -> (frame: i32, element: bool) {
	frame = -1
	at := core.ROOT
	for at != from {
		it := core.doc_pairs(m.doc, at)
		count: u32
		inside := false
		for k, v in core.doc_pair_next(&it) {
			if !is_element(m.doc, k) {
				continue
			}
			count += 1
			if from >= v && int(from) < int(v) + core.subtree_size(m.doc, v) {
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

@(private)
push_frame :: proc(m: ^Matcher, f: Frame) -> bool {
	if _, err := append(&m.frames, f); err != nil {
		m.err = err
		return false
	}
	return true
}

// The frame of the next element in preorder of the levels past `base`, which it leaves when they are walked.
@(private)
walk_next :: proc(m: ^Matcher, base: int) -> (frame: i32, ok: bool) {
	for len(m.levels) > base && m.err == nil {
		lv := &m.levels[len(m.levels) - 1]
		k, v, more := core.doc_pair_next(&lv.pairs)
		if !more {
			pop(&m.levels)
			continue
		}
		if !is_element(m.doc, k) {
			continue
		}
		lv.count += 1
		parent, index := lv.frame, lv.count
		resize(&m.frames, lv.top)
		push_frame(m, {key = k, value = v, parent = parent, index = index}) or_break
		frame = i32(len(m.frames) - 1)
		if m.doc.nodes[v].kind == .Object {
			if _, err := append(&m.levels, Level{pairs = core.doc_pairs(m.doc, v), frame = frame, top = len(m.frames)}); err != nil {
				m.err = err
				break
			}
		}
		return frame, true
	}
	return -1, false
}

@(private)
match_list :: proc(m: ^Matcher, list: Run, f: i32, anchor: core.Node_Index) -> bool {
	for c in m.sel.complexes[list.lo:][:list.n] {
		if match_at(m, c, int(c.compounds.n) - 1, f, anchor) {
			return true
		}
	}
	return false
}

// Whether compound `j` of `c` matches frame `f` and what stands left of it matches the frames its combinator reaches.
// `anchor` is the value of the element `:has` tests, which the first compound of a relative selector relates to.
@(private)
match_at :: proc(m: ^Matcher, c: Complex, j: int, f: i32, anchor: core.Node_Index) -> bool {
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
		it := core.doc_pairs(m.doc, parent_value(m, at))
		before := Frame{parent = at.parent}
		for k, v in core.doc_pair_next(&it) {
			if v == at.value {
				break
			}
			if !is_element(m.doc, k) {
				continue
			}
			before = {key = k, value = v, parent = at.parent, index = before.index + 1}
			if compound.combinator == .Subsequent && sibling_left_of(m, c, j, before, anchor) {
				return true
			}
		}
		return compound.combinator == .Next && before.index > 0 && sibling_left_of(m, c, j, before, anchor)
	}
	return false
}

// Whether frame `g` matches what stands left of compound `j`: compound `j - 1`, or the anchor for the first compound
// of a relative selector.
@(private)
left_of :: proc(m: ^Matcher, c: Complex, j: int, g: i32, anchor: core.Node_Index) -> bool {
	if j == 0 {
		return m.frames[g].value == anchor
	}
	return match_at(m, c, j - 1, g, anchor)
}

// `left_of` for a sibling, which has a frame only while it is tested.
@(private)
sibling_left_of :: proc(m: ^Matcher, c: Complex, j: int, sibling: Frame, anchor: core.Node_Index) -> bool {
	n := len(m.frames)
	push_frame(m, sibling) or_return
	ok := left_of(m, c, j, i32(n), anchor)
	resize(&m.frames, n)
	return ok
}

// The value of the parent of frame `f`'s element, the root for a member of it.
@(private)
parent_value :: #force_inline proc(m: ^Matcher, f: Frame) -> core.Node_Index {
	return m.frames[f.parent].value if f.parent >= 0 else core.ROOT
}

@(private)
test :: proc(m: ^Matcher, t: Test, f: i32) -> bool {
	switch t.kind {
	case .Type:
		buf: [64]u8
		return names_equal(m.fold, token_string(m.doc, m.doc.nodes[m.frames[f].key], buf[:]), text(m, t.name))
	case .Attribute:
		return attribute(m, t, m.frames[f].value)
	case .Is:
		return match_list(m, t.list, f, core.NO_NODE)
	case .Not:
		return !match_list(m, t.list, f, core.NO_NODE)
	case .Has:
		return has(m, t.list, f)
	case .Root:
		if m.frames[f].parent >= 0 {
			return false
		}
		it := core.doc_pairs(m.doc, core.ROOT)
		elements := 0
		for k in core.doc_pair_next(&it) {
			elements += int(is_element(m.doc, k))
		}
		return elements == 1
	case .Empty:
		v := m.doc.nodes[m.frames[f].value]
		if v.kind != .Plain || v.n == 0 {
			return v.kind == .Plain
		}
		buf: [256]u8
		return v.spelling & core.SPELLING_DECODE != 0 && len(token_string(m.doc, v, buf[:])) == 0
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
	return fold_equal(a, b) if fold_case else a == b
}

// Whether the element whose value is `v` has the attribute `t` names with a value its operator takes.
@(private)
attribute :: proc(m: ^Matcher, t: Test, v: core.Node_Index) -> bool {
	want := text(m, t.name)
	it := core.attributes_of(m.doc, v)
	for name, value in core.attribute_next(&it) {
		name_buf: [64]u8
		if !names_equal(m.fold, token_string(m.doc, name, name_buf[:]), want) {
			continue
		}
		if t.op == .Exists {
			return true
		}
		value_buf: [256]u8
		return value_matches(t, token_string(m.doc, value, value_buf[:]), text(m, t.value))
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
			for i < len(have) && is_space(have[i]) {
				i += 1
			}
			j := i
			for j < len(have) && !is_space(have[j]) {
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
	if t.list.n > 0 && !match_list(m, t.list, f, core.NO_NODE) {
		return 0
	}
	name_buf: [64]u8
	name := token_string(m.doc, m.doc.nodes[at.key], name_buf[:])
	it := core.doc_pairs(m.doc, parent_value(m, at))
	p, index := i64(1), u32(0)
	after := false
	for k, v in core.doc_pair_next(&it) {
		if !is_element(m.doc, k) {
			continue
		}
		index += 1
		if v == at.value {
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
			if token_string(m.doc, m.doc.nodes[k], buf[:]) != name {
				continue
			}
		}
		if t.list.n > 0 && !sibling_matches(m, t.list, {key = k, value = v, parent = at.parent, index = index}) {
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
	ok := match_list(m, list, i32(n), core.NO_NODE)
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
			if subtree_matches(m, c, f, at.value) {
				return true
			}
		case .Next, .Subsequent:
			it := core.doc_pairs(m.doc, parent_value(m, at))
			index := u32(0)
			after := false
			for k, v in core.doc_pair_next(&it) {
				if !is_element(m.doc, k) {
					continue
				}
				index += 1
				if v == at.value {
					after = true
					continue
				}
				if !after {
					continue
				}
				n := len(m.frames)
				push_frame(m, {key = k, value = v, parent = at.parent, index = index}) or_return
				ok := match_at(m, c, int(c.compounds.n) - 1, i32(n), at.value) || subtree_matches(m, c, i32(n), at.value)
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
subtree_matches :: proc(m: ^Matcher, c: Complex, g: i32, anchor: core.Node_Index) -> bool {
	v := m.frames[g].value
	if m.doc.nodes[v].kind != .Object {
		return false
	}
	base, frames := len(m.levels), len(m.frames)
	if _, err := append(&m.levels, Level{pairs = core.doc_pairs(m.doc, v), frame = g, top = frames}); err != nil {
		m.err = err
		return false
	}
	found := false
	for d in walk_next(m, base) {
		if match_at(m, c, int(c.compounds.n) - 1, d, anchor) {
			found = true
			break
		}
	}
	resize(&m.levels, base)
	resize(&m.frames, frames)
	return found
}
