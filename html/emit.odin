package html

import "base:intrinsics"
import "base:runtime"
import core "../core"

// The tokens of a tree, in preorder, which a hook reads as it reads a walk's: the document's tokens are those of an
// XML text with the same markup. The document is an `Object`: of one member, the root element, or for a fragment of the
// nodes of its root. An element is a `Key` of its name, then its attributes as `Attribute` facts, then its value. An
// element with no child element has a `Plain` value of its text, empty for none. An element with one is an `Object`,
// then a `Key` of `#text` with no bytes of its own and a `Plain` for each run of text between its children that holds a
// character other than whitespace, and its child elements as members, then an `End`. Comments, processing instructions
// and the DOCTYPE are facts before the token they precede, by the comment position rule. A node the tree construction
// implied has a key with no bytes, and a text of pieces apart in the source, or one a comment splits, is a `Plain` whose
// pieces the document's state lists.

// The bits of an element or attribute key's `spelling` past core's bits 0 to 2: the form its text takes, whether the
// tree made the element otherwise than as the source spells it, the element's namespace, and the index the form reads.
// A key with `SPELLING_DECODE` clear is its span. `#text` is `SPELLING_SYNTHETIC` with form `.Span`.
@(private)
Key_Form :: enum u8 {
	Span, // the span as written
	Fold, // the span read as a name: ASCII upper case lowered, U+0000 and ill-formed UTF-8 as U+FFFD
	Tag, // `TAG_NAMES[index]`: an implied element's, with no bytes, or a renamed start tag's
	Foreign, // `FOREIGN_NAMES[index].name`, the span's mixed case restored
}

@(private)
KEY_FORM_SHIFT :: 3
@(private)
KEY_FROZEN :: u16(1 << 5)
@(private)
KEY_NS_SHIFT :: 6
@(private)
KEY_INDEX_SHIFT :: 8

// The bits of a text value's `spelling` past core's bits 0 to 2: the `Mode` `decode` reads it in, whether its pieces
// are in the document's state, and whether a node of it was foster parented.
@(private)
TEXT_MODE_SHIFT :: 3
@(private)
TEXT_PIECES :: u16(1 << 6)
@(private)
TEXT_FROZEN :: u16(1 << 7)

#assert(len(Tag) <= 256 && len(FOREIGN_NAMES) <= 256 && len(Mode) <= 8)

// The key's form, from its spelling.
@(private)
key_form :: #force_inline proc "contextless" (spelling: u16) -> Key_Form {
	return Key_Form(spelling >> KEY_FORM_SHIFT & 3)
}

// The flags of a span a name or a value may hold that `decode` changes, which a reader of a document passes to
// `decode` since the document keeps no span's own flags.
@(private)
DECODED :: Span_Flags{.Ref, .Nul, .Upper, .Cr, .Invalid}

// What a document keeps past its tokens, built by the write pass of a build: the byte past each element `Object`'s
// close, by its node, and the pieces of each text that is no one span, by the text's first byte. `open` holds the node
// of each `Object` the pass has open.
@(private)
Kept :: struct {
	ends:   [dynamic]End_Entry,
	texts:  [dynamic]Text_Entry,
	pieces: [dynamic]Span,
	open:   [dynamic]u32,
	oom:    bool,
}

@(private)
End_Entry :: struct {
	node: u32,
	end:  u64,
}

@(private)
Text_Entry :: struct {
	lo:    u64,
	first: u32,
	count: u32,
}

// The head of a document's state, which the three tables follow in order.
@(private)
State_Head :: struct {
	ends, texts, pieces, _: u32,
}

#assert(size_of(State_Head) == 16 && size_of(End_Entry) == 16 && size_of(Text_Entry) == 16 && size_of(Span) == 16)

// The tables of a document's state, empty for none.
@(private)
state_tables :: proc "contextless" (state: []u8) -> (ends: []End_Entry, texts: []Text_Entry, pieces: []Span) {
	if len(state) < size_of(State_Head) {
		return
	}
	head := (^State_Head)(raw_data(state))
	p := uintptr(raw_data(state)) + size_of(State_Head)
	ends = ([^]End_Entry)(rawptr(p))[:head.ends]
	p += uintptr(head.ends) * size_of(End_Entry)
	texts = ([^]Text_Entry)(rawptr(p))[:head.texts]
	p += uintptr(head.texts) * size_of(Text_Entry)
	pieces = ([^]Span)(rawptr(p))[:head.pieces]
	return
}

// Seals `k` into one block from `allocator`, its ends sorted by node and its texts by first byte, one per byte, which
// `doc.state` takes. Returns false when memory runs out.
@(private)
keep_state :: proc(doc: ^core.Document, k: ^Kept, allocator: runtime.Allocator) -> bool {
	if k.oom {
		return false
	}
	if len(k.ends) == 0 && len(k.texts) == 0 {
		return true
	}
	sort_entries(k.ends[:], proc(a, b: End_Entry) -> bool {return a.node < b.node})
	sort_entries(k.texts[:], proc(a, b: Text_Entry) -> bool {return a.lo < b.lo})
	// Two texts start at one byte only when one is the other's copy, and the first stands for both.
	n := 0
	for e, i in k.texts {
		if i == 0 || e.lo != k.texts[n - 1].lo {
			k.texts[n] = e
			n += 1
		}
	}
	resize(&k.texts, n)
	size := size_of(State_Head) + len(k.ends) * size_of(End_Entry) + len(k.texts) * size_of(Text_Entry) + len(k.pieces) * size_of(Span)
	block, err := runtime.mem_alloc_bytes(size, 16, allocator)
	if err != nil {
		return false
	}
	(^State_Head)(raw_data(block))^ = {ends = u32(len(k.ends)), texts = u32(len(k.texts)), pieces = u32(len(k.pieces))}
	ends, texts, pieces := state_tables(block)
	copy(ends, k.ends[:])
	copy(texts, k.texts[:])
	copy(pieces, k.pieces[:])
	doc.state = block
	return true
}

@(private)
kept_destroy :: proc(k: ^Kept) {
	delete(k.ends)
	delete(k.texts)
	delete(k.pieces)
	delete(k.open)
}

// A stable insertion sort, since the entries come nearly in order: the ends of a subtree's elements in reverse, and
// the texts in source order but for those the tree moved.
@(private)
sort_entries :: proc(xs: []$T, less: proc(a, b: T) -> bool) {
	for i in 1 ..< len(xs) {
		x := xs[i]
		j := i
		for j > 0 && less(x, xs[j - 1]) {
			xs[j] = xs[j - 1]
			j -= 1
		}
		xs[j] = x
	}
}

// The walk over a tree. `node` is the document node the next value or key takes, counted as the builder counts.
@(private)
Emitter :: struct($H: typeid) {
	t:       ^Html_Tree,
	h:       ^H,
	regs:    core.Hook_Regs,
	spec:    Spec,
	node:    u32,
	keep:    ^Kept,
	// The pieces of the text `text_value` reads, its scratch.
	run:     [dynamic]Span,
	stopped: bool,
	// The byte past the token the hook stopped on.
	hi:      u64,
	fault:   Maybe(core.Fault),
}

// Gives the token to the hook. Returns the hook's action, `.Stop` once the walk is over. `element` is the element node
// whose tokens a `Skip` on this one hides, 0 for one the walk reads on past, which a walk with a cursor holds.
@(private)
give :: proc(e: ^Emitter($H), $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), kind: core.Kind, role: core.Role, lo: u64, n: u64, spelling: u16 = 0, element: u32 = 0) -> core.Action {
	when intrinsics.type_is_specialization_of(H, core.Holding) {
		e.h.skip_at = u64(element)
	}
	if e.stopped {
		return .Stop
	}
	if n > u64(max(u32)) {
		e.fault = core.Fault{at = lo, rules = &RULES, kind = .Too_Wide}
		e.stopped = true
		return .Stop
	}
	a: core.Action
	e.regs, a = on(e.h, e.regs, core.Token{lo, u32(n), kind, role, spelling})
	if role <= .Key && kind != .End {
		e.node += 1
	}
	if a == .Stop {
		e.stopped, e.hi = true, lo + n
	}
	return a
}

// Marks the end of element `n`'s tokens among those a walk with a cursor holds.
@(private)
element_end :: proc(e: ^Emitter($H), n: u32) {
	when intrinsics.type_is_specialization_of(H, core.Holding) {
		if e.h.held != nil && !core.hold(e.h, core.Held_Token{at = u64(n), close = true}) {
			e.stopped = true
		}
	}
}

// Gives the tokens of the tree: the document, or a fragment's nodes. Every element is reached from its parent and its
// previous sibling, so the walk keeps no stack of its own.
@(private)
emit_tree :: proc(e: ^Emitter($H), $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) {
	t := e.t
	top := DOCUMENT
	if e.spec == .Fragment {
		top = t.nodes[DOCUMENT].first
	}
	parent := top
	child := t.nodes[top].first
	prev, opening := false, true
	for !e.stopped {
		next, shut := content(e, on, parent, child, prev, opening, top)
		if e.stopped {
			return
		}
		if next == 0 {
			if !shut {
				lo := u64(len(t.src)) if parent == top else t.nodes[parent].end
				if give(e, on, .End, .Value, lo, 0) == .Stop {
					return
				}
				element_end(e, parent)
				if e.keep != nil && parent != top {
					if _, err := append(&e.keep.ends, End_Entry{node = pop(&e.keep.open), end = lo}); err != nil {
						e.keep.oom = true
					}
				}
			}
			if parent == top {
				return
			}
			child, parent = t.nodes[parent].next, t.nodes[parent].parent
			prev, opening = true, false
			continue
		}
		if !element(e, on, next) {
			child, prev, opening = t.nodes[next].next, true, false
			continue
		}
		parent, child = next, t.nodes[next].first
		prev, opening = false, true
	}
}

// Gives the run of `parent`'s children from `from` to its next element child, which it returns, 0 at the end of the
// children: their comments, instructions and DOCTYPE as facts, then the parent's `Object` when `opening`, then the
// run's text as a `#text` member when it holds a character other than whitespace. `prev` says a child element ends
// before the run. `shut` says the hook skipped the `Object`, so the parent has no more tokens.
@(private)
content :: proc(e: ^Emitter($H), $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), parent, from: u32, prev, opening: bool, top: u32) -> (next: u32, shut: bool) {
	t := e.t
	nodes := t.nodes[:]
	end := from
	last_text := u32(0)
	for end != 0 && nodes[end].kind != .Element {
		if nodes[end].kind == .Text && has_char(t, end) {
			last_text = end
		}
		end = nodes[end].next
	}
	// A comment is the parent's foot when only whitespace follows it before the end tag, and inline when a child
	// element ended on its line with only whitespace and comments between.
	seen := last_text == 0
	text_seen := false
	next_line := !prev
	for k := from; k != end; k = nodes[k].next {
		n := &nodes[k]
		switch n.kind {
		case .Text:
			if k == last_text {
				seen = true
			}
			if !text_seen && has_char(t, k) {
				text_seen = true
			}
		case .Comment:
			foot := end == 0 && seen && !opening
			role := core.Role.Comment_Foot if foot else .Comment
			if prev && !text_seen {
				if !next_line && newline_before(t.src, n.lo) {
					next_line = true
				}
				if !next_line {
					role = .Comment_Inline
				}
			}
			if give(e, on, .Plain, role, n.lo, n.hi - n.lo, markers(n.lo, n.hi, n.name.lo, n.name.lo + u64(n.name.n))) == .Stop {
				return 0, true
			}
			if has_newline(t.src[n.lo:n.hi]) {
				next_line = true
			}
		case .Instruction:
			data := t.pieces[n.a].span
			body_end := data.lo + u64(data.n) if data.n > 0 else n.name.lo + u64(n.name.n)
			if give(e, on, .Plain, .Instruction, n.lo, n.hi - n.lo, markers(n.lo, n.hi, n.name.lo, body_end)) == .Stop {
				return 0, true
			}
		case .Doctype:
			if give(e, on, .Plain, .Doctype, n.lo, n.hi - n.lo) == .Stop {
				return 0, true
			}
		case .Document, .Element:
		}
	}
	if opening && (end != 0 || parent == top) {
		lo, n: u64
		if parent == top {
			lo = nodes[end].lo if end != 0 && e.spec == .Document else 0
		} else {
			p := &nodes[parent]
			lo, n = p.lo, p.hi - p.lo
		}
		at := e.node
		a := give(e, on, .Object, .Value, lo, n, 0, parent if parent != top else 0)
		if a == .Stop {
			return 0, true
		}
		if a == .Skip && parent != top {
			return 0, true
		}
		if e.keep != nil && parent != top {
			if _, err := append(&e.keep.open, at); err != nil {
				e.keep.oom = true
			}
		}
	}
	if last_text != 0 {
		if give(e, on, .String, .Key, nodes[last_text].lo, 0, core.SPELLING_SYNTHETIC) == .Stop {
			return 0, true
		}
		if !text_value(e, on, from, end, 0) {
			return 0, true
		}
	}
	return end, false
}

// Gives element `n`'s key and attributes, and its value when it has no child element. Returns whether its children
// are to be read, which they are not for such an element or one the hook skipped.
@(private)
element :: proc(e: ^Emitter($H), $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), n: u32) -> bool {
	t := e.t
	node := &t.nodes[n]
	key := key_of(t, node)
	if a := give(e, on, .String, .Key, key.lo, u64(key.n), key.spelling, n); a != .Next {
		return false
	}
	for a in t.attrs[node.a:][:node.b] {
		lo, hi, spelling := attribute_fact(t.src, a)
		if give(e, on, .Plain, .Attribute, lo, hi - lo, spelling) == .Stop {
			return false
		}
	}
	parent := false
	for c := node.first; c != 0; c = t.nodes[c].next {
		if t.nodes[c].kind == .Element {
			parent = true
			break
		}
	}
	if parent {
		return true
	}
	for c := node.first; c != 0; c = t.nodes[c].next {
		child := &t.nodes[c]
		#partial switch child.kind {
		case .Comment:
			if give(e, on, .Plain, .Comment, child.lo, child.hi - child.lo, markers(child.lo, child.hi, child.name.lo, child.name.lo + u64(child.name.n))) == .Stop {
				return false
			}
		case .Instruction:
			data := t.pieces[child.a].span
			body_end := data.lo + u64(data.n) if data.n > 0 else child.name.lo + u64(child.name.n)
			if give(e, on, .Plain, .Instruction, child.lo, child.hi - child.lo, markers(child.lo, child.hi, child.name.lo, body_end)) == .Stop {
				return false
			}
		}
	}
	if text_value(e, on, node.first, 0, node.lo if .Implied in node.flags else node.hi) {
		element_end(e, n)
	}
	return false
}

// Gives the `Plain` of the text nodes among the siblings from `from` to `end`, an empty one at `empty_at` when they are
// none. Its span runs from the first byte of its pieces to past the last, and pieces apart, or in another order, are
// listed in the state by that first byte. Returns false when the walk is over.
@(private)
text_value :: proc(e: ^Emitter($H), $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), from, end: u32, empty_at: u64) -> bool {
	t := e.t
	clear(&e.run)
	lo, hi := empty_at, empty_at
	decoded := false
	frozen := false
	for k := from; k != end; k = t.nodes[k].next {
		n := &t.nodes[k]
		if n.kind != .Text {
			continue
		}
		frozen ||= .Moved in n.flags
		for p := n.a;; p = t.pieces[p].next {
			s := t.pieces[p].span
			if len(e.run) == 0 {
				lo, hi = s.lo, s.lo
			}
			lo, hi = min(lo, s.lo), max(hi, s.lo + u64(s.n))
			decoded ||= s.flags & DECODED != {}
			if _, err := append(&e.run, s); err != nil {
				e.fault = core.Fault{rules = &RULES, kind = .No_Memory}
				e.stopped = true
				return false
			}
			if p == n.b {
				break
			}
		}
	}
	spelling := u16(0)
	if len(e.run) > 1 {
		spelling = core.SPELLING_DECODE | core.SPELLING_LAX | TEXT_PIECES
		if k := e.keep; k != nil {
			_, err := append(&k.texts, Text_Entry{lo = lo, first = u32(len(k.pieces)), count = u32(len(e.run))})
			_, perr := append(&k.pieces, ..e.run[:])
			k.oom ||= err != nil || perr != nil
		}
	} else if decoded {
		spelling = core.SPELLING_DECODE | core.SPELLING_LAX
	}
	if spelling != 0 {
		spelling |= u16(e.run[0].mode) << TEXT_MODE_SHIFT
	}
	if frozen {
		spelling |= TEXT_FROZEN
	}
	return give(e, on, .Plain, .Value, lo, hi - lo, spelling) != .Stop
}

// The key of element `n`: its name's span, read as the form its spelling says, or no bytes for an implied element.
@(private)
key_of :: proc(t: ^Html_Tree, n: ^Tree_Node) -> core.Token {
	spelling := u16(n.ns) << KEY_NS_SHIFT
	if n.flags & {.Implied, .Cloned, .Moved} != {} {
		spelling |= KEY_FROZEN
	}
	if n.name.n == 0 {
		return {lo = n.lo, kind = .String, role = .Key, spelling = spelling | core.SPELLING_SYNTHETIC | u16(Key_Form.Tag) << KEY_FORM_SHIFT | u16(n.tag) << KEY_INDEX_SHIFT}
	}
	key := core.Token{lo = n.name.lo, n = n.name.n, kind = .String, role = .Key}
	if n.ns == .Svg {
		i := foreign_of(raw_data(t.src)[n.name.lo:], n.name.n)
		if n.name.flags & {.Nul, .Invalid} == {} && .Svg_Element in FOREIGN_NAMES[i].kinds {
			key.spelling = spelling | core.SPELLING_DECODE | u16(Key_Form.Foreign) << KEY_FORM_SHIFT | u16(i) << KEY_INDEX_SHIFT
			return key
		}
	}
	// A start tag the tree renames, `image` read as `img`, reads as its tag.
	if n.tag != .Other && int(n.name.n) != len(TAG_NAMES[n.tag]) {
		key.spelling = spelling | core.SPELLING_DECODE | u16(Key_Form.Tag) << KEY_FORM_SHIFT | u16(n.tag) << KEY_INDEX_SHIFT
		return key
	}
	key.spelling = spelling | name_spelling(n.name.flags)
	return key
}

// The spelling of a name key whose span holds `flags`: its span, or read as a name, which may grow when it holds U+0000
// or ill-formed UTF-8.
@(private)
name_spelling :: #force_inline proc "contextless" (flags: Span_Flags) -> u16 {
	if flags & {.Upper, .Nul, .Invalid} == {} {
		return 0
	}
	s := core.SPELLING_DECODE | u16(Key_Form.Fold) << KEY_FORM_SHIFT
	if flags & {.Nul, .Invalid} != {} {
		s |= core.SPELLING_LAX
	}
	return s
}

// The span and spelling of attribute `a`'s fact: from its name through its value, the closing quote included, leading
// to the value, or the name alone for a valueless attribute, which leads with its whole span.
@(private)
attribute_fact :: proc "contextless" (src: []u8, a: Attribute) -> (lo, hi: u64, spelling: u16) {
	lo = a.name.lo
	if a.value.lo == 0 {
		hi = lo + u64(a.name.n)
		return lo, hi, core.attribute_spelling(int(hi - lo), false)
	}
	quoted := src[a.value.lo - 1] == '"' || src[a.value.lo - 1] == '\''
	hi = a.value.lo + u64(a.value.n) + (1 if quoted else 0)
	return lo, hi, core.attribute_spelling(int(a.value.lo - lo), quoted)
}

// The lead and tail markers of a comment or an instruction token from `lo` to `hi` whose body runs from `body_lo` to
// `body_hi`, each saturated at 255.
@(private)
markers :: proc "contextless" (lo, hi, body_lo, body_hi: u64) -> u16 {
	if body_lo < lo || body_hi > hi || body_lo > body_hi {
		return 0
	}
	return core.comment_spelling(u8(min(body_lo - lo, 255)), u8(min(hi - body_hi, 255)))
}

// Whether text node `n` holds a character other than whitespace.
@(private)
has_char :: proc(t: ^Html_Tree, n: u32) -> bool {
	node := &t.nodes[n]
	for p := node.a;; p = t.pieces[p].next {
		s := t.pieces[p].span
		text := t.src[s.lo:s.lo + u64(s.n)] if s.flags & DECODED == {} else transmute([]u8)decoded(t, s, 0)
		for c in text {
			if !is_space(c) {
				return true
			}
		}
		if p == node.b {
			break
		}
	}
	return false
}

// Whether only whitespace with a line end in it stands before byte `lo`, back to the last other byte.
@(private)
newline_before :: proc "contextless" (src: []u8, lo: u64) -> bool {
	for q := lo; q > 0 && is_space(src[q - 1]); q -= 1 {
		if src[q - 1] == '\n' || src[q - 1] == '\r' {
			return true
		}
	}
	return false
}

@(private)
has_newline :: proc "contextless" (b: []u8) -> bool {
	for c in b {
		if c == '\n' || c == '\r' {
			return true
		}
	}
	return false
}
