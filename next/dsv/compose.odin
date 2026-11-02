package dsv

import core "../core"

// A delimited text's root junctions. A record ends with a line end, the last perhaps not, and a comment is a line of its
// own. A record's cells use core's junction, with the delimiter as separator.

// Whether the bytes written from `from`, or else the source before `lo`, end a line. The text's start ends one.
@(private)
ends_line :: proc(cx: ^core.Compose, from: int, lo: u64) -> bool {
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
@(private)
compose_root_junction :: proc(cx: ^core.Compose, open, close: u64, l, r: int, inserts: []core.Edit) -> bool {
	doc := cx.doc
	members := cx.members[:]
	n := len(members)
	has_left, has_right := l >= 0, r < n
	lo, hi := open, close
	if has_left {
		lo = members[l].hi
	}
	if has_right {
		hi = members[r].lo
	}
	clear(&cx.items)
	if has_right {
		core.add_items(cx, members[r].node, lo, hi) or_return
	}
	core.add_items(cx, core.ROOT, lo, hi) or_return
	core.sort_items(cx)
	first := hi
	if len(cx.items) > 0 {
		first = cx.items[0].lo
	}
	a_end, b_lo: u64
	switch {
	case r - l > 1:
		a_end, b_lo = core.head_lo(doc, members[l + 1]), members[r - 1].hi
	case has_right:
		a_end, b_lo = first, first
	case:
		a_end = max(lo, core.text_start(doc.src, 0))
		b_lo = a_end
	}
	sep := transmute([]u8)edit_record_sep(doc)
	from := len(cx.text)
	cx.in_line, cx.value_line = false, false
	core.emit_range(cx, lo, a_end, core.NO_BYTE, false) or_return
	owner := members[r].node if has_right else core.ROOT
	role := core.Role.Comment if has_right else .Comment_Foot
	new := core.new_fact(cx, owner, role)
	ended := ends_line(cx, from, a_end)
	for e, i in inserts {
		if !ended {
			core.put_text(cx, sep) or_return
		}
		core.write_member(cx, e) or_return
		ended = i == len(inserts) - 1
		if !ended {
			ended = true
			core.put_text(cx, sep) or_return
		} else {
			ended = false
		}
	}
	if len(inserts) > 0 {
		last_end := open
		if n > 0 {
			last_end = members[n - 1].hi
		}
		if has_right || b_lo < hi || new >= 0 || ends_line(cx, len(cx.text), last_end) {
			core.put_text(cx, sep) or_return
			ended = true
		}
	}
	core.emit_range(cx, b_lo, hi, core.NO_BYTE, false) or_return
	cx.in_line = false
	if new >= 0 {
		if b_lo < hi {
			ended = ends_line(cx, from, hi)
		}
		cx.value_line = !ended
		core.write_fact(cx, cx.list.edits[new], hi, hi) or_return
	}
	cx.in_line = false
	return core.emit_chunk(cx, lo, hi, from, core.RANK_LINE_HEAD if has_right else core.RANK_LINE_TAIL)
}

// Writes the edits of the root's comments above its header, which no junction reaches: each fact in place, or a new
// one at the text's start.
@(private)
compose_root_head :: proc(cx: ^core.Compose, open: u64) -> (err: core.Document_Error, ok: bool) {
	err = {kind = .No_Memory}
	doc := cx.doc
	for f in core.all_facts(doc, core.ROOT) {
		if f.lo < open && core.fact_edit_of(cx, core.ROOT, f.role) >= 0 {
			core.member_fact(cx, f) or_return
		}
	}
	if new := core.new_fact(cx, core.ROOT, .Comment); new >= 0 {
		at := core.text_start(doc.src, 0)
		from := len(cx.text)
		cx.in_line, cx.value_line = false, false
		core.write_fact(cx, cx.list.edits[new], at, at) or_return
		core.emit_chunk(cx, at, at, from, core.RANK_LINE_HEAD) or_return
	}
	return {}, true
}
