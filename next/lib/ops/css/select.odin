package css

import "base:runtime"
import "stury:lib/base/kernel"
import "stury:lib/core/markup"
import "stury:lib/core/tape"

// Matching walks the elements of a markup document in preorder, keeping the chain of elements open above the one it is
// at as frames, and tests each against the selector from its last compound leftward through the frames its
// combinators reach. An element is a member of an element's value, or of the document's root, whose key is no `#text`.
// The walk and the match keep their state in explicit stacks, so the depth of a document costs no native stack, and
// the match recurses only as deep as the selector's own nesting.

// Reads the name and the value, as texts `tape.node_text` reads with the document, of attribute fact `f` of `doc`. A
// format that has attributes gives its own, which decodes them as the format does.
Attribute_Reader :: #type proc "contextless" (doc: ^tape.Document, f: tape.Fact) -> (name, value: tape.Token)

// What a select needs beside the selector and the document.
Options :: struct {
	attribute: Attribute_Reader,
	// Element and attribute names compare ASCII case-insensitively, as HTML's do. An attribute value compares as
	// written unless the selector's `i` flag says otherwise.
	fold:      bool,
}

// One step of the path from the element a select starts at to an element it found: the key of the member, and for a
// name its parent repeats the place among the members of that name, from 0, else -1.
Step :: struct {
	key:   tape.Node_Index,
	index: i32,
}

// An element a select found: the node of its value, and its steps in `Found.steps`.
Match :: struct {
	value: tape.Node_Index,
	lo, n: u32,
}

// What a select found, in document order. `destroy_found` frees it.
// `partial` is true when the document holds only part of its values and could not be selected from.
Found :: struct {
	matches: [dynamic]Match,
	steps:   [dynamic]Step,
	partial: bool,
}

// The steps from the element the select started at to the one `m` found.
steps_of :: proc(found: ^Found, m: Match) -> []Step {
	return found.steps[m.lo:][:m.n]
}

destroy_found :: proc(found: ^Found) {
	delete(found.matches)
	delete(found.steps)
	found^ = {}
}

// An element the match can reach: its key and value nodes, its parent's frame, -1 for a member of the document's root,
// its place among its parent's elements, from 1, and its depth below the root, from 0.
@(private)
Frame :: struct {
	key, value: tape.Node_Index,
	parent:     i32,
	index:      u32,
	depth:      u32,
}

// An element being walked: its children, its frame, the frame count its children's frames start at, and the children
// walked so far.
@(private)
Level :: struct {
	children: tape.Children,
	frame:    i32,
	top:      int,
	count:    u32,
}

// The place of the last element a level gave a path step to, so that the next one of the same name in the same parent
// counts from it rather than from the first.
@(private)
Group_Run :: struct {
	parent, key, value: tape.Node_Index,
	index, count:       i32,
}

@(private)
Matcher :: struct {
	doc:     ^tape.Document,
	reader:  tape.Reader,
	sel:     ^Selector,
	opts:    Options,
	frames:  [dynamic]Frame,
	levels:  [dynamic]Level,
	runs:    [dynamic]Group_Run, // by depth
	scratch: [dynamic]u8,
	err:     runtime.Allocator_Error,
}

// The elements of `doc` below node `from`, that `sel` matches, in document order, in `allocator`. `from` is the root,
// or the value of an element, which `:root`, the combinators and the positions still read in the document's whole
// tree. Any other node, and a document that holds only part of its values, have no matches. The walk reads each element
// once and allocates only for its frames and the answer. `:has` walks the element's subtree, or its following
// siblings' for `+` and `~`, `~` and the counts of `:nth-last-*` and `*-of-type` read the element's siblings, and a name
// or an attribute value past 256 bytes is decoded into one buffer that grows.
select :: proc(doc: ^tape.Document, from: tape.Node_Index, sel: ^Selector, opts: Options, allocator := context.allocator) -> (found: Found, err: runtime.Allocator_Error) {
	m := Matcher {
		doc    = doc,
		reader = {doc = doc},
		sel    = sel,
		opts   = opts,
		frames = make([dynamic]Frame, allocator),
		levels = make([dynamic]Level, allocator),
		runs   = make([dynamic]Group_Run, allocator),
		scratch = make([dynamic]u8, allocator),
	}
	defer delete(m.frames)
	defer delete(m.levels)
	defer delete(m.runs)
	defer delete(m.scratch)
	found = {
		matches = make([dynamic]Match, allocator),
		steps   = make([dynamic]Step, allocator),
	}
	if doc.partial != nil {
		found.partial = true
		return found, nil
	}
	if len(doc.nodes) > 0 {
		base := start(&m, from)
		for f in walk_next(&m, 0) {
			if !match_list(&m, sel.list, f, -1) {
				continue
			}
			record(&m, &found, f, base)
		}
	}
	if m.err != nil {
		destroy_found(&found)
		return {}, m.err
	}
	return found, nil
}

// Opens the walk below node `from` with the frames of the elements above it, and returns the frame of its element, -1
// for the root. A `from` that is no element's value and not the root opens none.
@(private)
start :: proc(m: ^Matcher, from: tape.Node_Index) -> (base: i32) {
	base = -1
	at := tape.ROOT
	for at != from {
		it := children_at(at)
		count: u32
		found := false
		for g in next_element(m, &it) {
			count += 1
			if from >= g.value && from < tape.node_after(m.doc, g.value) {
				if !push_frame(m, {key = g.key, value = g.value, parent = base, index = count, depth = 0 if base < 0 else m.frames[base].depth + 1}) {
					return -1
				}
				base, at, found = i32(len(m.frames) - 1), g.value, true
				break
			}
		}
		if !found {
			return -1
		}
	}
	if m.doc.nodes[from].kind == .Object {
		if _, err := append(&m.levels, Level{children = children_at(from), frame = base, top = len(m.frames)}); err != nil {
			m.err = err
			return -1
		}
	}
	return base
}

// Adds the path to frame `f`'s element, from the element at frame `base`, to `found`.
@(private)
record :: proc(m: ^Matcher, found: ^Found, f, base: i32) {
	lo := len(found.steps)
	for g := f; g != base; g = m.frames[g].parent {
		if _, err := append(&found.steps, Step{key = m.frames[g].key, index = group_index(m, g)}); err != nil {
			m.err = err
			return
		}
	}
	steps := found.steps[lo:]
	for i in 0 ..< len(steps) / 2 {
		steps[i], steps[len(steps) - 1 - i] = steps[len(steps) - 1 - i], steps[i]
	}
	if _, err := append(&found.matches, Match{value = m.frames[f].value, lo = u32(lo), n = u32(len(steps))}); err != nil {
		m.err = err
	}
}

// The place of frame `g`'s element among its parent's members of its name, from 0, -1 when it is the only one. A
// parent's members are counted from where the last element of the same depth in the same parent left off.
@(private)
group_index :: proc(m: ^Matcher, g: i32) -> i32 {
	at := m.frames[g]
	parent := parent_node(m, at)
	for len(m.runs) <= int(at.depth) {
		if _, err := append(&m.runs, Group_Run{parent = tape.NO_NODE}); err != nil {
			m.err = err
			return -1
		}
	}
	run := &m.runs[at.depth]
	if run.parent == parent && at.value > run.value && same_name(m, run.key, at.key) {
		index := run.index
		it := tape.Children{container = parent, next = tape.node_after(m.doc, run.value)}
		for {
			key, value, p := tape.next_child(m.reader, &it, .Group)
			if p != .Found || value == at.value {
				break
			}
			if same_name(m, key, at.key) {
				index += 1
			}
		}
		run.index, run.key, run.value = index + 1, at.key, at.value
		return run.index if run.count > 1 else -1
	}
	buf: [64]u8
	name := node_string(m, m.doc.nodes[at.key], buf[:])
	it, p := tape.named(m.reader, parent, name)
	if p != .Found {
		return -1
	}
	index, count := i32(0), i32(0)
	for {
		_, value, q := tape.next_child(m.reader, &it, .Group)
		if q != .Found {
			break
		}
		if value == at.value {
			index = count
		}
		count += 1
	}
	run^ = {parent = parent, key = at.key, value = at.value, index = index, count = count}
	return index if count > 1 else -1
}

// Whether keys `a` and `b` of the document read as one name.
@(private)
same_name :: #force_inline proc(m: ^Matcher, a, b: tape.Node_Index) -> bool {
	return m.doc.format.same_text(m.doc.src, m.doc.nodes[a], m.doc.src, m.doc.nodes[b])
}

// Whether keys `a` and `b` have the same element type name, folding ASCII case when `m.opts.fold` is set.
@(private)
same_type :: proc(m: ^Matcher, a, b: tape.Node_Index) -> bool {
	if !m.opts.fold {
		return same_name(m, a, b)
	}
	abuf, bbuf: [64]u8
	sa, aok := tape.node_text(m.doc, m.doc.nodes[a], abuf[:])
	sb, bok := tape.node_text(m.doc, m.doc.nodes[b], bbuf[:])
	if aok && bok {
		return fold_equal(sa, sb)
	}
	ra := tape.text_room(m.doc, m.doc.nodes[a])
	rb := tape.text_room(m.doc, m.doc.nodes[b])
	if err := resize(&m.scratch, ra + rb); err != nil {
		m.err = err
		return false
	}
	sa, _ = tape.node_text(m.doc, m.doc.nodes[a], m.scratch[:ra])
	sb, _ = tape.node_text(m.doc, m.doc.nodes[b], m.scratch[ra:ra + rb])
	return fold_equal(sa, sb)
}

// Whether key `k` names an element, not a run of text.
@(private)
is_element :: #force_inline proc(doc: ^tape.Document, k: tape.Node_Index) -> bool {
	return !markup.is_text_key(doc.nodes[k])
}

// The members of the container at `at`, as written.
@(private)
children_at :: #force_inline proc "contextless" (at: tape.Node_Index) -> tape.Children {
	return {container = at, next = at + 1}
}

// The next element of `it`, its parent, index and depth unset.
@(private)
next_element :: #force_inline proc(m: ^Matcher, it: ^tape.Children) -> (Frame, bool) {
	for {
		key, value, p := tape.next_child(m.reader, it, .Group)
		if p != .Found {
			return {}, false
		}
		if is_element(m.doc, key) {
			return {key = key, value = value}, true
		}
	}
}

// The node of the value of frame `f`'s parent, the root for a member of it.
@(private)
parent_node :: #force_inline proc(m: ^Matcher, f: Frame) -> tape.Node_Index {
	return m.frames[f.parent].value if f.parent >= 0 else tape.ROOT
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
		f, more := next_element(m, &lv.children)
		if !more {
			pop(&m.levels)
			continue
		}
		lv.count += 1
		f.parent, f.index = lv.frame, lv.count
		f.depth = 0 if lv.frame < 0 else m.frames[lv.frame].depth + 1
		resize(&m.frames, lv.top)
		push_frame(m, f) or_break
		frame = i32(len(m.frames) - 1)
		if m.doc.nodes[f.value].kind == .Object {
			if _, err := append(&m.levels, Level{children = children_at(f.value), frame = frame, top = len(m.frames)}); err != nil {
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
		it := children_at(parent_node(m, at))
		before := Frame{parent = at.parent, depth = at.depth}
		for g in next_element(m, &it) {
			if before.index + 1 == at.index {
				break
			}
			before = {key = g.key, value = g.value, parent = at.parent, index = before.index + 1, depth = at.depth}
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

@(private)
test :: proc(m: ^Matcher, t: Test, f: i32) -> bool {
	at := m.frames[f]
	switch t.kind {
	case .Type:
		buf: [64]u8
		return names_equal(m.opts.fold, node_string(m, m.doc.nodes[at.key], buf[:]), text(m, t.name))
	case .Attribute:
		return attribute(m, t, at)
	case .Is:
		return match_list(m, t.list, f, -1)
	case .Not:
		return !match_list(m, t.list, f, -1)
	case .Has:
		return has(m, t.list, f)
	case .Root:
		if at.parent >= 0 {
			return false
		}
		it := children_at(tape.ROOT)
		elements := 0
		for _ in next_element(m, &it) {
			elements += 1
		}
		return elements == 1
	case .Empty:
		return is_empty(m, m.doc.nodes[at.value])
	case .Nth:
		return nth(t.a, t.b, position(m, t, f))
	}
	return false
}

// Whether the element whose value is `v` holds no child element and no text.
@(private)
is_empty :: proc(m: ^Matcher, v: tape.Node) -> bool {
	#partial switch v.kind {
	case .Null:
		return true
	case .String, .Plain:
		if v.spelling & tape.SPELLING_DECODE == 0 {
			return v.n == 0
		}
		buf: [256]u8
		return len(node_string(m, v, buf[:])) == 0
	}
	return false
}

@(private)
text :: #force_inline proc(m: ^Matcher, r: Run) -> string {
	return string(m.sel.text[r.lo:][:r.n])
}

// The text of token `t` of the document: its span, or its decode into `buf`, or into the matcher's buffer when `buf` is
// short, which the next call may overwrite.
@(private)
node_string :: proc(m: ^Matcher, t: tape.Token, buf: []u8) -> string {
	s, ok := tape.node_text(m.doc, t, buf)
	if ok {
		return s
	}
	if err := resize(&m.scratch, tape.text_room(m.doc, t)); err != nil {
		m.err = err
		return ""
	}
	s, _ = tape.node_text(m.doc, t, m.scratch[:])
	return s
}

@(private)
names_equal :: #force_inline proc(fold_case: bool, a, b: string) -> bool {
	return fold_equal(a, b) if fold_case else a == b
}

// Whether the element at frame `at` has the attribute `t` names with a value its operator takes.
@(private)
attribute :: proc(m: ^Matcher, t: Test, at: Frame) -> bool {
	if m.opts.attribute == nil {
		return false
	}
	want := text(m, t.name)
	for fact in tape.facts_of(m.doc, at.value) {
		if fact.kind != .Attribute {
			continue
		}
		name, value := m.opts.attribute(m.doc, fact)
		name_buf: [64]u8
		if !names_equal(m.opts.fold, node_string(m, name, name_buf[:]), want) {
			continue
		}
		if t.op == .Exists {
			return true
		}
		value_buf: [256]u8
		return value_matches(t, node_string(m, value, value_buf[:]), text(m, t.value))
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
	it := children_at(parent_node(m, at))
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
		if t.of_type && !same_type(m, at.key, g.key) {
			continue
		}
		if t.list.n > 0 && !sibling_matches(m, t.list, {key = g.key, value = g.value, parent = at.parent, index = index, depth = at.depth}) {
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
			it := children_at(parent_node(m, at))
			index := u32(0)
			for g in next_element(m, &it) {
				index += 1
				if index <= at.index {
					continue
				}
				n := len(m.frames)
				push_frame(m, {key = g.key, value = g.value, parent = at.parent, index = index, depth = at.depth}) or_return
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
	if m.doc.nodes[m.frames[g].value].kind != .Object {
		return false
	}
	base, frames := len(m.levels), len(m.frames)
	if _, err := append(&m.levels, Level{children = children_at(m.frames[g].value), frame = g, top = frames}); err != nil {
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
