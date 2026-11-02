package core

import "base:runtime"
import "core:bytes"
import "core:slice"

// A commit, composed per container. A container is its members and the gaps between them, and the root is the
// one member of the text. A junction is the bytes between two surviving neighbours: the gaps, the removed members and
// the new members between them. An edited junction becomes one chunk, written once, so chunks overlap only when a set
// covers a nested edit. A fact goes with its node: a kept inline stays on its value's line, and a kept head or foot
// starts a line of its own.

NO_BYTE :: max(u64)

// The source bytes a set replaces, whose contents no container walk emits.
@(private)
Written_Span :: struct {
	lo, hi: u64,
}

// The order of chunks at one byte, which only a member of no bytes makes possible: what comes before a line, what comes
// before a member, a set, what comes after a member, what comes after a line.
RANK_LINE_HEAD :: u8(0)
@(private)
RANK_HEAD :: u8(1)
@(private)
RANK_SET :: u8(2)
@(private)
RANK_TAIL :: u8(3)
RANK_LINE_TAIL :: u8(4)

// A member as a commit reads it: its value's node, its first byte, key included, and one past its value.
Member :: struct {
	node:   Node_Index,
	lo, hi: u64,
}

@(private)
Fact_Key :: struct {
	key:  u64,
	edit: int,
}

@(private)
Item_Action :: enum u8 {
	Keep,
	Cut,
	Write,
}

// A comment in a junction, or the place of a new inline when `lo == hi`. `line` says it ends at its line's end.
@(private)
Item :: struct {
	lo, hi: u64,
	edit:   int,
	action: Item_Action,
	role:   Role,
	line:   bool,
}

// One commit's composing state. `in_line` says the last bytes written are a line comment with no line end after them,
// and `value_line` that no line end follows the last value written. A format with its own junctions composes on it.
Compose :: struct {
	doc:          ^Document,
	list:         ^Edit_List,
	style:        Comment_Spelling,
	comment_byte: u8,
	text:         ^[dynamic]u8,
	chunks:       ^[dynamic]Chunk,
	dropped:      ^int,
	keys:         []Fact_Key,
	items:        [dynamic]Item,
	members:      [dynamic]Member,
	removed:      [dynamic]bool,
	dirty:        [dynamic]bool,
	emptied:      bool,
	in_line:      bool,
	value_line:   bool,
}

// Returns the fact edit of `node` and `role`, or -1.
fact_edit_of :: proc(cx: ^Compose, node: Node_Index, role: Role) -> int {
	i, found := slice.binary_search_by(cx.keys, u64(node) << 8 | u64(role), proc(k: Fact_Key, want: u64) -> slice.Ordering {
		return slice.cmp(k.key, want)
	})
	return cx.keys[i].edit if found else -1
}

// Returns whether `node` holds a fact of `role`.
@(private)
holds_fact :: proc(doc: ^Document, node: Node_Index, role: Role) -> bool {
	for f in all_facts(doc, node) {
		if f.role == role {
			return true
		}
	}
	return false
}

// Returns what a source fact becomes: the output cannot hold it, an edit names it, or it stays. A set writes the first
// fact it names and cuts the others.
@(private)
fact_action :: proc(cx: ^Compose, f: Fact) -> (action: Item_Action, edit: int) {
	doc := cx.doc
	slot := fact_slot(doc, f.node, f.role, cx.style, cx.emptied)
	edit = fact_edit_of(cx, f.node, f.role)
	if edit < 0 {
		return .Keep if slot else .Cut, -1
	}
	if !slot || cx.list.edits[edit].op == .Remove_Fact {
		return .Cut, edit
	}
	for g in all_facts(doc, f.node) {
		if g.role == f.role {
			return .Write if g.lo == f.lo else .Cut, edit
		}
	}
	return .Cut, edit
}

// Returns the set of `node` and `role` that writes a new fact: the node holds none of that role.
new_fact :: proc(cx: ^Compose, node: Node_Index, role: Role) -> int {
	edit := fact_edit_of(cx, node, role)
	if edit < 0 || cx.list.edits[edit].op != .Set_Fact {
		return -1
	}
	if !fact_slot(cx.doc, node, role, cx.style, cx.emptied) || holds_fact(cx.doc, node, role) {
		return -1
	}
	return edit
}

// Adds `node`'s facts in `lo` through `hi` to the junction's items.
add_items :: proc(cx: ^Compose, node: Node_Index, lo, hi: u64) -> bool {
	for f in all_facts(cx.doc, node) {
		if f.lo < lo || f.lo >= hi {
			continue
		}
		action, edit := fact_action(cx, f)
		push(&cx.items, Item{lo = f.lo, hi = f.lo + u64(f.n), edit = edit, action = action, role = f.role, line = f.spelling >> 8 == 0}) or_return
	}
	return true
}

// Sorts the junction's items by byte.
sort_items :: proc(cx: ^Compose) {
	slice.sort_by(cx.items[:], proc(a, b: Item) -> bool { return a.lo < b.lo })
}

// Writes `b`, ending a line comment first when `b` does not.
put_text :: proc(cx: ^Compose, b: []u8) -> bool {
	if len(b) == 0 {
		return true
	}
	if cx.in_line && line_end_len(b, 0) == 0 {
		push(cx.text, '\n') or_return
		cx.value_line = false
	}
	cx.in_line = false
	push_all(cx.text, b) or_return
	if body_line_end(b) {
		cx.value_line = false
	}
	return true
}

// Writes a fact edit's body over `lo` through `hi`, or at `hi` when the two are equal.
write_fact :: proc(cx: ^Compose, e: Edit, lo, hi: u64) -> bool {
	doc := cx.doc
	taken := 1 if hi > lo else 0
	line := fact_line(doc, e, hi, taken, false)
	if !fact_body_held(cx.style, e.text, line) {
		cx.dropped^ += 1
		return true
	}
	indent: []u8
	lead := false
	if cx.style == .Byte {
		lead = cx.value_line
	} else if e.role != .Comment_Inline {
		indent, lead = line_shape(doc, lo)
		lead = lead || cx.value_line
	}
	if cx.in_line {
		push(cx.text, '\n') or_return
		cx.in_line = false
	}
	fresh := taken == 0 && e.role != .Comment_Inline
	fact_write(doc, cx.style, cx.comment_byte, e.role, e.text, line, indent, lead, fresh, cx.text) or_return
	cx.in_line = line && !fresh
	if lead || fresh {
		cx.value_line = false
	}
	return true
}

// Writes `lo` through `hi` of the source without byte `skip`, applying the items there. `fresh` says the range holds
// only heads and feet, which must not read as the last value's inline.
emit_range :: proc(cx: ^Compose, lo, hi, skip: u64, fresh: bool) -> bool {
	src := cx.doc.src
	copy_gap :: proc(cx: ^Compose, src: []u8, lo, hi, skip: u64) -> bool {
		if skip >= lo && skip < hi {
			put_text(cx, src[lo:skip]) or_return
			return put_text(cx, src[skip + 1:hi])
		}
		return put_text(cx, src[lo:hi])
	}
	at := lo
	for it in cx.items {
		zero := it.hi == it.lo
		if zero && (fresh || it.lo < lo || it.lo > hi) || !zero && (it.lo < lo || it.lo >= hi) {
			continue
		}
		copy_gap(cx, src, at, it.lo, skip) or_return
		at = it.hi
		switch it.action {
		case .Cut:
		case .Write:
			write_fact(cx, cx.list.edits[it.edit], it.lo, it.hi) or_return
		case .Keep:
			if fresh && cx.value_line {
				indent, _ := line_shape(cx.doc, it.lo)
				put_text(cx, transmute([]u8)string("\n")) or_return
				push_all(cx.text, indent) or_return
			}
			put_text(cx, src[it.lo:it.hi]) or_return
			cx.in_line = it.line
		}
	}
	return copy_gap(cx, src, at, hi, skip)
}

// Returns the first separator in `lo` through `hi` that lies outside the junction's comments.
@(private)
gap_comma :: proc(cx: ^Compose, lo, hi: u64, sep: u8) -> u64 {
	src := cx.doc.src
	at := lo
	for it in cx.items {
		if it.lo < lo || it.lo >= hi {
			continue
		}
		if k := bytes.index_byte(src[at:it.lo], sep); k >= 0 {
			return at + u64(k)
		}
		at = it.hi
	}
	if at < hi {
		if k := bytes.index_byte(src[at:hi], sep); k >= 0 {
			return at + u64(k)
		}
	}
	return NO_BYTE
}

// Returns the byte of member `v` where its comments start.
head_lo :: proc(doc: ^Document, m: Member) -> u64 {
	lo := m.lo
	for f in all_facts(doc, m.node) {
		if f.lo < lo {
			lo = f.lo
		}
	}
	return lo
}

// Returns one past member `m`'s value and the comments after it.
@(private)
tail_hi :: proc(doc: ^Document, m: Member) -> u64 {
	hi := m.hi
	for f in all_facts(doc, m.node) {
		if f.lo >= hi {
			hi = f.lo + u64(f.n)
		}
	}
	return hi
}

// Writes an insert's member, its key first.
write_member :: proc(cx: ^Compose, e: Edit) -> bool {
	edit := cx.doc.spelling.edit
	if cx.in_line {
		put_text(cx, transmute([]u8)string("\n")) or_return
	}
	if e.role == .Key {
		if edit.key_text == nil || !edit.key_text(cx.doc, e.key, cx.text) {
			return false
		}
		push_all(cx.text, transmute([]u8)edit.key_sep) or_return
	}
	push_all(cx.text, e.text) or_return
	cx.value_line = true
	return true
}

// Composes the junction between survivors `l` and `r`, `-1` for the open and the member count for the close, with the
// edits `inserts` writes between them.
@(private)
compose_junction :: proc(cx: ^Compose, c: Node_Index, open, close: u64, l, r: int, inserts: []Edit) -> bool {
	doc := cx.doc
	lo, hi := open, close
	members := cx.members[:]
	n := len(members)
	has_left, has_right := l >= 0, r < n
	run := r - l > 1
	if has_left {
		lo = members[l].hi
	}
	if has_right {
		hi = members[r].lo
	}
	clear(&cx.items)
	if has_left {
		add_items(cx, members[l].node, lo, hi) or_return
	}
	if has_right {
		add_items(cx, members[r].node, lo, hi) or_return
	}
	if c != NO_NODE {
		add_items(cx, c, lo, hi) or_return
	}
	sort_items(cx)

	following := len(inserts) > 0 || has_right
	l_end := lo
	for it in cx.items {
		if it.role == .Comment_Inline {
			l_end = max(l_end, it.hi)
		}
	}
	first_r := hi
	for it in cx.items {
		if it.role != .Comment_Inline {
			first_r = it.lo
			break
		}
	}
	new_inline := -1
	inline_at := lo
	if has_left {
		new_inline = new_fact(cx, members[l].node, .Comment_Inline)
		if new_inline >= 0 {
			if after, comma := comma_after(doc.src, lo); comma && following {
				inline_at = after
				l_end = max(l_end, after)
			}
		}
	}
	a_end, b_lo: u64
	switch {
	case !run && has_right:
		a_end, b_lo = first_r, first_r
	case !run:
		a_end = l_end if has_left else first_r
		b_lo = a_end
	case has_right:
		a_end, b_lo = head_lo(doc, members[l + 1]), first_r
	case has_left:
		a_end, b_lo = l_end, tail_hi(doc, members[r - 1])
	case:
		a_end, b_lo = lo, first_r
	}
	if new_inline >= 0 {
		push(&cx.items, Item{lo = inline_at, hi = inline_at, edit = new_inline, action = .Write}) or_return
		sort_items(cx)
	}

	sep_text := transmute([]u8)doc.spelling.edit.member_sep(doc)
	ca, cz := NO_BYTE, NO_BYTE
	if c != NO_NODE {
		ca = gap_comma(cx, lo, a_end, sep_text[0])
		cz = gap_comma(cx, b_lo, hi, sep_text[0])
	}
	drop_a, drop_z := NO_BYTE, NO_BYTE
	joined := false
	if ca != NO_BYTE {
		if following {
			joined = true
		} else {
			drop_a = ca
		}
	}
	if cz != NO_BYTE && len(inserts) == 0 && (joined || !has_left) {
		drop_z = cz
	}

	from := len(cx.text)
	cx.in_line, cx.value_line = false, has_left
	if has_left && following && !joined && (len(inserts) > 0 || cz == NO_BYTE) {
		put_text(cx, sep_text) or_return
		cx.value_line = true
	}
	emit_range(cx, lo, a_end, drop_a, false) or_return
	for e, i in inserts {
		if i > 0 {
			put_text(cx, sep_text) or_return
		}
		write_member(cx, e) or_return
	}
	if len(inserts) > 0 && has_right && cz == NO_BYTE {
		put_text(cx, sep_text) or_return
	}
	emit_range(cx, b_lo, hi, drop_z, true) or_return
	owner := members[r].node if has_right else (c if c != NO_NODE else members[0].node)
	role := Role.Comment if has_right else .Comment_Foot
	// A new root foot goes at the text's end, which the text's own junction writes.
	if edit := new_fact(cx, owner, role); edit >= 0 && (has_right || c != ROOT) {
		write_fact(cx, cx.list.edits[edit], hi, hi) or_return
	}
	if cx.in_line && hi < u64(len(doc.src)) && line_end_len(doc.src, hi) == hi {
		push(cx.text, '\n') or_return
	}
	cx.in_line = false
	return emit_chunk(cx, lo, hi, from, RANK_HEAD if has_right || !has_left else RANK_TAIL)
}

// Makes the text written from `from` the chunk that replaces `lo` through `hi`.
emit_chunk :: proc(cx: ^Compose, lo, hi: u64, from: int, rank: u8) -> bool {
	_, ok := push(cx.chunks, Chunk{lo = lo, hi = hi, from = from, to = len(cx.text), rank = rank})
	return ok
}

// Returns the member position `lo` lies before, which names the gap it is in.
@(private)
gap_of :: proc(members: []Member, lo: u64) -> int {
	i := 0
	for i < len(members) && members[i].hi <= lo {
		i += 1
	}
	return i
}

// Writes a fact that lies inside its member, between the key and the value, as a chunk of its own.
member_fact :: proc(cx: ^Compose, f: Fact) -> bool {
	action, edit := fact_action(cx, f)
	from := len(cx.text)
	cx.in_line, cx.value_line = false, false
	if action == .Write {
		write_fact(cx, cx.list.edits[edit], f.lo, f.lo + u64(f.n)) or_return
	}
	cx.in_line = false
	_, ok := push(cx.chunks, Chunk{lo = f.lo, hi = f.lo + u64(f.n), from = from, to = len(cx.text), remove = action == .Cut, fact = action == .Cut})
	return ok
}

// Composes one edited container: `c` is `NO_NODE` for the text around the root.
@(private)
compose_container :: proc(cx: ^Compose, c: Node_Index, group: []Target, allocator: runtime.Allocator) -> (err: Document_Error, ok: bool) {
	err = {kind = .No_Memory}
	doc := cx.doc
	clear(&cx.members)
	lo, hi := u64(0), u64(len(doc.src))
	lines := c == ROOT && flat_doc(doc)
	if c == NO_NODE {
		at := key_start(doc.nodes[ROOT])
		push(&cx.members, Member{node = ROOT, lo = at, hi = at + u64(len(span(doc, ROOT)))}) or_return
	} else {
		lo, hi = interior(doc, c)
		if lines {
			doc.spelling.edit.root_head(cx, lo) or_return
		}
		it := children(doc, c)
		for {
			v, more := child_next(&it)
			if !more {
				break
			}
			at := value_lo(doc, c, v)
			push(&cx.members, Member{node = v, lo = at, hi = key_start(doc.nodes[v]) + u64(len(span(doc, v)))}) or_return
		}
	}
	members := cx.members[:]
	n := len(members)
	resize(&cx.removed, n)
	resize(&cx.dirty, n + 1)
	slice.zero(cx.removed[:])
	slice.zero(cx.dirty[:])
	position :: proc(members: []Member, node: Node_Index) -> int {
		i, found := slice.binary_search_by(members, node, proc(m: Member, n: Node_Index) -> slice.Ordering {
			return slice.cmp(m.node, n)
		})
		return i if found else -1
	}
	inserts, _ := make([dynamic]Edit, allocator)
	defer delete(inserts)
	for t in group {
		e := cx.list.edits[t.edit]
		switch e.op {
		case .Insert:
			cx.dirty[e.at] = true
			push(&inserts, e) or_return
		case .Remove:
			p := position(members, e.node)
			if p < 0 {
				return {kind = .Bad_Index}, false
			}
			if cx.removed[p] {
				return {kind = .Conflicting_Edits, at = members[p].lo}, false
			}
			cx.removed[p] = true
		case .Set:
		case .Set_Fact, .Remove_Fact:
			if e.role == .Comment_Foot {
				cx.dirty[n] = true
				if c != NO_NODE {
					for f in all_facts(doc, c) {
						if f.role == .Comment_Foot && f.lo >= lo && f.lo < hi {
							cx.dirty[gap_of(members, f.lo)] = true
						}
					}
				}
				continue
			}
			if lines && e.node == ROOT {
				continue
			}
			p := position(members, e.node)
			if p < 0 {
				return {kind = .Bad_Index}, false
			}
			if e.role == .Comment_Inline {
				cx.dirty[p + 1] = true
				continue
			}
			cx.dirty[p] = true
			for f in all_facts(doc, e.node) {
				if f.role == .Comment && f.lo >= members[p].lo && f.lo < members[p].hi {
					member_fact(cx, f) or_return
				}
			}
		}
	}
	l, k := -1, 0
	for r in 0 ..= n {
		if r < n && cx.removed[r] {
			continue
		}
		edited := r - l > 1
		for i in l + 1 ..= r {
			edited = edited || cx.dirty[i]
		}
		j := k
		for j < len(inserts) && int(inserts[j].at) <= r {
			j += 1
		}
		if edited {
			if lines {
				doc.spelling.edit.root_junction(cx, lo, hi, l, r, inserts[k:j]) or_return
			} else {
				compose_junction(cx, c, lo, hi, l, r, inserts[k:j]) or_return
			}
		}
		k = j
		l = r
	}
	return {}, true
}

// Builds a tree's chunks: every set's, then each edited container's junctions, then a chunk for each source fact the
// output cannot hold.
@(private)
compose_tree :: proc(doc: ^Document, list: ^Edit_List, style: Comment_Spelling, comment_byte: u8, text: ^[dynamic]u8, chunks: ^[dynamic]Chunk, dropped: ^int, allocator: runtime.Allocator) -> (err: Document_Error, ok: bool) {
	err = {kind = .No_Memory}
	emptied := doc.spelling.edit != nil && doc.spelling.edit.emptied != nil && doc.spelling.edit.emptied(doc, list)
	targets, _ := make([dynamic]Target, allocator)
	defer delete(targets)
	groups, _ := make([dynamic]Target, allocator)
	defer delete(groups)
	keys, _ := make([dynamic]Fact_Key, allocator)
	defer delete(keys)
	spans, _ := make([dynamic]Written_Span, allocator)
	defer delete(spans)
	for e, i in list.edits {
		switch e.op {
		case .Insert:
			push(&groups, Target{node = e.node, edit = i, at = e.at}) or_return
		case .Remove:
			push(&targets, Target{node = e.node, edit = i}) or_return
		case .Set:
			from := len(text^)
			if e.role == .Key {
				if doc.spelling.edit.key_text == nil || !doc.spelling.edit.key_text(doc, e.text, text) {
					return {kind = .No_Memory}, false
				}
			} else {
				push_all(text, e.text) or_return
			}
			at := key_start(doc.nodes[e.node])
			end := at + u64(len(span(doc, e.node)))
			push(chunks, Chunk{lo = at, hi = end, from = from, to = len(text^), rank = RANK_SET}) or_return
			push(&spans, Written_Span{lo = at, hi = end}) or_return
		case .Set_Fact, .Remove_Fact:
			push(&keys, Fact_Key{key = u64(e.node) << 8 | u64(e.role), edit = i}) or_return
			if e.op == .Set_Fact && !fact_slot(doc, e.node, e.role, style, emptied) {
				dropped^ += 1
			}
			// A flat text's root holds all of its comments.
			if e.node == ROOT && flat_doc(doc) {
				push(&groups, Target{node = ROOT, edit = i}) or_return
				continue
			}
			if e.role != .Comment_Foot {
				push(&targets, Target{node = e.node, edit = i}) or_return
				continue
			}
			n := doc.nodes[e.node]
			if n.kind == .Array || n.kind == .Map {
				push(&groups, Target{node = e.node, edit = i}) or_return
			}
			if e.node == ROOT {
				push(&groups, Target{node = NO_NODE, edit = i}) or_return
			}
		}
	}
	slice.sort_by(keys[:], proc(a, b: Fact_Key) -> bool { return a.key < b.key })
	for i in 1 ..< len(keys[:]) {
		if keys[i].key == keys[i-1].key {
			return {kind = .Conflicting_Edits, at = key_start(doc.nodes[Node_Index(keys[i].key >> 8)])}, false
		}
	}
	parents_of(doc, targets[:], &groups, allocator) or_return
	slice.stable_sort_by(groups[:], proc(a, b: Target) -> bool {
		if a.node != b.node {
			return a.node < b.node
		}
		return a.at < b.at
	})
	cx := Compose{doc = doc, list = list, style = style, comment_byte = comment_byte, text = text, chunks = chunks, dropped = dropped, keys = keys[:], emptied = emptied}
	cx.items, _ = make([dynamic]Item, allocator)
	cx.members, _ = make([dynamic]Member, allocator)
	cx.removed, _ = make([dynamic]bool, allocator)
	cx.dirty, _ = make([dynamic]bool, allocator)
	defer {
		delete(cx.items)
		delete(cx.members)
		delete(cx.removed)
		delete(cx.dirty)
	}
	for i := 0; i < len(groups[:]); {
		j := i
		for j < len(groups[:]) && groups[:][j].node == groups[:][i].node {
			j += 1
		}
		if e, good := compose_container(&cx, groups[:][i].node, groups[:][i:j], allocator); !good {
			return e, false
		}
		i = j
	}
	slice.sort_by(spans[:], proc(a, b: Written_Span) -> bool { return a.lo < b.lo })
	for i in 1 ..< len(spans[:]) {
		spans[i].hi = max(spans[i].hi, spans[i-1].hi)
	}
	for f in doc.facts {
		if fact_edit_of(&cx, f.node, f.role) >= 0 || fact_slot(doc, f.node, f.role, style, emptied) {
			continue
		}
		// An unnamed root comment above shared keys reads as the root's foot once the root is emptied, so it stays.
		if f.role == .Comment && f.node == ROOT && doc.shared_keys != 0 && emptied {
			continue
		}
		written := false
		if len(spans[:]) > 0 {
			i, _ := slice.binary_search_by(spans[:], f.lo, proc(s: Written_Span, lo: u64) -> slice.Ordering {
				return .Less if s.lo <= lo else .Greater
			})
			written = i > 0 && spans[i-1].hi >= f.lo + u64(f.n)
		}
		if !written {
			push(chunks, Chunk{lo = f.lo, hi = f.lo + u64(f.n), remove = true, fact = true}) or_return
			dropped^ += 1
		}
	}
	return {}, true
}

// Sorts the chunks and refuses two that overlap or two edits of one node. A fact the output cannot hold writes nothing
// inside a chunk that covers it.
@(private)
order_chunks :: proc(chunks: ^[dynamic]Chunk) -> Document_Error {
	slice.stable_sort_by(chunks[:], proc(a, b: Chunk) -> bool {
		if a.lo != b.lo {
			return a.lo < b.lo
		}
		return a.hi != b.hi ? a.hi < b.hi : a.rank < b.rank
	})
	at := u64(0)
	prev: Chunk
	have := false
	for i in 0 ..< len(chunks) {
		c := chunks[i]
		if c.fact && c.remove && have && c.hi <= at {
			chunks[i] = Chunk{lo = at, hi = at}
			continue
		}
		if have && (c.lo < at || c.lo == prev.lo && c.hi == prev.hi && c.rank == prev.rank) {
			return {kind = .Conflicting_Edits, at = c.lo}
		}
		at = c.hi
		prev = c
		have = true
	}
	return {}
}
