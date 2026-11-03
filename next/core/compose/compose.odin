package compose

import "base:runtime"
import "core:bytes"
import "core:slice"
import core ".."

// A commit, composed per container. A container is its members and the gaps between them, and the root is the
// one member of the text. A junction is the bytes between two surviving neighbours: the gaps, the removed members and
// the new members between them. An edited junction becomes one chunk, written once, so chunks overlap only when a set
// covers a nested edit. A fact goes with its node: a kept inline stays on its value's line, and a kept head or foot
// starts a line of its own.

@(private)
NO_BYTE :: max(u64)

// The order of chunks at one byte, which only a member of no bytes makes possible: what comes before a line, what comes
// before a member, a set, what comes after a member, what comes after a line.
@(private)
Rank :: enum u8 {
	Line_Head,
	Head,
	Set,
	Tail,
	Line_Tail,
}

// A member as a commit reads it: its value's node, its first byte, key included, and one past its value.
Member :: struct {
	node:   core.Node_Index,
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
	role:   core.Role,
	line:   bool,
}

// One commit's composing state, whose allocations all come from the commit's arena. `in_line` says the last bytes written are a line comment with no line end after them,
// and `value_line` that no line end follows the last value written. A format with its own junctions composes on it.
Compose :: struct {
	doc:          ^core.Document,
	list:         ^core.Edit_List,
	root:         ^Root_Spelling,
	style:        core.Comment_Spelling,
	comment_byte: u8,
	allocator:    runtime.Allocator,
	err:          core.Document_Error, // what a procedure returning false refuses, `.No_Memory` until one sets it
	text:         [dynamic]u8,
	chunks:       [dynamic]Chunk,
	dropped:      int,
	keys:         []Fact_Key,
	items:        [dynamic]Item,
	members:      [dynamic]Member,
	emptied:      bool,
	in_line:      bool,
	value_line:   bool,
}

// Records why the commit stops, and returns false for `or_return`.
@(private)
refuse :: proc(cx: ^Compose, err: core.Document_Error) -> bool {
	cx.err = err
	return false
}

// Returns the fact edit of `node` and `role`, or -1.
fact_edit_of :: proc(cx: ^Compose, node: core.Node_Index, role: core.Role) -> int {
	i, found := slice.binary_search_by(cx.keys, u64(node) << 8 | u64(role), proc(k: Fact_Key, want: u64) -> slice.Ordering {
		return slice.cmp(k.key, want)
	})
	return cx.keys[i].edit if found else -1
}

// Returns whether `node` holds a fact of `role`.
@(private)
holds_fact :: proc(doc: ^core.Document, node: core.Node_Index, role: core.Role) -> bool {
	for f in core.all_facts(doc, node) {
		if f.role == role {
			return true
		}
	}
	return false
}

// Returns what a source fact becomes: the output cannot hold it, an edit names it, or it stays. A set writes the first
// fact it names and cuts the others.
@(private)
fact_action :: proc(cx: ^Compose, f: core.Fact) -> (action: Item_Action, edit: int) {
	doc := cx.doc
	slot := fact_slot(doc, f.node, f.role, cx.style, cx.emptied)
	edit = fact_edit_of(cx, f.node, f.role)
	if edit < 0 {
		return .Keep if slot else .Cut, -1
	}
	if !slot || cx.list.edits[edit].op == .Remove_Fact {
		return .Cut, edit
	}
	for g in core.all_facts(doc, f.node) {
		if g.role == f.role {
			return .Write if g.lo == f.lo else .Cut, edit
		}
	}
	return .Cut, edit
}

// Returns the set of `node` and `role` that writes a new fact: the node holds none of that role.
new_fact :: proc(cx: ^Compose, node: core.Node_Index, role: core.Role) -> int {
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
@(private)
add_items :: proc(cx: ^Compose, node: core.Node_Index, lo, hi: u64) -> bool {
	for f in core.all_facts(cx.doc, node) {
		if f.lo < lo || f.lo >= hi {
			continue
		}
		action, edit := fact_action(cx, f)
		push(&cx.items, Item{lo = f.lo, hi = f.lo + u64(f.n), edit = edit, action = action, role = f.role, line = f.spelling >> 8 == 0}) or_return
	}
	return true
}

// Sorts the junction's items by byte.
@(private)
sort_items :: proc(cx: ^Compose) {
	slice.sort_by(cx.items[:], proc(a, b: Item) -> bool { return a.lo < b.lo })
}

// Writes `b`, ending a line comment first when `b` does not.
put_text :: proc(cx: ^Compose, b: []u8) -> bool {
	if len(b) == 0 {
		return true
	}
	if cx.in_line && core.line_end_len(b, 0) == 0 {
		push(&cx.text, '\n') or_return
		cx.value_line = false
	}
	cx.in_line = false
	push_all(&cx.text, b) or_return
	if body_line_end(b) {
		cx.value_line = false
	}
	return true
}

// Writes a fact edit's body over `lo` through `hi`, or at `hi` when the two are equal: `//body` when a line comment can
// end there, else `/*body*/`, or the format's comment byte. A body the output cannot spell is dropped and counted. A
// fact that leads its line starts on a line of its own with the line's indent, and a new head or foot (`fresh`) also ends
// its line, so a role reads back where it was written.
write_fact :: proc(cx: ^Compose, e: core.Edit, lo, hi: u64) -> bool {
	doc := cx.doc
	inline := e.role == .Comment_Inline
	fresh := hi == lo && !inline
	line := (fresh || hi >= u64(len(doc.src)) || core.line_end_len(doc.src, hi) > hi) && !body_line_end(e.text)
	held := !core.has_line_end(e.text) if cx.style == .Byte else line || bytes.index(e.text, transmute([]u8)string("*/")) < 0
	if !held {
		cx.dropped += 1
		return true
	}
	indent: []u8
	lead := false
	if cx.style == .Byte {
		lead = cx.value_line
	} else if !inline {
		indent, lead = line_shape(doc, lo)
		lead = lead || cx.value_line
	}
	if cx.in_line {
		push(&cx.text, '\n') or_return
	}
	if lead {
		push(&cx.text, '\n') or_return
		push_all(&cx.text, indent) or_return
	}
	if inline {
		push(&cx.text, ' ') or_return
	}
	switch {
	case cx.style == .Byte:
		push(&cx.text, cx.comment_byte) or_return
		push_all(&cx.text, e.text) or_return
	case line:
		push_all(&cx.text, transmute([]u8)string("//")) or_return
		push_all(&cx.text, e.text) or_return
	case:
		push_all(&cx.text, transmute([]u8)string("/*")) or_return
		push_all(&cx.text, e.text) or_return
		push_all(&cx.text, transmute([]u8)string("*/")) or_return
	}
	if fresh {
		push(&cx.text, '\n') or_return
		push_all(&cx.text, indent) or_return
	}
	cx.in_line = line && !fresh
	if lead || fresh {
		cx.value_line = false
	}
	return true
}

// Writes `lo` through `hi` of the source, applying the items there. `fresh` says the range holds only heads and feet,
// which must not read as the last value's inline.
emit_range :: proc(cx: ^Compose, lo, hi: u64, fresh: bool) -> bool {
	src := cx.doc.src
	at := lo
	for it in cx.items {
		zero := it.hi == it.lo
		if zero && (fresh || it.lo < lo || it.lo > hi) || !zero && (it.lo < lo || it.lo >= hi) {
			continue
		}
		put_text(cx, src[at:it.lo]) or_return
		at = it.hi
		switch it.action {
		case .Cut:
		case .Write:
			write_fact(cx, cx.list.edits[it.edit], it.lo, it.hi) or_return
		case .Keep:
			if fresh && cx.value_line {
				indent, _ := line_shape(cx.doc, it.lo)
				put_text(cx, transmute([]u8)string("\n")) or_return
				push_all(&cx.text, indent) or_return
			}
			put_text(cx, src[it.lo:it.hi]) or_return
			cx.in_line = it.line
		}
	}
	return put_text(cx, src[at:hi])
}

// Returns the first separator in `lo` through `hi` that lies outside the junction's comments.
@(private)
gap_comma :: proc(cx: ^Compose, lo, hi: u64, sep: u8) -> u64 {
	src := cx.doc.src
	at := lo
	for it in cx.items {
		if it.lo >= lo && it.lo < hi {
			if k := bytes.index_byte(src[at:it.lo], sep); k >= 0 {
				return at + u64(k)
			}
			at = it.hi
		}
	}
	k := bytes.index_byte(src[at:max(at, hi)], sep)
	return at + u64(k) if k >= 0 else NO_BYTE
}

// Returns the byte of member `v` where its comments start.
head_lo :: proc(doc: ^core.Document, m: Member) -> u64 {
	lo := m.lo
	for f in core.all_facts(doc, m.node) {
		if f.lo < lo {
			lo = f.lo
		}
	}
	return lo
}

// Returns one past member `m`'s value and the comments after it.
@(private)
tail_hi :: proc(doc: ^core.Document, m: Member) -> u64 {
	hi := m.hi
	for f in core.all_facts(doc, m.node) {
		if f.lo >= hi {
			hi = f.lo + u64(f.n)
		}
	}
	return hi
}

// Writes an insert's member, its key first.
write_member :: proc(cx: ^Compose, e: core.Edit) -> bool {
	edit := cx.doc.spelling.edit
	if cx.in_line {
		put_text(cx, transmute([]u8)string("\n")) or_return
	}
	if e.role == .Key {
		if edit.key_text == nil || !edit.key_text(cx.doc, e.key, &cx.text) {
			return false
		}
		push_all(&cx.text, transmute([]u8)edit.key_sep) or_return
	}
	push_all(&cx.text, e.text) or_return
	cx.value_line = true
	return true
}

// Fills `cx.items` with the comment items between survivors `l` and `r` of container `c`, sorted, and returns the span
// they lie in: from the left survivor's end, else `open`, to the right survivor's start, else `close`. `left` says
// whether the left survivor's own items are read, which a format that keeps no comment on a record's line leaves out.
junction_items :: proc(cx: ^Compose, c: core.Node_Index, open, close: u64, l, r: int, left: bool) -> (lo, hi: u64, ok: bool) {
	members := cx.members[:]
	lo, hi = open, close
	if l >= 0 {
		lo = members[l].hi
	}
	if r < len(members) {
		hi = members[r].lo
	}
	clear(&cx.items)
	if left && l >= 0 {
		add_items(cx, members[l].node, lo, hi) or_return
	}
	if r < len(members) {
		add_items(cx, members[r].node, lo, hi) or_return
	}
	if c != core.NO_NODE {
		add_items(cx, c, lo, hi) or_return
	}
	sort_items(cx)
	return lo, hi, true
}

// Composes the junction between survivors `l` and `r`, `-1` for the open and the member count for the close, with the
// edits `inserts` writes between them.
@(private)
compose_junction :: proc(cx: ^Compose, c: core.Node_Index, open, close: u64, l, r: int, inserts: []core.Edit) -> bool {
	doc := cx.doc
	members := cx.members[:]
	has_left, has_right := l >= 0, r < len(members)
	run := r - l > 1
	lo, hi := junction_items(cx, c, open, close, l, r, true) or_return

	following := len(inserts) > 0 || has_right
	l_end, first_r := lo, hi
	for it in cx.items {
		if it.role == .Comment_Inline {
			l_end = max(l_end, it.hi)
		} else if first_r == hi {
			first_r = it.lo
		}
	}
	new_inline := -1
	inline_at := lo
	if has_left {
		new_inline = new_fact(cx, members[l].node, .Comment_Inline)
		if new_inline >= 0 {
			if comma := blanks_end(doc.src, lo, u64(len(doc.src))); following && comma < u64(len(doc.src)) && doc.src[comma] == ',' {
				inline_at = comma + 1
				l_end = max(l_end, inline_at)
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
	sep_text := transmute([]u8)doc.spelling.edit.member_sep(doc)
	ca, cz := NO_BYTE, NO_BYTE
	if c != core.NO_NODE {
		ca = gap_comma(cx, lo, a_end, sep_text[0])
		cz = gap_comma(cx, b_lo, hi, sep_text[0])
	}
	joined := ca != NO_BYTE && following
	if ca != NO_BYTE && !following {
		push(&cx.items, Item{lo = ca, hi = ca + 1, action = .Cut}) or_return
	}
	if cz != NO_BYTE && len(inserts) == 0 && (joined || !has_left) {
		push(&cx.items, Item{lo = cz, hi = cz + 1, action = .Cut}) or_return
	}
	if new_inline >= 0 {
		push(&cx.items, Item{lo = inline_at, hi = inline_at, edit = new_inline, action = .Write}) or_return
	}
	if len(cx.items) > 1 {
		sort_items(cx)
	}

	from := len(cx.text)
	cx.in_line, cx.value_line = false, has_left
	if has_left && following && !joined && (len(inserts) > 0 || cz == NO_BYTE) {
		put_text(cx, sep_text) or_return
		cx.value_line = true
	}
	emit_range(cx, lo, a_end, false) or_return
	for e, i in inserts {
		if i > 0 {
			put_text(cx, sep_text) or_return
		}
		write_member(cx, e) or_return
	}
	if len(inserts) > 0 && has_right && cz == NO_BYTE {
		put_text(cx, sep_text) or_return
	}
	emit_range(cx, b_lo, hi, true) or_return
	owner := members[r].node if has_right else (c if c != core.NO_NODE else members[0].node)
	role := core.Role.Comment if has_right else .Comment_Foot
	// A new root foot goes at the text's end, which the text's own junction writes.
	if edit := new_fact(cx, owner, role); edit >= 0 && (has_right || c != core.ROOT) {
		write_fact(cx, cx.list.edits[edit], hi, hi) or_return
	}
	if cx.in_line && hi < u64(len(doc.src)) && core.line_end_len(doc.src, hi) == hi {
		push(&cx.text, '\n') or_return
	}
	cx.in_line = false
	return emit_chunk(cx, lo, hi, from, .Head if has_right || !has_left else .Tail)
}

// Makes the text written from `from` the chunk that replaces `lo` through `hi`.
emit_chunk :: proc(cx: ^Compose, lo, hi: u64, from: int, rank: Rank) -> bool {
	_, ok := push(&cx.chunks, Chunk{lo = lo, hi = hi, from = from, to = len(cx.text), rank = rank})
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
member_fact :: proc(cx: ^Compose, f: core.Fact) -> bool {
	action, edit := fact_action(cx, f)
	from := len(cx.text)
	cx.in_line, cx.value_line = false, false
	if action == .Write {
		write_fact(cx, cx.list.edits[edit], f.lo, f.lo + u64(f.n)) or_return
	}
	cx.in_line = false
	_, ok := push(&cx.chunks, Chunk{lo = f.lo, hi = f.lo + u64(f.n), from = from, to = len(cx.text), cut = action == .Cut})
	return ok
}

// Composes one edited container: `c` is `NO_NODE` for the text around the root.
@(private)
compose_container :: proc(cx: ^Compose, c: core.Node_Index, group: []Target) -> bool {
	doc := cx.doc
	clear(&cx.members)
	lo, hi := u64(0), u64(len(doc.src))
	lines := c == core.ROOT && core.is_flat(doc)
	if c == core.NO_NODE {
		at := core.node_start(doc.nodes[core.ROOT])
		push(&cx.members, Member{node = core.ROOT, lo = at, hi = at + u64(len(core.span(doc, core.ROOT)))}) or_return
	} else {
		lo, hi = interior(doc, c)
		if lines {
			cx.root.root_head(cx, lo) or_return
		}
		it := core.children(doc, c)
		for {
			v, more := core.child_next(&it)
			if !more {
				break
			}
			at := value_lo(doc, c, v)
			push(&cx.members, Member{node = v, lo = at, hi = core.node_start(doc.nodes[v]) + u64(len(core.span(doc, v)))}) or_return
		}
	}
	members := cx.members[:]
	n := len(members)
	flags, ferr := make([]bool, 2 * n + 1, cx.allocator)
	if ferr != nil {
		return false
	}
	removed, dirty := flags[:n], flags[n:]
	position :: proc(members: []Member, node: core.Node_Index) -> int {
		i, found := slice.binary_search_by(members, node, proc(m: Member, n: core.Node_Index) -> slice.Ordering {
			return slice.cmp(m.node, n)
		})
		return i if found else -1
	}
	inserts, _ := make([dynamic]core.Edit, cx.allocator)
	for t in group {
		e := cx.list.edits[t.edit]
		switch e.op {
		case .Insert:
			dirty[e.at] = true
			push(&inserts, e) or_return
		case .Remove:
			p := position(members, e.node)
			if p < 0 {
				return refuse(cx, {kind = .Bad_Index})
			}
			if removed[p] {
				return refuse(cx, {kind = .Conflicting_Edits, at = members[p].lo})
			}
			removed[p] = true
		case .Set:
		case .Set_Fact, .Remove_Fact:
			if e.role == .Comment_Foot {
				dirty[n] = true
				if c != core.NO_NODE {
					for f in core.all_facts(doc, c) {
						if f.role == .Comment_Foot && f.lo >= lo && f.lo < hi {
							dirty[gap_of(members, f.lo)] = true
						}
					}
				}
				continue
			}
			if lines && e.node == core.ROOT {
				continue
			}
			p := position(members, e.node)
			if p < 0 {
				return refuse(cx, {kind = .Bad_Index})
			}
			if e.role == .Comment_Inline {
				dirty[p + 1] = true
				continue
			}
			dirty[p] = true
			for f in core.all_facts(doc, e.node) {
				if f.role == .Comment && f.lo >= members[p].lo && f.lo < members[p].hi {
					member_fact(cx, f) or_return
				}
			}
		}
	}
	l, k := -1, 0
	for r in 0 ..= n {
		if r < n && removed[r] {
			continue
		}
		edited := r - l > 1
		for i in l + 1 ..= r {
			edited = edited || dirty[i]
		}
		j := k
		for j < len(inserts) && int(inserts[j].at) <= r {
			j += 1
		}
		if edited {
			if lines {
				cx.root.root_junction(cx, lo, hi, l, r, inserts[k:j]) or_return
			} else {
				compose_junction(cx, c, lo, hi, l, r, inserts[k:j]) or_return
			}
		}
		k = j
		l = r
	}
	return true
}

// A `Target` names a node a group of edits works on, a container for an insert or a removed member, with the edit that
// named it. An insert's `at` orders it against the other inserts of its container.
@(private)
Target :: struct {
	node: core.Node_Index,
	edit: int,
	at:   u32,
}

// Returns the node after `node`'s subtree.
@(private)
subtree_end :: #force_inline proc(doc: ^core.Document, node: core.Node_Index) -> core.Node_Index {
	n := doc.nodes[node]
	return node + (core.Node_Index(n.n) if n.kind == .Array || n.kind == .Map else 1)
}

// Returns the parent of `node`, `NO_NODE` for the root. `next` is the first node the walk has not read and `stack` the
// containers open there, so ascending calls walk the tree once and step over a subtree no call reaches.
@(private)
parent_of :: proc(doc: ^core.Document, node: core.Node_Index, stack: ^[dynamic]core.Node_Index, next: ^core.Node_Index) -> (parent: core.Node_Index, ok: bool) {
	for next^ < node {
		end := subtree_end(doc, next^)
		if end <= node {
			next^ = end
			continue
		}
		push(stack, next^) or_return
		next^ += 1
	}
	for len(stack) > 0 && subtree_end(doc, stack[len(stack) - 1]) <= node {
		pop(stack)
	}
	return stack[len(stack) - 1] if len(stack) > 0 else core.NO_NODE, true
}

// Sweeps the edits once in node order. Returns the conflict when an edit writes inside a subtree another edit removes or
// a fact edit names a node below a set's node, for the earliest such edit recorded. A set on a fact's own node is not
// above it, so a node's sets count from the next node. Fills `groups` with what each container's composition takes: an
// insert or a foot goes to its own container, and a removal or another fact edit to its node's parent.
@(private)
group_edits :: proc(cx: ^Compose, groups: ^[dynamic]Target) -> bool {
	doc, list := cx.doc, cx.list
	// A node in the high half and an edit's index in the low, so the sort needs no comparison procedure.
	order, _ := make([dynamic]u64, 0, len(list.edits), cx.allocator)
	for e, i in list.edits {
		if int(e.node) < len(doc.nodes) {
			push(&order, u64(e.node) << 32 | u64(i)) or_return
		}
	}
	slice.sort(order[:])
	stack, _ := make([dynamic]core.Node_Index, cx.allocator)
	removed_hi, set_hi, next := core.Node_Index(0), core.Node_Index(0), core.Node_Index(0)
	first, first_node := -1, core.Node_Index(0)
	for i := 0; i < len(order); {
		node := core.Node_Index(order[i] >> 32)
		j, own_set_hi := i, core.Node_Index(0)
		for ; j < len(order) && core.Node_Index(order[j] >> 32) == node; j += 1 {
			#partial switch list.edits[u32(order[j])].op {
			case .Remove:
				removed_hi = max(removed_hi, subtree_end(doc, node))
			case .Set:
				own_set_hi = subtree_end(doc, node)
			}
		}
		for key in order[i:j] {
			at := int(u32(key))
			e := list.edits[at]
			fact := e.op == .Set_Fact || e.op == .Remove_Fact
			if e.op != .Remove && (removed_hi > node || fact && set_hi > node) && (first < 0 || at < first) {
				first, first_node = at, node
			}
			t := Target{node = node, edit = at, at = e.at}
			foot := fact && e.role == .Comment_Foot
			switch {
			case e.op == .Set:
			// A flat text's root holds all of its comments.
			case e.op == .Insert, fact && node == core.ROOT && core.is_flat(doc):
				push(groups, t) or_return
			case foot:
				if n := doc.nodes[node]; n.kind == .Array || n.kind == .Map {
					push(groups, t) or_return
				}
				if node == core.ROOT {
					push(groups, Target{node = core.NO_NODE, edit = t.edit}) or_return
				}
			case:
				parent := parent_of(doc, node, &stack, &next) or_return
				push(groups, Target{node = parent, edit = t.edit}) or_return
			}
		}
		set_hi = max(set_hi, own_set_hi)
		i = j
	}
	if first >= 0 {
		return refuse(cx, {kind = .Conflicting_Edits, at = core.node_start(doc.nodes[first_node])})
	}
	return true
}

// Builds a tree's chunks: every set's, then each edited container's junctions, then a chunk for each source fact the
// output cannot hold.
@(private)
compose_tree :: proc(cx: ^Compose) -> bool {
	doc, list := cx.doc, cx.list
	style := cx.style
	if edit := doc.spelling.edit; edit != nil && edit.emptied != nil {
		cx.emptied = edit.emptied(doc, list)
	}
	emptied := cx.emptied
	cx.text, _ = make([dynamic]u8, cx.allocator)
	cx.chunks, _ = make([dynamic]Chunk, cx.allocator)
	cx.items, _ = make([dynamic]Item, cx.allocator)
	cx.members, _ = make([dynamic]Member, cx.allocator)
	groups, _ := make([dynamic]Target, cx.allocator)
	keys, _ := make([dynamic]Fact_Key, cx.allocator)
	group_edits(cx, &groups) or_return
	for e, i in list.edits {
		switch e.op {
		case .Insert, .Remove:
		case .Set:
			from := len(cx.text)
			if e.role == .Key {
				if doc.spelling.edit.key_text == nil || !doc.spelling.edit.key_text(doc, e.text, &cx.text) {
					return false
				}
			} else {
				push_all(&cx.text, e.text) or_return
			}
			at := core.node_start(doc.nodes[e.node])
			end := at + u64(len(core.span(doc, e.node)))
			push(&cx.chunks, Chunk{lo = at, hi = end, from = from, to = len(cx.text), rank = .Set}) or_return
		case .Set_Fact, .Remove_Fact:
			push(&keys, Fact_Key{key = u64(e.node) << 8 | u64(e.role), edit = i}) or_return
			if e.op == .Set_Fact && !fact_slot(doc, e.node, e.role, style, emptied) {
				cx.dropped += 1
			}
		}
	}
	slice.sort_by(keys[:], proc(a, b: Fact_Key) -> bool { return a.key < b.key })
	for i in 1 ..< len(keys[:]) {
		if keys[i].key == keys[i-1].key {
			return refuse(cx, {kind = .Conflicting_Edits, at = core.node_start(doc.nodes[core.Node_Index(keys[i].key >> 8)])})
		}
	}
	slice.stable_sort_by(groups[:], proc(a, b: Target) -> bool {
		if a.node != b.node {
			return a.node < b.node
		}
		return a.at < b.at
	})
	cx.keys = keys[:]
	for i := 0; i < len(groups[:]); {
		j := i
		for j < len(groups[:]) && groups[:][j].node == groups[:][i].node {
			j += 1
		}
		compose_container(cx, groups[:][i].node, groups[:][i:j]) or_return
		i = j
	}
	for f in doc.facts {
		if fact_edit_of(cx, f.node, f.role) >= 0 || fact_slot(doc, f.node, f.role, style, emptied) {
			continue
		}
		// An unnamed root comment above shared keys reads as the root's foot once the root is emptied, so it stays.
		if f.role == .Comment && f.node == core.ROOT && doc.shared_keys != 0 && emptied {
			continue
		}
		push(&cx.chunks, Chunk{lo = f.lo, hi = f.lo + u64(f.n), cut = true, drop = true}) or_return
	}
	return true
}

// Sorts the chunks and refuses two that overlap or two edits of one node. A cut inside a chunk that covers it writes
// nothing. A fact the output cannot hold is counted here, unless a set's bytes hold it.
@(private)
order_chunks :: proc(cx: ^Compose) -> bool {
	chunks := cx.chunks[:]
	slice.stable_sort_by(chunks, proc(a, b: Chunk) -> bool {
		if a.lo != b.lo {
			return a.lo < b.lo
		}
		return a.hi != b.hi ? a.hi < b.hi : a.rank < b.rank
	})
	at := u64(0)
	prev: Chunk
	have := false
	for &c in chunks {
		covered := c.cut && have && c.hi <= at
		if c.drop && !(covered && prev.rank == .Set) {
			cx.dropped += 1
		}
		if covered {
			c = Chunk{lo = at, hi = at}
			continue
		}
		if have && (c.lo < at || c.lo == prev.lo && c.hi == prev.hi && c.rank == prev.rank) {
			return refuse(cx, {kind = .Conflicting_Edits, at = c.lo})
		}
		at = c.hi
		prev = c
		have = true
	}
	return true
}
