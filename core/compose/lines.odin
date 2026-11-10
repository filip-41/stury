#+private
package compose

import core ".."

// A flat text's root junctions. A record ends with a line end, the last perhaps not, and a comment is a line of its
// own. A record's cells use core's junction, with the delimiter as separator.

// Whether the bytes written from `from`, or else the source before `lo`, end a line. The text's start ends one.
ends_line :: proc(cx: ^Compose, from: int, lo: u64) -> bool {
	src := cx.doc.src
	last: u8
	switch {
	case len(cx.text) > from:
		last = cx.text[len(cx.text)-1]
	case lo <= core.text_start(src, 0):
		return true
	case:
		last = src[lo-1]
	}
	return last == '\n' || last == '\r'
}

// Composes the junction between survivors `l` and `r` of the root. A new last record ends the way the old last record
// did.
compose_root_junction :: proc(cx: ^Compose, open, close: u64, l, r: int, inserts: []core.Edit) -> bool {
	doc := cx.doc
	members := cx.members[:]
	n := len(members)
	has_right := r < n
	lo, hi := junction_items(cx, core.ROOT, open, close, l, r, false) or_return
	first := hi
	if len(cx.items) > 0 {
		first = cx.items[0].lo
	}
	a_end, b_lo: u64
	switch {
	case r - l > 1:
		a_end, b_lo = head_lo(doc, members[l + 1]), members[r - 1].hi
	case has_right:
		a_end, b_lo = first, first
	case:
		a_end = max(lo, core.text_start(doc.src, 0))
		b_lo = a_end
	}
	sep := transmute([]u8)cx.edit.member_sep(doc, core.ROOT)
	from := len(cx.text)
	cx.in_line, cx.value_line = false, false
	emit_range(cx, lo, a_end, false) or_return
	owner := members[r].node if has_right else core.ROOT
	role := core.Role.Comment if has_right else .Comment_Foot
	new := new_fact(cx, owner, role)
	ended := ends_line(cx, from, a_end)
	for e, i in inserts {
		if i > 0 || !ended {
			put_text(cx, sep) or_return
		}
		write_member(cx, e) or_return
	}
	if len(inserts) > 0 {
		ended = false
		last_end := open
		if n > 0 {
			last_end = members[n - 1].hi
		}
		if has_right || b_lo < hi || new >= 0 || ends_line(cx, len(cx.text), last_end) {
			put_text(cx, sep) or_return
			ended = true
		}
	}
	emit_range(cx, b_lo, hi, false) or_return
	cx.in_line = false
	if new >= 0 {
		if b_lo < hi {
			ended = ends_line(cx, from, hi)
		}
		cx.value_line = !ended
		write_fact(cx, cx.list.edits[new], hi, hi) or_return
	}
	cx.in_line = false
	return emit_chunk(cx, lo, hi, from, .Line_Head if has_right else .Line_Tail)
}

// Writes the edits of the root's comments above its header, which no junction reaches: each fact in place, or a new
// one at the text's start.
compose_root_head :: proc(cx: ^Compose, open: u64) -> bool {
	doc := cx.doc
	for f in core.all_facts(doc, core.ROOT) {
		if f.lo < open && fact_edit_of(cx, core.ROOT, f.role) >= 0 {
			member_fact(cx, f) or_return
		}
	}
	if new := new_fact(cx, core.ROOT, .Comment); new >= 0 {
		at := core.text_start(doc.src, 0)
		from := len(cx.text)
		cx.in_line, cx.value_line = false, false
		write_fact(cx, cx.list.edits[new], at, at) or_return
		emit_chunk(cx, at, at, from, .Line_Head) or_return
	}
	return true
}
