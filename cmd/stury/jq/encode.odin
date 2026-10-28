package jq

// Values printed as jq 1.8 prints them, through the library's `json.Writer` in jq's spelling: its number formats,
// its string escapes, its layout and its colours.

import "core:bytes"
import core_pkg "../../../core"
import json "../../../json"

// How values are printed: the library's writer, whose `out`, `depth` and `jq_spelling` each print sets (`bind`), and
// whose `src` is the source of a JSONC value whose comments `write_answer` prints at their attachment points, nil for
// none; and what the writer does not do.
Layout :: struct {
	using writer:  json.Writer,
	sort_keys:     bool,
	drop_comments: bool, // `write_answer` prints no comments even when the value has some (output other than JSONC)
	spill:         ^Spill, // receives the output once it reaches `at` bytes, so a deep value is not held whole; nil for none
}

// A layout's way to empty the output it is written into, the dynamic array `write_value` is given.
Spill :: struct {
	at:    int,
	flush: proc(data: rawptr),
	data:  rawptr,
}

// The output written so far, spilled when the layout has a place for it and it has passed its size.
@(private = "file")
spill :: #force_inline proc(l: ^Layout) {
	if l.spill != nil && len(l.out) >= l.spill.at {
		l.spill.flush(l.spill.data)
	}
}

// Points the writer of `l` at `out`, `depth` levels in, in jq's spelling.
@(private = "file")
bind :: #force_inline proc(l: ^Layout, out: ^[dynamic]byte, depth: int) {
	l.out, l.depth, l.jq_spelling = out, depth, true
}

// `v` laid out `depth` levels in. In colour, as jq's jv_dump_term paints it: each value in its kind's colour, reset
// after. A container's punctuation in its colour, reset before each member, and an object's keys in theirs. A NaN is
// a number painting a null.
write_value :: proc(out: ^[dynamic]byte, v: Value, l: Layout, depth := 0) {
	l := l
	bind(&l, out, depth)
	emit(&l, v)
}

@(private = "file")
emit :: proc(l: ^Layout, v: Value) {
	w := &l.writer
	k := kind(v)
	switch {
	case w.depth > MAX_DEPTH:
		json.write_token(w, k, "<skipped: too deep>") // what jq prints past its depth limit
	case k == .Null:
		json.write_token(w, .Null, "null")
	case k == .False:
		json.write_token(w, .False, "false")
	case k == .True:
		json.write_token(w, .True, "true")
	case k == .Number:
		if r, is_ref := v.(Ref); is_ref && r.doc.rows[r.node].first_esc != core_pkg.SPELLED_NUMBER {
			json.write_number(w, string(core_pkg.get_raw(r.doc, r.node)))
			break
		}
		n, _ := number_of(v)
		if n.lit != "" {
			json.write_number(w, n.lit)
		} else {
			json.write_float(w, n.f)
		}
	case k == .String:
		s, _ := string_of(v)
		put_string(w, s)
	case is_empty(v):
		json.write_open(w, k)
		json.write_close(w, k, 0, nil, comments_of(v, l))
	case k == .Array:
		json.write_open(w, .Array)
		it := iterate(v)
		i := 0
		last: []json.Fact // the member written last's comments, whose trailing ones follow its comma
		for _, m in next_member(&it) {
			spill(l)
			own := comments_of(m, l)
			json.write_element(w, .Array, i, last, own)
			emit(l, m)
			last = own
			i += 1
		}
		spill(l)
		json.write_close(w, .Array, i, last, comments_of(v, l))
	case:
		json.write_open(w, .Object)
		i := 0
		last: []json.Fact
		if l.sort_keys && is_wide(v) {
			for m in sorted_members(v) {
				emit_member(l, m.key, m.val, &i, &last)
			}
		} else if l.sort_keys {
			for key in sorted_keys(v) {
				m, _ := object_get(v, key)
				emit_member(l, key, m, &i, &last)
			}
		} else {
			it := iterate(v)
			for key, m in next_member(&it) {
				emit_member(l, key, m, &i, &last)
			}
		}
		spill(l)
		json.write_close(w, .Object, i, last, comments_of(v, l))
	}
}

// Member `i` of the object open innermost: key `k`, value `m`. `last` holds the comments of the member before, then
// of this one.
@(private = "file")
emit_member :: proc(l: ^Layout, k: string, m: Value, i: ^int, last: ^[]json.Fact) {
	w := &l.writer
	spill(l)
	own := comments_of(m, l)
	json.write_element(w, .Object, i^, last^, own)
	if json.write_key(w, k, own) == .Bad_Utf8 {
		json.write_key(w, valid_utf8(k), own)
	}
	emit(l, m)
	last^ = own
	i^ += 1
}

// `s` as jq prints a string. A jq string is UTF-8, as jq makes each string it reads or builds. One that is not
// prints as `valid_utf8` makes it.
@(private = "file")
put_string :: #force_inline proc(w: ^json.Writer, s: string) {
	if json.write_string(w, s) == .Bad_Utf8 {
		json.write_string(w, valid_utf8(s))
	}
}

// The punctuation `c` of a container of kind `k`, painted in its colour when the layout has colours.
write_punct :: proc(out: ^[dynamic]byte, l: Layout, k: Kind, c: byte) {
	l := l
	bind(&l, out, 0)
	text := [1]byte{c}
	json.write_token(&l.writer, k, string(text[:]))
}

// The entries of array `v`, `depth` levels in, as `write_value` lays them out after the line break that
// follows its `[`.
write_items :: proc(out: ^[dynamic]byte, v: Value, l: Layout, depth: int) {
	l := l
	bind(&l, out, depth + 1)
	it := iterate(v)
	i := 0
	last: []json.Fact
	for _, m in next_member(&it) {
		spill(&l)
		own := comments_of(m, &l)
		if i == 0 {
			json.write_comments(&l.writer, own, .Lead)
		} else {
			json.write_element(&l.writer, .Array, i, last, own)
		}
		emit(&l, m)
		last = own
		i += 1
	}
	json.write_comments(&l.writer, last, .Trail)
}

// `v` as `write_value` prints it. A string or container read from JSON text that is already in jq's format is copied,
// or laid out, from that text rather than walked. A value of a JSONC document with comments is printed with each
// comment attached to it or to a value in it, as `json.marshal` places them. A value the filter made has none. A
// caller whose `write_spelled` just refused the text passes no `respell`. The writer of `l` is pointed at `out`.
write_answer :: proc(out: ^[dynamic]byte, v: Value, l: ^Layout, respell := true) {
	bind(l, out, 0)
	r, is_ref := v.(Ref)
	// Only a JSONC document has facts.
	if is_ref && !l.drop_comments && len(r.doc.facts) > 0 {
		own := facts_of(r)
		kd, _ := core_pkg.kind(r.doc, r.node)
		if len(own) > 0 || kd >= .Array {
			l.src = r.doc.src
			json.write_comments(&l.writer, own, .Lead, root = true)
			emit(l, v)
			json.write_comments(&l.writer, own, .Trail, root = true)
			l.src = nil
			return
		}
	}
	if !is_ref || l.ascii || l.sort_keys || l.colors != nil {
		emit(l, v)
		return
	}
	text := core_pkg.get_raw(r.doc, r.node)
	switch kd, _ := core_pkg.kind(r.doc, r.node); kd {
	case .String:
		// A dialect with its own spelling writes a string unlike JSON's even where it holds no backslash.
		if !escaped(text) && !json.own_spelling(r.doc) {
			append(out, ..text)
			return
		}
	case .Object, .Array:
		if respell && json.plain_json(r.doc) && json.write_raw(&l.writer, text, unique = r.doc.distinct_keys) {
			return
		}
	case .Null, .False, .True, .Number:
	}
	emit(l, v)
}

// The well-formed JSON text of an array or object laid out onto `out` as `write_value` lays out the value it reads
// as, when that is its own format with only the whitespace changed (`json.write_raw`), else false with `out` as it
// was, always so for a layout with colours. With `items`, `text` is the entries of an array at `depth`, without its
// brackets, laid out as that array lays them out. With `unique`, no object repeats a key.
write_spelled :: proc(out: ^[dynamic]byte, text: []byte, l: Layout, depth := 0, items := false, unique := false) -> bool {
	l := l
	bind(&l, out, depth)
	return json.write_raw(&l.writer, text, items, unique)
}

// Whether `text` has an escape or a DEL, which jq may write differently. One without them is copied as it is.
escaped :: proc(text: []byte) -> bool {
	return bytes.index_byte(text, '\\') >= 0 || bytes.index_byte(text, 0x7f) >= 0
}

// The comments attached to a value of a JSONC document, spans of `l.src`. It is none for any other value, or
// when the layout prints none.
@(private = "file")
comments_of :: proc(v: Value, l: ^Layout) -> []json.Fact {
	r, is_ref := v.(Ref)
	if len(l.src) == 0 || !is_ref {
		return nil
	}
	return facts_of(r)
}

// Where the last `facts_of` ended. Outputs mostly come in source order, so this is only a hint, checked before use.
@(private = "file", thread_local)
facts_hint: int

// `core_pkg.facts` of `r`, found from `facts_hint` on by doubling steps, then halving.
facts_of :: proc(r: Ref) -> []json.Fact {
	all := r.doc.facts[:]
	n := r.node
	lo := facts_hint
	if lo > len(all) || lo > 0 && all[lo - 1].node >= n {
		lo = 0
	}
	// all[lo - 1] is before n's facts, so the first of them is at lo or after.
	for step := 1; lo < len(all) && all[lo].node < n; step *= 2 {
		next := lo + step
		if next < len(all) && all[next].node < n {
			lo = next
			continue
		}
		hi := min(next, len(all))
		lo += 1
		for lo < hi {
			mid := lo + (hi - lo) / 2
			if all[mid].node < n {
				lo = mid + 1
			} else {
				hi = mid
			}
		}
		break
	}
	hi := lo
	for hi < len(all) && all[hi].node == n {
		hi += 1
	}
	facts_hint = hi
	return all[lo:hi]
}

// The line break before a member `depth` levels in: none when compact.
newline :: proc(out: ^[dynamic]byte, l: Layout, depth: int) {
	l := l
	bind(&l, out, depth)
	json.write_newline(&l.writer)
}

// `s` as jq prints a string: JSON's escapes and DEL's, and with `ascii` every character past U+007F as `\u` escapes.
write_string :: proc(out: ^[dynamic]byte, s: string, ascii := false) {
	w := json.Writer{out = out, ascii = ascii, jq_spelling = true}
	put_string(&w, s)
}

write_led_cell :: json.write_led_string

// The text `tostring` and string interpolation give a value: a string as itself, anything else as
// compact JSON.
text_of :: proc(v: Value) -> string {
	if s, is_str := string_of(v); is_str {
		return s
	}
	return to_json(v)
}

to_json :: proc(v: Value) -> string {
	out := make([dynamic]byte)
	write_value(&out, v, {})
	return string(out[:])
}
