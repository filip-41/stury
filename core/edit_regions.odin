package core

import "core:slice"

// A value `list`'s edits make, at its path in the edited document: `want` the value the path reads there, or no value
// when `gone`, as a removed member's name and the place past an array's last element are.
Edited_Region :: struct {
	path: Path,
	want: Value,
	gone: bool,
}

// The regions of `list`'s document that its edits make, built in the context allocator: each value a set or an insert
// writes, each name a removal or a rename leaves free, the end of each array that gains or loses elements, and the
// whole of a container its edits reorder. A value no edit reaches is not among them. `known` is false as for
// `reads_as_edited`. The regions come in the edited document's order. `fits` is false when the regions are no paths a
// read answers alone: a path past `MAX_STEPS`, a flat text, whose paths do not group names as its read does, or an
// object on the way that repeats a key. A markup document's paths name its elements, not the grouped value's arrays,
// so its regions fit only as one set of an element's content that is no array, through the first element of each name
// on the way, which a read under `.First` answers. Its read of several paths builds the document.
edited_regions :: proc(list: ^Edit_List) -> (regions: []Edited_Region, known, fits: bool) {
	a := applied_of(list) or_return
	markup := is_markup(list.doc)
	if is_flat(list.doc) || (markup && !one_content_set(list)) {
		return nil, true, false
	}
	r := Regions{a = &a, fits = true, markup = markup}
	regions_of(&r, ROOT)
	return r.out[:], true, r.fits && (!markup || len(r.out) <= 1)
}

// Whether `list` sets the content of one element of a markup document to a value that is no array.
@(private = "file")
one_content_set :: proc(list: ^Edit_List) -> bool {
	if len(list.edits) != 1 {
		return false
	}
	e := list.edits[0]
	_, many := e.value.(^Array)
	return e.op == .Set && e.role == .Value && e.node != ROOT && !many && !key_equals(list.doc, e.node - 1, MARKUP_TEXT)
}

@(private = "file")
Regions :: struct {
	a:          ^Applied,
	steps:      [dynamic]Step, // the path from the root to the node being walked
	out:        [dynamic]Edited_Region,
	fits:       bool,
	markup:     bool,
	reached_at: int, // the entry of the applied edits' reached nodes past the last container the walk read
}

@(private = "file")
region :: proc(r: ^Regions, step: Maybe(Step), want: Value, gone := false) {
	path := make([]Step, len(r.steps) + (1 if step != nil else 0))
	copy(path, r.steps[:])
	if s, has := step.?; has {
		path[len(path) - 1] = s
	}
	append(&r.out, Edited_Region{path = {steps = path}, want = want, gone = gone})
}

// Adds the regions under node `n`, at the path `r.steps`, to `r`.
@(private = "file")
regions_of :: proc(r: ^Regions, n: Node_Index) {
	a := r.a
	doc := a.doc
	if has(a.is_set, n) {
		region(r, nil, set_of(a, n))
		return
	}
	if !has(a.dirty, n) || !r.fits {
		return
	}
	if _, reordered := entry_of(a.orders, n); reordered {
		region(r, nil, applied(a, n))
		return
	}
	if len(r.steps) >= MAX_STEPS - 1 {
		r.fits = false
		return
	}
	inserts := of_node(a.inserts, n)
	// The members of `n` an edit reaches are the reached nodes within its subtree that no other reached node holds. A
	// walk in document order enters each reached node at the entry the last one left off at.
	touched := make([dynamic]Node_Index)
	end := n + Node_Index(subtree_size(doc, n))
	k := r.reached_at + 1
	if r.reached_at >= len(a.reached) || a.reached[r.reached_at] != n {
		k, _ = slice.binary_search(a.reached[:], n + 1)
	}
	for k < len(a.reached) && a.reached[k] < end {
		v := a.reached[k]
		append(&touched, v)
		for past := v + Node_Index(subtree_size(doc, v)); k < len(a.reached) && a.reached[k] < past; {
			k += 1
		}
	}
	r.reached_at = k
	if doc.nodes[n].kind == .Object {
		object_regions(r, n, touched[:], inserts)
		return
	}
	if r.markup {
		r.fits = false
		return
	}
	resized := len(inserts) > 0
	for v in touched {
		resized ||= has(a.gone, v)
	}
	// An array that keeps its length keeps each element's index, so the walk ends at the last member an edit reaches.
	at, t, i := 0, 0, 0
	it := doc_children(doc, n)
	for v in doc_child_next(&it) {
		if !resized && t == len(touched) {
			break
		}
		defer i += 1
		for p in inserts {
			if int(p.at) == i {
				region(r, Index(at), p.v)
				at += 1
			}
		}
		reached := t < len(touched) && touched[t] == v
		t += int(reached)
		switch {
		case reached && has(a.gone, v):
			continue
		case reached:
			append(&r.steps, Index(at))
			regions_of(r, v)
			pop(&r.steps)
		}
		at += 1
	}
	for p in inserts {
		if int(p.at) == i {
			region(r, Index(at), p.v)
			at += 1
		}
	}
	if resized {
		region(r, Index(at), nil, true)
	}
}

// The step of key `name`. An empty name an edit holds or a decode makes has no bytes, which a path refuses as an unset
// step, so it gets a data pointer.
@(private = "file")
name_step :: proc(name: string) -> Name {
	return Name(name) if raw_data(name) != nil else Name(string(NO_NAME[:0]))
}

@(private = "file", rodata)
NO_NAME := [1]u8{}

// Adds the regions of object `n` to `r`: the members `touched` names, each name a removal or a rename frees, and each
// of `inserts`. A name the object holds more than once among those the edits reach, as an insert of a name it holds
// does, is no path a read answers alone, but for the first element of the name in a markup object.
@(private = "file")
object_regions :: proc(r: ^Regions, n: Node_Index, touched: []Node_Index, inserts: []Applied_Insert) {
	a := r.a
	doc := a.doc
	names := make([dynamic]string, 0, len(touched) + len(inserts))
	for v in touched {
		append(&names, node_string(doc, v - 1))
	}
	for p in inserts {
		append(&names, p.key)
	}
	for name, i in names {
		held, first := int(i >= len(touched)), NO_NODE
		it := doc_pairs(doc, n)
		for k, v in doc_pair_next(&it) {
			if key_equals(doc, k, name) {
				held += 1
				first = v if first == NO_NODE else first
			}
		}
		if held > 1 && !(r.markup && first == touched[i]) {
			r.fits = false
			return
		}
	}
	start := len(r.out)
	for v, i in touched {
		name := names[i]
		renamed, is_renamed := entry_of(a.renames, v)
		switch {
		case has(a.gone, v) || is_renamed:
			region(r, name_step(name), nil, true)
			if is_renamed && !has(a.gone, v) {
				region(r, name_step(renamed.key), applied(a, v))
			}
		case:
			append(&r.steps, name_step(name))
			regions_of(r, v)
			pop(&r.steps)
		}
	}
	for p in inserts {
		region(r, name_step(p.key), p.v)
	}
	// A name freed and written again in one object holds what is written.
	for i := start; i < len(r.out); i += 1 {
		o := r.out[i]
		if !o.gone || len(o.path.steps) != len(r.steps) + 1 {
			continue
		}
		for w in r.out[start:] {
			if !w.gone && len(w.path.steps) == len(o.path.steps) && w.path.steps[len(w.path.steps) - 1] == o.path.steps[len(o.path.steps) - 1] {
				ordered_remove(&r.out, i)
				i -= 1
				break
			}
		}
	}
}
