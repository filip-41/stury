package jq

import "base:runtime"
import "core:unicode/utf8"
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
			return {}, false, raise_joined(m, text, " is not a valid modifier string")
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
		fixed := valid_utf8(text, h.allocator)
		defer delete(fixed, h.allocator)
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
	defer if status != .Ok {
		query.release(h, caps)
	}
	for g in 1 ..= query.regex_groups(re) {
		c := capture_object(h, re, s, found, g, off, w) or_return
		query.append_owned(h, &caps, c) or_return
	}
	c := caps
	caps = query.ABSENT
	put(h, &o, "captures", c) or_return
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

@(private = "file")
node_uses_regex :: proc "contextless" (root: ^Node) -> bool {
	if root == nil {
		return false
	}
	stack: [64]^Node
	sp := 1
	stack[0] = root
	for sp > 0 {
		sp -= 1
		cur := stack[sp]
		if cur.kind == .Call && ((cur.builtin != nil && cur.builtin.fn == v_match_impl) || cur.ref.kind == .Def) {
			return true
		}
		for i in 0 ..< child_count(cur) {
			if c := child(cur, i); c != nil {
				if sp >= len(stack) {
					return true
				}
				stack[sp] = c
				sp += 1
			}
		}
	}
	return false
}

// Fast native execution for prelude `sub`/`gsub` over text inputs with literal/native pattern,
// optional literal/native flags, and literal or native single-output replacement expressions.
// Avoids allocating match/capture arrays per match and `reduce`/`range` VM continuations.
@(private)
eval_sub_fast :: proc(m: ^Machine, r: ^Regs, fn: ^Func, n: ^Node) -> bool {
	if r.track || m.steps >= 0 || m.track_origin {
		return false
	}
	if !query.is_text(r.input) {
		return false
	}
	is_gsub := fn.name == "gsub"
	if !is_gsub && fn.name != "sub" {
		return false
	}
	re_expr := n.args[0]
	if re_expr == nil || (re_expr.kind != .Literal && .Native not_in re_expr.flags) {
		return false
	}
	has_flags_arg := len(n.args) == 3
	flags_expr := n.args[2] if has_flags_arg else nil
	if has_flags_arg && (flags_expr == nil || (flags_expr.kind != .Literal && .Native not_in flags_expr.flags)) {
		return false
	}
	rep_node, rep_env := closure_target(n.args[1], r.env)
	if rep_node == nil {
		return false
	}
	rep_is_lit := rep_node.kind == .Literal
	if rep_is_lit {
		if rep_node.value.kind != .String {
			return false
		}
	} else if .Native not_in rep_node.flags || node_uses_regex(rep_node) {
		return false
	}

	h := m.h
	re_val := query.ABSENT
	re_owned := false
	if re_expr.kind == .Literal {
		re_val = re_expr.value
	} else {
		rf: bool
		rs: query.Status
		re_val, rf, rs = eval_native(m, re_expr, query.retain(r.input), r.env)
		re_owned = true
		if rs != .Ok || !rf {
			query.release(h, re_val)
			if !h.tainted {
				query.clear_error(h)
			}
			return false
		}
	}
	defer if re_owned {
		query.release(h, re_val)
	}
	if !query.is_text(re_val) {
		return false
	}

	opts := query.Regex_Flags{}
	global := is_gsub
	if has_flags_arg {
		fl_val := query.ABSENT
		fl_owned := false
		if flags_expr.kind == .Literal {
			fl_val = flags_expr.value
		} else {
			ff: bool
			fs: query.Status
			fl_val, ff, fs = eval_native(m, flags_expr, query.retain(r.input), r.env)
			fl_owned = true
			if fs != .Ok || !ff {
				query.release(h, fl_val)
				if !h.tainted {
					query.clear_error(h)
				}
				return false
			}
		}
		fopts, fglob, fst := regex_flags(m, fl_val)
		if fl_owned {
			query.release(h, fl_val)
		}
		if fst != .Ok {
			if !h.tainted {
				query.clear_error(h)
			}
			return false
		}
		opts = fopts
		global = true if is_gsub else fglob
	}

	re, rerr := query.regex_compile(h, &m.regexes, re_val, .Oniguruma, opts)
	if rerr != .Ok {
		if !h.tainted {
			query.clear_error(h)
		}
		return false
	}

	s := query.text_of(r.input)
	groups := query.regex_groups(re)
	width := 2 * (groups + 1)
	found_stack: [32]int
	found_heap: []int
	found: []int
	if width <= len(found_stack) {
		found = found_stack[:width]
	} else {
		aerr: runtime.Allocator_Error
		found_heap, aerr = make([]int, width, h.allocator)
		if aerr != nil {
			return false
		}
		found = found_heap
	}
	defer if len(found_heap) > 0 {
		delete(found_heap, h.allocator)
	}

	hit, hs := query.regex_search(h, &m.regexes, re, s, 0, found)
	if hs != .Ok {
		if !h.tainted {
			query.clear_error(h)
		}
		return false
	}
	if !hit {
		out := r.input
		r.input = query.ABSENT
		give(m, r, out)
		return true
	}

	is_ascii := true
	for c in transmute([]u8)s {
		if c >= 0x80 {
			is_ascii = false
			break
		}
	}
	if !is_ascii && !utf8.valid_string(s) {
		return false
	}

	is_rune_bound :: #force_inline proc "contextless" (s: string, at: int) -> bool #no_bounds_check {
		return at <= len(s) && (at == len(s) || s[at] & 0xC0 != 0x80)
	}
	if !is_rune_bound(s, found[0]) || !is_rune_bound(s, found[1]) {
		return false
	}

	lit_rep := query.text_of(rep_node.value) if rep_is_lit else ""
	sb, sberr := make([dynamic]u8, 0, len(s) + 16, h.allocator)
	if sberr != nil {
		return false
	}
	defer delete(sb)

	cap_obj := query.ABSENT
	defer query.release(h, cap_obj)
	cap_ready := false
	named_groups := 0
	if !rep_is_lit {
		for g in 1 ..= groups {
			if query.regex_group_name(re, g) != "" {
				named_groups += 1
			}
		}
	}

	prev := 0
	for {
		if found[0] > prev {
			if _, aerr := append(&sb, s[prev:found[0]]); aerr != nil {
				return false
			}
		}
		if rep_is_lit {
			if len(lit_rep) > 0 {
				if _, aerr := append(&sb, lit_rep); aerr != nil {
					return false
				}
			}
		} else {
			if cap_obj.kind == .Absent || !query.unique(cap_obj) {
				query.release(h, cap_obj)
				cap_ready = false
				cs: query.Status
				cap_obj, cs = query.make_object(h, named_groups)
				if cs != .Ok {
					query.clear_error(h)
					return false
				}
			}
			if named_groups > 0 {
				need_owned_keys := !cap_ready
				for g in 1 ..= groups {
					gname := query.regex_group_name(re, g)
					if gname == "" {
						continue
					}
					lo, hi := found[2 * g], found[2 * g + 1]
					val := query.NULL
					if lo >= 0 {
						if lo == hi || found[0] == found[1] {
							val = query.text_borrowed("")
						} else {
							if !is_rune_bound(s, lo) || !is_rune_bound(s, hi) {
								return false
							}
							val = query.text_borrowed(s[lo:hi])
						}
					}
					k: query.Value
					if need_owned_keys {
						ks: query.Status
						k, ks = query.text_value(h, gname)
						if ks != .Ok {
							query.clear_error(h)
							return false
						}
					} else {
						k = query.text_borrowed(gname)
					}
					if ps := query.object_put(h, &cap_obj, k, val); ps != .Ok {
						query.clear_error(h)
						return false
					}
				}
				cap_ready = true
			}
			rep, rep_found, rep_st := eval_native(m, rep_node, query.retain(cap_obj), rep_env)
			if rep_st != .Ok || !rep_found || query.type_of(rep) != .String {
				query.release(h, rep)
				if !h.tainted {
					query.clear_error(h)
				}
				return false
			}
			rt := query.text_of(rep)
			if len(rt) > 0 {
				if _, aerr := append(&sb, rt); aerr != nil {
					query.release(h, rep)
					return false
				}
			}
			query.release(h, rep)
		}

		prev = found[1]
		if !global {
			break
		}
		at := found[1] if found[1] > found[0] else found[1] + 1
		if at > len(s) {
			break
		}
		nhit, nhs := query.regex_search(h, &m.regexes, re, s, at, found)
		if nhs != .Ok {
			if !h.tainted {
				query.clear_error(h)
			}
			return false
		}
		if !nhit {
			break
		}
		if !is_rune_bound(s, found[0]) || !is_rune_bound(s, found[1]) {
			return false
		}
	}

	if prev < len(s) {
		if _, aerr := append(&sb, s[prev:]); aerr != nil {
			return false
		}
	}
	out, os := query.text_value(h, string(sb[:]))
	if os != .Ok {
		if !h.tainted {
			query.clear_error(h)
		}
		return false
	}
	give(m, r, out)
	return true
}
