package jq

import "base:runtime"
import "core:unicode/utf8"
import "stury:lib/query"

// jq's `_match_impl`, which the prelude's `match`, `test`, `capture`, `scan`, `splits`, `split/2`, `sub` and `gsub` are
// written over: Oniguruma's patterns as jq's flags set them, and `match`'s objects.

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
	found := make([]int, 2 * (query.regex_groups(re) + 1), h.allocator)
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

@(private = "file")
span :: proc(w: ^query.Code_Walk, s: string, lo, hi: int) -> (offset, length: int) {
	if lo < len(s) && lo < hi && s[lo] & 0xC0 == 0x80 {
		return 0, query.code_points_before(w, s, hi)
	}
	offset = query.code_points_before(w, s, lo)
	return offset, query.code_points_before(w, s, hi) - offset
}

@(private = "file")
span_text :: proc(h: ^query.Heap, s: string, lo, hi: int) -> (query.Value, query.Status) {
	inside :: #force_inline proc(s: string, at: int) -> bool { return at < len(s) && s[at] & 0xC0 == 0x80 }
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

@(private = "file")
match_object :: proc(h: ^query.Heap, re: ^query.Regex, s: string, found: []int, w: ^query.Code_Walk) -> (res: query.Value, status: query.Status) {
	o := query.make_object(h, 4) or_return
	defer if status != .Ok {
		query.release(h, o)
	}
	off, length := span(w, s, found[0], found[1])
	put(h, &o, "offset", query.int_value(i64(off))) or_return
	put(h, &o, "length", query.int_value(i64(length))) or_return
	put(h, &o, "string", span_text(h, s, found[0], found[1]) or_return) or_return
	caps := query.make_array(h, query.regex_groups(re)) or_return
	defer if status != .Ok {
		query.release(h, caps)
	}
	for g in 1 ..= query.regex_groups(re) {
		query.append_owned(h, &caps, capture_object(h, re, s, found, g, off, w) or_return) or_return
	}
	c := caps
	caps = query.ABSENT
	put(h, &o, "captures", c) or_return
	return o, .Ok
}

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

@(private = "file")
eval_sub_arg :: proc(m: ^Machine, expr: ^Node, input: query.Value, env: ^Env) -> (val: query.Value, owned, ok: bool) {
	if expr.kind == .Literal {
		return expr.value, false, true
	}
	v, found, st := eval_native(m, expr, query.retain(input), env)
	if st != .Ok || !found {
		query.release(m.h, v)
		return query.ABSENT, false, false
	}
	return v, true, true
}

// Fast native execution for prelude `sub`/`gsub` over text inputs with literal/native pattern and replacement.
@(private)
eval_sub_fast :: proc(m: ^Machine, r: ^Regs, fn: ^Func, n: ^Node) -> (ok: bool) {
	if r.track || m.steps >= 0 || m.track_origin || !query.is_text(r.input) {
		return false
	}
	is_gsub := fn.name == "gsub"
	if !is_gsub && fn.name != "sub" {
		return false
	}
	re_expr := n.args[0]
	has_flags := len(n.args) == 3
	flags_expr := n.args[2] if has_flags else nil
	if re_expr == nil || (re_expr.kind != .Literal && .Native not_in re_expr.flags) {
		return false
	}
	if has_flags && (flags_expr == nil || (flags_expr.kind != .Literal && .Native not_in flags_expr.flags)) {
		return false
	}
	rep_node, rep_env := closure_target(n.args[1], r.env)
	if rep_node == nil {
		return false
	}
	rep_is_lit := rep_node.kind == .Literal
	if (rep_is_lit && rep_node.value.kind != .String) || (!rep_is_lit && (.Native not_in rep_node.flags || node_uses_regex(rep_node))) {
		return false
	}

	h := m.h
	defer if !ok && !h.tainted {
		query.clear_error(h)
	}
	re_val, re_owned, re_ok := eval_sub_arg(m, re_expr, r.input, r.env)
	defer if re_owned {
		query.release(h, re_val)
	}
	if !re_ok || !query.is_text(re_val) {
		return false
	}

	opts: query.Regex_Flags
	global := is_gsub
	if has_flags {
		fl_val, fl_owned, fl_ok := eval_sub_arg(m, flags_expr, r.input, r.env)
		defer if fl_owned {
			query.release(h, fl_val)
		}
		if !fl_ok {
			return false
		}
		fopts, fglob, fst := regex_flags(m, fl_val)
		if fst != .Ok {
			return false
		}
		opts, global = fopts, true if is_gsub else fglob
	}

	re, rerr := query.regex_compile(h, &m.regexes, re_val, .Oniguruma, opts)
	if rerr != .Ok {
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
	defer delete(found_heap, h.allocator)

	is_rune_bound :: #force_inline proc "contextless" (s: string, at: int) -> bool #no_bounds_check {
		return at <= len(s) && (at == len(s) || s[at] & 0xC0 != 0x80)
	}

	sb: [dynamic]u8
	defer delete(sb)
	cap_obj := query.ABSENT
	defer query.release(h, cap_obj)
	cap_ready, utf8_checked := false, false
	named_groups := 0
	if !rep_is_lit {
		for g in 1 ..= groups {
			named_groups += int(query.regex_group_name(re, g) != "")
		}
	}
	lit_rep := query.text_of(rep_node.value) if rep_is_lit else ""

	prev, at := 0, 0
	matched_any := false
	for at <= len(s) {
		hit, hs := query.regex_search(h, &m.regexes, re, s, at, found)
		if hs != .Ok {
			return false
		}
		if !hit {
			break
		}
		if !utf8_checked {
			utf8_checked = true
			for c in transmute([]u8)s {
				if c >= 0x80 {
					if !utf8.valid_string(s) {
						return false
					}
					break
				}
			}
			sberr: runtime.Allocator_Error
			sb, sberr = make([dynamic]u8, 0, len(s) + 16, h.allocator)
			if sberr != nil {
				return false
			}
		}
		if !is_rune_bound(s, found[0]) || !is_rune_bound(s, found[1]) {
			return false
		}
		matched_any = true
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
					return false
				}
			}
			if named_groups > 0 {
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
						} else if !is_rune_bound(s, lo) || !is_rune_bound(s, hi) {
							return false
						} else {
							val = query.text_borrowed(s[lo:hi])
						}
					}
					k := query.text_borrowed(gname)
					if !cap_ready {
						ks: query.Status
						k, ks = query.text_value(h, gname)
						if ks != .Ok {
							return false
						}
					}
					if query.object_put(h, &cap_obj, k, val) != .Ok {
						return false
					}
				}
				cap_ready = true
			}
			rep, rep_found, rep_st := eval_native(m, rep_node, query.retain(cap_obj), rep_env)
			defer query.release(h, rep)
			if rep_st != .Ok || !rep_found || query.type_of(rep) != .String {
				return false
			}
			if rt := query.text_of(rep); len(rt) > 0 {
				if _, aerr := append(&sb, rt); aerr != nil {
					return false
				}
			}
		}
		prev = found[1]
		if !global {
			break
		}
		at = found[1] if found[1] > found[0] else found[1] + 1
	}

	if !matched_any {
		out := r.input
		r.input = query.ABSENT
		give(m, r, out)
		return true
	}
	if prev < len(s) {
		if _, aerr := append(&sb, s[prev:]); aerr != nil {
			return false
		}
	}
	out, os := query.text_value(h, string(sb[:]))
	if os != .Ok {
		return false
	}
	give(m, r, out)
	return true
}
