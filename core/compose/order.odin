#+private
package compose

import "core:bytes"
import core ".."

// A reordered container, composed as one chunk of segments. A survivor is its bytes from its first head comment through
// its value, with its inline comments carried beside it, and the gap before each place in the order is the source's gap
// at that place, so the separators, a trailing comma, lines and indent stay where they were. A segment of source bytes
// is spliced with the chunks inside it, so an edit within a moved member still applies.

// A piece of a reordered container's text: source bytes, spliced with the chunks inside them, or, when `written`, the
// bytes `lo` through `hi` of `Compose.text`.
Segment :: struct {
	lo, hi:  u64,
	written: bool,
}

// Returns entry `i` of a reorder edit's order.
order_at :: #force_inline proc(order: []u8, i: int) -> int {
	b := order[4 * i:]
	return int(u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24)
}

// Composes container `c`, whose members lie in `lo` through `hi`, in the order `order` gives its survivors and
// `inserts`. `removed` marks the members a removal names.
compose_order :: proc(cx: ^Compose, c: core.Node_Index, lo, hi: u64, removed: []bool, inserts: []core.Edit, order: []u8) -> bool {
	doc := cx.doc
	members := cx.members[:]
	n := len(members)
	count := len(order) / 4
	seen, serr := make([]bool, n + len(inserts), cx.allocator)
	if serr != nil {
		return false
	}
	for i in 0 ..< count {
		k := order_at(order, i)
		if k >= len(seen) || seen[k] || k < n && removed[k] {
			return refuse(cx, {kind = .Bad_Index})
		}
		seen[k] = true
	}
	for k in 0 ..< len(seen) {
		if !seen[k] && (k >= n || !removed[k]) || count == 0 {
			return refuse(cx, {kind = .Bad_Index})
		}
	}
	flat := core.is_flat(doc)
	sep := transmute([]u8)cx.edit.member_sep(doc, c)
	// Where each member's own bytes start: its first head comment, unless a separator lies between it and the member.
	starts, aerr := make([]u64, n, cx.allocator)
	if aerr != nil {
		return false
	}
	for m, i in members {
		starts[i] = head_lo(doc, m)
		if i > 0 && !flat && starts[i] < m.lo {
			junction_items(cx, c, lo, hi, i - 1, i, true) or_return
			if at := gap_comma(cx, members[i - 1].hi, m.lo, sep[0]); at != NO_BYTE && at >= starts[i] {
				starts[i] = m.lo
			}
		}
	}
	from := len(cx.segments)
	for j in 0 ..= count {
		left := order_at(order, j - 1) if j > 0 else -1
		switch {
		case j == 0:
			order_gap(cx, c, lo, hi, 0, starts, left) or_return
		case j == count:
			order_gap(cx, c, lo, hi, n, starts, left) or_return
			// A new root foot goes at the text's end, which the text's own junction writes.
			if c != core.ROOT {
				order_new_fact(cx, c, .Comment_Foot, hi) or_return
			}
		case j < n:
			order_gap(cx, c, lo, hi, j, starts, left) or_return
		case n >= 2:
			order_gap(cx, c, lo, hi, n - 1, starts, left) or_return
		case:
			at := len(cx.text)
			cx.in_line = false
			put_text(cx, sep) or_return
			if left >= 0 && left < n {
				order_inline(cx, members[left], cx.gap) or_return
			}
			put_text(cx, cx.gap) or_return
			push(&cx.segments, Segment{lo = u64(at), hi = u64(len(cx.text)), written = true}) or_return
		}
		if j == count {
			break
		}
		k := order_at(order, j)
		if k < n {
			order_new_fact(cx, members[k].node, .Comment, starts[k]) or_return
			push(&cx.segments, Segment{lo = starts[k], hi = members[k].hi}) or_return
			continue
		}
		at := len(cx.text)
		cx.in_line = false
		write_member(cx, inserts[k - n]) or_return
		push(&cx.segments, Segment{lo = u64(at), hi = u64(len(cx.text)), written = true}) or_return
	}
	_, ok := push(&cx.chunks, Chunk{lo = lo, hi = hi, from = from, to = len(cx.segments), rank = .Set, ordered = true})
	return ok
}

// Writes the source gap before member `g`, `g == n` for the one before the close, with the inline comments of member
// `g - 1` taken out and those of `left`, the order's entry before this gap, put in.
order_gap :: proc(cx: ^Compose, c: core.Node_Index, lo, hi: u64, g: int, starts: []u64, left: int) -> bool {
	doc := cx.doc
	src := doc.src
	members := cx.members[:]
	n := len(members)
	glo := members[g - 1].hi if g > 0 else lo
	ghi := starts[g] if g < n else hi
	cuts: [dynamic]core.Fact
	cuts.allocator = cx.allocator
	if g > 0 {
		for f in core.all_facts(doc, members[g - 1].node) {
			if f.role == .Comment_Inline && f.lo >= glo && f.lo < ghi {
				push(&cuts, f) or_return
			}
		}
	}
	moved := left >= 0 && left < n && left != g - 1
	// A member that stays where it was but whose inline comments an edit names has them written as a moved one's are.
	rewritten := moved || left == g - 1 && left >= 0 && fact_edit_of(cx, members[left].node, .Comment_Inline) >= 0
	if !rewritten && left == g - 1 && left >= 0 {
		return source_segment(cx, glo, ghi)
	}
	// Where the moved inline goes: where the cut one was, or before the gap's first line end, or after its separator.
	at := ghi
	if len(cuts) > 0 {
		at = cuts[0].lo
		for at > glo && (src[at - 1] == ' ' || src[at - 1] == '\t') {
			at -= 1
		}
	} else {
		clear(&cx.items)
		if g > 0 {
			add_items(cx, members[g - 1].node, glo, ghi) or_return
		}
		if c != core.NO_NODE {
			add_items(cx, c, glo, ghi) or_return
		}
		sort_items(cx)
		sep := cx.edit.member_sep(doc, c)
		from := glo
		if comma := gap_comma(cx, glo, ghi, sep[0]); comma != NO_BYTE {
			from = comma + u64(len(sep))
			at = from
		}
		if k := bytes.index_any(src[from:ghi], transmute([]u8)string("\r\n")); k >= 0 {
			at = from + u64(k)
			for at > from && (src[at - 1] == ' ' || src[at - 1] == '\t') {
				at -= 1
			}
		}
	}
	source_segment(cx, glo, at) or_return
	rest := at
	if len(cuts) > 0 {
		rest = cuts[0].lo
	}
	for f in cuts {
		source_segment(cx, rest, f.lo) or_return
		rest = f.lo + u64(f.n)
	}
	if rewritten {
		after := src[rest:ghi]
		text := len(cx.text)
		cx.in_line = false
		order_inline(cx, members[left], after) or_return
		push(&cx.segments, Segment{lo = u64(text), hi = u64(len(cx.text)), written = true}) or_return
	}
	if len(cuts) > 0 {
		// The blanks the cut comment stood after are gone, so a line end's or the next member's bytes follow directly.
		for rest < ghi && (src[rest] == ' ' || src[rest] == '\t') && !rewritten {
			rest += 1
		}
	}
	return source_segment(cx, rest, ghi)
}

// Writes member `m`'s inline comments, each after a space, as an edit of them says. A line comment ends its line unless
// `after`, the bytes that follow, starts with a line end after its blanks.
order_inline :: proc(cx: ^Compose, m: Member, after: []u8) -> bool {
	doc := cx.doc
	line := false
	for f in core.all_facts(doc, m.node) {
		if f.role != .Comment_Inline || f.lo < m.hi {
			continue
		}
		switch action, edit := fact_action(cx, f); action {
		case .Cut:
		case .Write:
			line = order_inline_text(cx, cx.list.edits[edit], after) or_return
		case .Keep:
			push(&cx.text, ' ') or_return
			push_all(&cx.text, doc.src[f.lo:f.lo + u64(f.n)]) or_return
			line = core.comment_tail(f.spelling) == 0
		}
	}
	if edit := new_fact(cx, m.node, .Comment_Inline); edit >= 0 {
		line = order_inline_text(cx, cx.list.edits[edit], after) or_return
	}
	if k := u64(len(blank_lead(after))); line && core.line_end_len(after, k) == k {
		push(&cx.text, '\n') or_return
	}
	return true
}

// Writes an inline comment edit's bodies, each after a space: the last a line comment where `after` starts with a line
// end after its blanks, or where a block comment cannot hold it, and the others block comments, dropping one that a block
// comment cannot hold. Returns whether it wrote a line comment.
order_inline_text :: proc(cx: ^Compose, e: core.Edit, after: []u8) -> (line, ok: bool) {
	k := u64(len(blank_lead(after)))
	n := fact_count(e)
	for i in 0 ..< n {
		body := fact_body(e, i)
		closes := bytes.index(body, transmute([]u8)string("*/")) >= 0
		if i < n - 1 && closes {
			cx.dropped += 1
			continue
		}
		line = i == n - 1 && (core.line_end_len(after, k) > k || closes)
		push(&cx.text, ' ') or_return
		put_comment(cx, body, line, e.padded) or_return
	}
	return line, true
}

// Writes as a segment of its own the fact of `role` an edit gives `node`, which holds none of that role, at the source
// byte `at` its line's shape is taken from.
order_new_fact :: proc(cx: ^Compose, node: core.Node_Index, role: core.Role, at: u64) -> bool {
	edit := new_fact(cx, node, role)
	if edit < 0 {
		return true
	}
	from := len(cx.text)
	cx.in_line, cx.value_line = false, false
	write_fact(cx, cx.list.edits[edit], at, at) or_return
	cx.in_line = false
	_, ok := push(&cx.segments, Segment{lo = u64(from), hi = u64(len(cx.text)), written = true})
	return ok
}

// Makes a chunk of each head comment before its member's bytes and each foot comment of `c` that a fact edit in
// `group` names, which the segments holding them splice. A member's inline comments are written where the order puts
// them (`order_inline`). A flat text's comments are lines of the root, which an order of its records does not place.
order_facts :: proc(cx: ^Compose, c: core.Node_Index, lo, hi: u64, group: []Target) -> bool {
	doc := cx.doc
	for t in group {
		e := cx.list.edits[t.edit]
		if e.op != .Set_Fact && e.op != .Remove_Fact {
			continue
		}
		if core.is_flat(doc) {
			return refuse(cx, {kind = .Conflicting_Edits, at = lo})
		}
		#partial switch e.role {
		case .Comment:
			for m in cx.members {
				if m.node != e.node {
					continue
				}
				for f in core.all_facts(doc, e.node) {
					if f.role == .Comment && f.lo < m.lo {
						member_fact(cx, f) or_return
					}
				}
			}
		case .Comment_Foot:
			for f in core.all_facts(doc, c) {
				if f.role == .Comment_Foot && f.lo >= lo && f.lo < hi {
					member_fact(cx, f) or_return
				}
			}
		}
	}
	return true
}

// Returns the spaces and tabs `b` starts with.
blank_lead :: proc(b: []u8) -> []u8 {
	i := 0
	for i < len(b) && (b[i] == ' ' || b[i] == '\t') {
		i += 1
	}
	return b[:i]
}

source_segment :: proc(cx: ^Compose, lo, hi: u64) -> bool {
	if hi <= lo {
		return true
	}
	_, ok := push(&cx.segments, Segment{lo = lo, hi = hi})
	return ok
}
