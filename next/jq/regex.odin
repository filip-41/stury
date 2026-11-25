package jq

import "core:strings"
import "stury:lib/query"

// jq's `_match_impl`, which the prelude's `match`, `test`, `capture`, `scan`, `splits`, `split/2`, `sub` and `gsub` are
// written over: Oniguruma's patterns as jq's flags set them, and `match`'s objects. Offsets and lengths count code
// points as jq 1.8.2 counts them, which a global search makes odd: after an empty match it goes on one byte later,
// which may be inside a character.

// The patterns and flags of `flags`, a string of `g i x n s l p m`, or null for none.
@(private = "file")
regex_flags :: proc(m: ^Machine, flags: query.Value) -> (opts: query.Regex_Flags, global: bool, status: query.Status) {
	if query.type_of(flags) == .Null || flags.kind == .Absent {
		return {}, false, .Ok
	}
	if !query.is_text(flags) {
		return {}, false, raise_typed(m, flags, " is not a string")
	}
	text := query.text_of(flags)
	for c in transmute([]u8)text {
		switch c {
		case 'g':
			global = true
		case 'i':
			opts.fold = true
		case 'x':
			opts.extend = true
		case 'n':
			opts.not_empty = true
		case 'p', 'm':
			opts.dotall = true
		case 'l':
			opts.longest = true
		case 's':
		case:
			return {}, false, raise_owned_text(m, strings.concatenate({text, " is not a valid modifier string"}, context.temp_allocator))
		}
	}
	return opts, global, .Ok
}

@(private)
v_match_impl :: proc(m: ^Machine, b: ^Builtin, x: query.Value, args: []query.Value) -> (res: query.Value, status: query.Status) {
	h := m.h
	if !query.is_text(x) {
		return query.NULL, raise_typed(m, x, " cannot be matched, as it is not a string")
	}
	if !query.is_text(args[0]) {
		return query.NULL, raise_typed(m, args[0], " is not a string")
	}
	opts, global := regex_flags(m, args[1]) or_return
	re := query.regex_compile(h, &m.regexes, args[0], .Oniguruma, opts) or_return
	s := query.text_of(x)
	if args[2].kind == .True {
		hit := query.regex_search(h, &m.regexes, re, s, 0, nil) or_return
		return query.bool_value(hit), .Ok
	}
	groups := query.regex_groups(re)
	width := 2 * (groups + 1)
	found := make([]int, width, h.allocator)
	defer delete(found, h.allocator)
	out := query.make_array(h, 1) or_return
	defer if status != .Ok {
		query.release(h, out)
	}
	walk: query.Code_Walk
	for at := 0; at <= len(s); {
		hit := query.regex_search(h, &m.regexes, re, s, at, found) or_return
		if !hit {
			break
		}
		query.append_owned(h, &out, match_object(h, re, s, found, &walk) or_return) or_return
		if !global {
			break
		}
		at = found[1] if found[1] > found[0] else found[1] + 1
	}
	return out, .Ok
}

// The offset and length jq gives the bytes lo..hi of a match or group. jq walks the string a code point at a time from
// its start and counts. A bound inside a character is never met, so such a span has offset 0 and counts its length
// from the start.
@(private = "file")
span :: proc(w: ^query.Code_Walk, s: string, lo, hi: int) -> (offset, length: int) {
	if lo < len(s) && lo < hi && s[lo] & 0xC0 == 0x80 {
		return 0, query.code_points_before(w, s, hi)
	}
	offset = query.code_points_before(w, s, lo)
	return offset, query.code_points_before(w, s, hi) - offset
}

// The bytes lo..hi as jq makes a string of them: a bound inside a character leaves bytes no UTF-8 holds alone, each
// run of which is one U+FFFD.
@(private = "file")
span_text :: proc(h: ^query.Heap, s: string, lo, hi: int) -> (res: query.Value, status: query.Status) {
	inside :: #force_inline proc(s: string, at: int) -> bool {
		return at < len(s) && s[at] & 0xC0 == 0x80
	}
	text := s[lo:hi]
	if inside(s, lo) || inside(s, hi) {
		fixed := valid_utf8(text)
		defer delete(fixed)
		return query.text_value(h, fixed)
	}
	return query.text_value(h, text)
}

@(private = "file")
put :: proc(h: ^query.Heap, o: ^query.Value, key: string, x: query.Value) -> query.Status {
	return query.object_put(h, o, query.text_borrowed(key), x)
}

// A match as jq's object: `offset`, `length`, `string`, `captures`. In an empty match, jq gives every group that took
// part the match's offset and no text.
@(private = "file")
match_object :: proc(h: ^query.Heap, re: ^query.Regex, s: string, found: []int, w: ^query.Code_Walk) -> (res: query.Value, status: query.Status) {
	o := query.make_object(h, 4) or_return
	defer if status != .Ok {
		query.release(h, o)
	}
	off, length := span(w, s, found[0], found[1])
	put(h, &o, "offset", query.int_value(i64(off))) or_return
	put(h, &o, "length", query.int_value(i64(length))) or_return
	text := span_text(h, s, found[0], found[1]) or_return
	put(h, &o, "string", text) or_return
	caps := query.make_array(h, query.regex_groups(re)) or_return
	for g in 1 ..= query.regex_groups(re) {
		c := capture_object(h, re, s, found, g, off, w) or_return
		if query.append_owned(h, &caps, c) != .Ok {
			query.release(h, caps)
			return query.NULL, .Error
		}
	}
	put(h, &o, "captures", caps) or_return
	return o, .Ok
}

// One group of a match, as jq's object: `offset`, `length`, `string`, `name`, whose key order jq changes for a group
// that took no part or an empty one.
@(private = "file")
capture_object :: proc(h: ^query.Heap, re: ^query.Regex, s: string, found: []int, g, match_offset: int, w: ^query.Code_Walk) -> (res: query.Value, status: query.Status) {
	c := query.make_object(h, 4) or_return
	defer if status != .Ok {
		query.release(h, c)
	}
	lo, hi := found[2 * g], found[2 * g + 1]
	switch {
	case lo < 0:
		put(h, &c, "offset", query.int_value(-1)) or_return
		put(h, &c, "string", query.NULL) or_return
		put(h, &c, "length", query.int_value(0)) or_return
	case lo == hi || found[0] == found[1]:
		at := match_offset if found[0] == found[1] else query.code_points_before(w, s, lo)
		put(h, &c, "offset", query.int_value(i64(at))) or_return
		put(h, &c, "string", query.text_borrowed("")) or_return
		put(h, &c, "length", query.int_value(0)) or_return
	case:
		at, n := span(w, s, lo, hi)
		put(h, &c, "offset", query.int_value(i64(at))) or_return
		put(h, &c, "length", query.int_value(i64(n))) or_return
		put(h, &c, "string", span_text(h, s, lo, hi) or_return) or_return
	}
	name := query.NULL
	if n := query.regex_group_name(re, g); n != "" {
		name = query.text_value(h, n) or_return
	}
	put(h, &c, "name", name) or_return
	return c, .Ok
}
