package jq

import "base:runtime"
import "core:math"
import "core:strings"
import "stury:lib/core/tape"
import "stury:lib/query"

// The value builtins: each takes its input and its arguments' values and gives one value, through the engine's
// operations, with jq's checks and messages.

@(private)
v_not :: proc(m: ^Machine, b: ^Builtin, x: query.Value, args: []query.Value) -> (res: query.Value, status: query.Status) {
	return query.bool_value(!truthy(x)), .Ok
}

@(private)
v_type :: proc(m: ^Machine, b: ^Builtin, x: query.Value, args: []query.Value) -> (res: query.Value, status: query.Status) {
	return query.text_borrowed(type_name(x)), .Ok
}

// jq's `reduce .[] as $x (null; . + $x)`, the sum held once so `+` extends it in place.
@(private)
v_add :: proc(m: ^Machine, b: ^Builtin, x: query.Value, args: []query.Value) -> (res: query.Value, status: query.Status) {
	h := m.h
	if t := query.type_of(x); t != .Array && t != .Object {
		return query.NULL, query.fail(h, .Types, .Iterate, x)
	}
	c := query.cursor_open(h, x) or_return
	defer query.cursor_close(&c)
	acc := query.NULL
	for {
		if m.steps >= 0 {
			if m.steps == 0 {
				query.release(h, acc)
				return query.NULL, fail_budget(m)
			}
			m.steps -= 1
		}
		key, v, more, s := query.cursor_next(h, &c)
		query.release(h, key)
		if s != .Ok || !more {
			if s != .Ok {
				query.release(h, acc)
			}
			return acc, s
		}
		if acc.kind == .Int && v.kind == .Int {
			if sum, ok := int_binary(.Add, acc.i, v.i); ok {
				acc = sum
				continue
			}
		}
		acc, s = binary_owned(h, .Add, acc, v)
		query.release(h, v)
		if s != .Ok {
			return query.NULL, s
		}
	}
}

@(private)
v_length :: proc(m: ^Machine, b: ^Builtin, x: query.Value, args: []query.Value) -> (res: query.Value, status: query.Status) {
	h := m.h
	switch query.type_of(x) {
	case .Absent, .Null:
		return query.int_value(0), .Ok
	case .False, .True:
		return query.NULL, raise_typed(m, x, " has no length")
	case .Number:
		if query.compare_numbers(x, query.int_value(0)) < 0 {
			return query.num_neg(h, x)
		}
		return query.retain(x), .Ok
	case .String:
		return query.int_value(i64(query.codepoint_count(query.text_of(x)))), .Ok
	case .Array, .Object:
		return query.int_value(i64(query.length_of(h, x))), .Ok
	}
	return query.NULL, .Ok
}

@(private)
v_utf8bytelength :: proc(m: ^Machine, b: ^Builtin, x: query.Value, args: []query.Value) -> (res: query.Value, status: query.Status) {
	if !query.is_text(x) {
		return query.NULL, raise_typed(m, x, " only strings have UTF-8 byte length")
	}
	return query.int_value(i64(len(query.text_of(x)))), .Ok
}

@(private)
v_keys :: proc(m: ^Machine, b: ^Builtin, x: query.Value, args: []query.Value) -> (res: query.Value, status: query.Status) {
	t := query.type_of(x)
	if t != .Array && t != .Object {
		return query.NULL, raise_typed(m, x, " has no keys")
	}
	return query.keys_of(m.h, x, b.name == "keys")
}

@(private)
v_has :: proc(m: ^Machine, b: ^Builtin, x: query.Value, args: []query.Value) -> (res: query.Value, status: query.Status) {
	t, k := query.type_of(x), query.type_of(args[0])
	switch {
	case t == .Object && k == .String:
		return query.bool_value(query.has_member(m.h, x, query.text_of(args[0]))), .Ok
	case t == .Array && k == .Number:
		f := query.as_f64(args[0])
		return query.bool_value(f >= 0 && f < f64(query.length_of(m.h, x))), .Ok
	case t == .Null:
		return query.FALSE, .Ok
	}
	out := make([dynamic]u8, m.h.allocator)
	defer delete(out)
	append(&out, "Cannot check whether ")
	append(&out, type_name(x))
	append(&out, " has a ")
	append(&out, type_name(args[0]))
	append(&out, " key")
	return query.NULL, raise_owned_text(m, string(out[:]))
}

@(private)
v_contains :: proc(m: ^Machine, b: ^Builtin, x: query.Value, args: []query.Value) -> (res: query.Value, status: query.Status) {
	ok := query.contains(m.h, x, args[0]) or_return
	return query.bool_value(ok), .Ok
}

@(private)
v_tostring :: proc(m: ^Machine, b: ^Builtin, x: query.Value, args: []query.Value) -> (res: query.Value, status: query.Status) {
	return to_text(m.h, x)
}

@(private)
v_tojson :: proc(m: ^Machine, b: ^Builtin, x: query.Value, args: []query.Value) -> (res: query.Value, status: query.Status) {
	return to_json(m.h, x)
}

@(private)
v_format :: proc(m: ^Machine, b: ^Builtin, x: query.Value, args: []query.Value) -> (res: query.Value, status: query.Status) {
	if !query.is_text(args[0]) {
		return query.NULL, raise_typed(m, args[0], " is not a valid format")
	}
	return format_value(m, query.text_of(args[0]), x)
}

@(private)
v_tonumber :: proc(m: ^Machine, b: ^Builtin, x: query.Value, args: []query.Value) -> (res: query.Value, status: query.Status) {
	h := m.h
	#partial switch query.type_of(x) {
	case .Number:
		return query.number_of(h, x)
	case .String:
		s := query.text_of(x)
		if number_text(s) || named_number(s) {
			v, ok := query.parse_number(h, s, true) or_return
			if ok {
				return v, .Ok
			}
		}
	}
	return query.NULL, raise_typed(m, x, " cannot be parsed as a number")
}

// Whether `s` is `nan`, `inf` or `infinity` in any case, with a sign or none: the numbers jq's `tonumber` reads by name.
@(private)
named_number :: proc(s: string) -> bool {
	name := s[1:] if len(s) > 0 && (s[0] == '+' || s[0] == '-') else s
	return strings.equal_fold(name, "nan") || strings.equal_fold(name, "inf") || strings.equal_fold(name, "infinity")
}

// Whether `s` is spelled as jq's `tonumber` reads a number: a sign, digits with a point, an exponent, no space.
@(private)
number_text :: proc(s: string) -> bool {
	digits := false
	for c, i in transmute([]u8)s {
		switch c {
		case '0' ..= '9':
			digits = true
		case '+', '-':
			if i > 0 && s[i - 1] != 'e' && s[i - 1] != 'E' {
				return false
			}
		case '.', 'e', 'E':
		case:
			return false
		}
	}
	return digits
}

// `fromjson`: the text read as one RFC 8259 JSON value.
@(private)
v_fromjson :: proc(m: ^Machine, b: ^Builtin, x: query.Value, args: []query.Value) -> (res: query.Value, status: query.Status) {
	if !query.is_text(x) {
		return query.NULL, raise_typed(m, x, " only strings can be parsed")
	}
	return read_json(m, query.text_of(x))
}

// The one JSON value of text `s`, copied into a document the value holds.
@(private)
read_json :: proc(m: ^Machine, s: string) -> (res: query.Value, status: query.Status) {
	h := m.h
	if m.hooks == nil || m.hooks.parse_json == nil {
		return query.NULL, raise_text(m, "fromjson is not available")
	}
	alloc := query.heap_allocator(h)
	src, serr := make([]u8, len(s), alloc)
	if serr != nil {
		return query.NULL, query.fail(h, .Memory, .None)
	}
	copy(src, s)
	mem_limit := u64(0)
	if h.limit > 0 {
		mem_limit = h.limit - h.used if h.limit > h.used else 1
	}
	budget := tape.Budget{depth = u32(query.depth_limit(h)), memory = mem_limit}
	doc, err := m.hooks.parse_json(m.hooks.data, src, budget, alloc)
	if err != nil {
		if b, is_budget := err.(tape.Exceeded); is_budget && b.kind == .Memory {
			delete(src, alloc)
			tape.destroy(&doc)
			return query.NULL, query.fail(h, .Memory, .None)
		}
		if _, is_oom := err.(runtime.Allocator_Error); is_oom {
			delete(src, alloc)
			tape.destroy(&doc)
			return query.NULL, query.fail(h, .Memory, .None)
		}
		buf: [256]u8
		text := tape.error_message(buf[:], err, src)
		delete(src, alloc)
		tape.destroy(&doc)
		out := make([dynamic]u8, h.allocator)
		defer delete(out)
		append(&out, text)
		append(&out, " (while parsing '")
		append(&out, s)
		append(&out, "')")
		return query.NULL, raise_owned_text(m, string(out[:]))
	}
	doc.flags += {.Owns_Src}
	return query.document_value(h, doc, true, synthetic = true)
}

@(private)
v_ascii_case :: proc(m: ^Machine, b: ^Builtin, x: query.Value, args: []query.Value) -> (res: query.Value, status: query.Status) {
	if !query.is_text(x) {
		return query.NULL, raise_text(m, "explode input must be a string")
	}
	return query.ascii_case(m.h, x, b.name == "ascii_upcase")
}

@(private)
v_explode :: proc(m: ^Machine, b: ^Builtin, x: query.Value, args: []query.Value) -> (res: query.Value, status: query.Status) {
	if !query.is_text(x) {
		return query.NULL, raise_text(m, "explode input must be a string")
	}
	return query.explode(m.h, query.text_of(x))
}

@(private)
v_implode :: proc(m: ^Machine, b: ^Builtin, x: query.Value, args: []query.Value) -> (res: query.Value, status: query.Status) {
	h := m.h
	if query.type_of(x) != .Array {
		return query.NULL, raise_text(m, "implode input must be an array")
	}
	a := query.built(h, x) or_return
	defer query.release(h, a)
	alloc := query.heap_allocator(h)
	cps, aerr := make([]i64, len(query.items_of(a)), alloc)
	if aerr != nil {
		return query.NULL, query.fail(h, .Memory, .None)
	}
	defer delete(cps, alloc)
	for c, i in query.items_of(a) {
		if query.type_of(c) != .Number {
			out := make([dynamic]u8, h.allocator)
			defer delete(out)
			typed(h, &out, c)
			append(&out, " can't be imploded, unicode codepoint needs to be numeric")
			return query.NULL, raise_owned_text(m, string(out[:]))
		}
		// A number that is no code point is U+FFFD, as jq has it.
		cp := query.trunc_i64(c)
		if cp < 0 || cp > 0x10FFFF || cp >= 0xD800 && cp < 0xE000 {
			cp = 0xFFFD
		}
		cps[i] = cp
	}
	v, _ := query.implode(h, cps) or_return
	return v, .Ok
}

@(private)
v_trim :: proc(m: ^Machine, b: ^Builtin, x: query.Value, args: []query.Value) -> (res: query.Value, status: query.Status) {
	if !query.is_text(x) {
		return query.NULL, raise_text(m, "trim input must be a string")
	}
	return query.text_trim(m.h, x, b.name != "rtrim", b.name != "ltrim")
}

@(private)
v_affix :: proc(m: ^Machine, b: ^Builtin, x: query.Value, args: []query.Value) -> (res: query.Value, status: query.Status) {
	if !query.is_text(x) || !query.is_text(args[0]) {
		return query.NULL, raise_text(m, "startswith() requires string inputs" if b.name == "startswith" else "endswith() requires string inputs")
	}
	s, t := query.text_of(x), query.text_of(args[0])
	if len(t) > len(s) {
		return query.FALSE, .Ok
	}
	if b.name == "startswith" {
		return query.bool_value(s[:len(t)] == t), .Ok
	}
	return query.bool_value(s[len(s) - len(t):] == t), .Ok
}

@(private)
v_split :: proc(m: ^Machine, b: ^Builtin, x: query.Value, args: []query.Value) -> (res: query.Value, status: query.Status) {
	if !query.is_text(x) || !query.is_text(args[0]) {
		return query.NULL, raise_text(m, "split input and separator must be strings")
	}
	return query.text_split(m.h, x, query.text_of(args[0]))
}

@(private)
v_strindices :: proc(m: ^Machine, b: ^Builtin, x: query.Value, args: []query.Value) -> (res: query.Value, status: query.Status) {
	h := m.h
	if !query.is_text(x) {
		return query.NULL, raise_typed(m, x, " cannot be searched, as it is not a string")
	}
	if !query.is_text(args[0]) {
		return query.NULL, raise_typed(m, args[0], " is not a string")
	}
	s, t := query.text_of(x), query.text_of(args[0])
	out := query.make_array(h, 0) or_return
	defer if status != .Ok {
		query.release(h, out)
	}
	if len(t) == 0 {
		return out, .Ok
	}
	// Code point offsets, counted as the search goes.
	cp := 0
	for i in 0 ..= len(s) - len(t) {
		if s[i:i + len(t)] == t {
			query.append_owned(h, &out, query.int_value(i64(cp))) or_return
		}
		if s[i] & 0xC0 != 0x80 {
			cp += 1
		}
	}
	return out, .Ok
}

@(private)
v_sort :: proc(m: ^Machine, b: ^Builtin, x: query.Value, args: []query.Value) -> (res: query.Value, status: query.Status) {
	if query.type_of(x) != .Array {
		s := raise_typed(m, x, " cannot be sorted, as it is not an array")
		query.release(m.h, x)
		return query.NULL, s
	}
	return query.sort_by(m.h, x, move = true)
}

// `_sort_by_impl`, `_group_by_impl`, `_unique_by_impl`, `_min_by_impl`, `_max_by_impl`, and `unique`, `min`, `max`.
@(private)
v_by :: proc(m: ^Machine, b: ^Builtin, x: query.Value, args: []query.Value) -> (res: query.Value, status: query.Status) {
	h := m.h
	keys := args[0] if len(args) > 0 else query.ABSENT
	if query.type_of(x) != .Array {
		s := raise_typed(m, x, " cannot be sorted, as it is not an array")
		if b.takes_input {
			query.release(h, x)
		}
		return query.NULL, s
	}
	if len(args) > 0 && (query.type_of(keys) != .Array || query.length_of(h, keys) != query.length_of(h, x)) {
		if b.takes_input {
			query.release(h, x)
		}
		return query.NULL, raise_text(m, "Sort keys must be an array of the input's length")
	}
	switch b.name {
	case "_sort_by_impl":
		return query.sort_by(h, x, keys, move = b.takes_input)
	case "_group_by_impl":
		if keys.kind == .Array && query.length_of(h, x) >= 64 {
			if fast_res, fast_ok, fast_status := group_by_string_keys(h, x, keys, b.takes_input); fast_ok {
				return fast_res, fast_status
			}
		}
		return query.runs_by(h, x, keys, .Group, move = b.takes_input)
	case "_unique_by_impl", "unique":
		return query.runs_by(h, x, keys, .First, move = b.takes_input)
	case "_min_by_impl", "min":
		return query.extreme_by(h, x, keys, false)
	}
	return query.extreme_by(h, x, keys, true)
}

@(private = "file")
plain_group_key_string :: #force_inline proc "contextless" (v: query.Value) -> (string, bool) #no_bounds_check {
	if v.kind == .String {
		return query.text_of(v), true
	}
	if v.kind == .Node && v.p != nil {
		d := (^query.Doc_Block)(v.p)
		t := d.doc.nodes[v.n]
		if (t.kind == .String || t.kind == .Plain) && t.role != .Key && (t.spelling & tape.SPELLING_DECODE) == 0 {
			return query.text_of(v), true
		}
	}
	return "", false
}

@(private = "file")
hash_group_key :: #force_inline proc "contextless" (s: string) -> u64 {
	x := u64(0xCBF29CE484222325)
	for c in transmute([]u8)s {
		x = (x ~ u64(c)) * 0x100000001B3
	}
	return x
}

@(private = "file")
sort_group_perm :: proc(groups: []Group_Bucket, perm: []int) #no_bounds_check {
	n := len(perm)
	if n <= 32 {
		for i in 1 ..< n {
			k := perm[i]
			ks := groups[k].key
			j := i
			for j > 0 && groups[perm[j - 1]].key > ks {
				perm[j] = perm[j - 1]
				j -= 1
			}
			perm[j] = k
		}
		return
	}
	sift :: proc(groups: []Group_Bucket, perm: []int, root, end: int) #no_bounds_check {
		root := root
		for {
			child := 2 * root + 1
			if child >= end {
				return
			}
			if child + 1 < end && groups[perm[child]].key < groups[perm[child + 1]].key {
				child += 1
			}
			if groups[perm[root]].key >= groups[perm[child]].key {
				return
			}
			perm[root], perm[child] = perm[child], perm[root]
			root = child
		}
	}
	for start := (n - 2) / 2; start >= 0; start -= 1 {
		sift(groups, perm, start, n)
	}
	for end := n - 1; end > 0; end -= 1 {
		perm[0], perm[end] = perm[end], perm[0]
		sift(groups, perm, 0, end)
	}
}

@(private = "file")
Group_Bucket :: struct {
	key:   string,
	hash:  u64,
	head:  i32,
	tail:  i32,
	count: int,
}

// Fast O(n + G log G) grouping when all keys are flat plain strings with low/medium cardinality.
// Falls back (`ok = false`) without mutating `x` or `h` if any key is non-string or distinct count > n/2.
@(private = "file")
group_by_string_keys :: proc(
	h: ^query.Heap,
	x, keys: query.Value,
	move: bool,
) -> (
	res: query.Value,
	ok: bool,
	status: query.Status,
) #no_bounds_check {
	kitems := query.items_of(keys)
	n := len(kitems)
	if n < 64 || (x.kind != .Array && x.kind != .Node && x.kind != .Overlay) {
		return {}, false, .Ok
	}
	alloc := query.heap_allocator(h)
	max_groups := max(n / 2, 64)
	tcap := 128
	table := make([]u32, tcap, alloc)
	if table == nil {
		return {}, false, .Ok
	}
	defer delete(table, alloc)
	next_idx := make([]i32, n, alloc)
	if next_idx == nil {
		return {}, false, .Ok
	}
	defer delete(next_idx, alloc)
	groups := make([dynamic]Group_Bucket, 0, 32, alloc)
	defer delete(groups)

	mask := u64(tcap - 1)
	for k, i in kitems {
		s, is_str := plain_group_key_string(k)
		if !is_str {
			return {}, false, .Ok
		}
		hv := hash_group_key(s)
		at := int(hv & mask)
		found := -1
		for {
			slot := table[at]
			if slot == 0 {
				break
			}
			gi := int(slot - 1)
			if groups[gi].hash == hv && groups[gi].key == s {
				found = gi
				break
			}
			at = (at + 1) & int(mask)
		}
		if found >= 0 {
			g := &groups[found]
			next_idx[g.tail] = i32(i)
			g.tail = i32(i)
			next_idx[i] = -1
			g.count += 1
			continue
		}
		if len(groups) >= max_groups {
			return {}, false, .Ok
		}
		if (len(groups) + 1) * 2 > len(table) {
			new_cap := len(table) * 2
			new_tbl := make([]u32, new_cap, alloc)
			if new_tbl == nil {
				return {}, false, .Ok
			}
			new_mask := u64(new_cap - 1)
			for &gb, gidx in groups {
				nat := int(gb.hash & new_mask)
				for new_tbl[nat] != 0 {
					nat = (nat + 1) & int(new_mask)
				}
				new_tbl[nat] = u32(gidx + 1)
			}
			delete(table, alloc)
			table = new_tbl
			mask = new_mask
			at = int(hv & mask)
			for table[at] != 0 {
				at = (at + 1) & int(mask)
			}
		}
		next_idx[i] = -1
		if _, aerr := append(&groups, Group_Bucket{key = s, hash = hv, head = i32(i), tail = i32(i), count = 1}); aerr != nil {
			return {}, false, .Ok
		}
		table[at] = u32(len(groups))
	}

	ng := len(groups)
	perm := make([]int, ng, alloc)
	if perm == nil {
		return {}, false, .Ok
	}
	defer delete(perm, alloc)
	for i in 0 ..< ng {
		perm[i] = i
	}
	sort_group_perm(groups[:], perm)

	xs := x
	xs_owned := move
	if x.kind != .Array {
		bs: query.Status
		xs, bs = query.built(h, x)
		if move {
			query.release(h, x)
		}
		xs_owned = true
		if bs != .Ok {
			return query.NULL, true, bs
		}
	}
	defer if xs_owned {
		query.release(h, xs)
	}

	src_items := query.items_of(xs)
	out, os := query.make_array(h, ng)
	if os != .Ok {
		return query.NULL, true, os
	}
	can_move := xs_owned && query.unique(xs)
	for gi in perm {
		g := &groups[gi]
		run, rs := query.make_array(h, g.count)
		if rs != .Ok {
			query.release(h, out)
			return query.NULL, true, rs
		}
		idx := g.head
		for idx >= 0 {
			el := src_items[idx] if can_move else query.retain(src_items[idx])
			if as := query.append_owned(h, &run, el); as != .Ok {
				if can_move {
					// Zero remaining unmoved slots before `xs` releases, keeping moved ones already released by `run`.
					for p := g.head; p != idx; p = next_idx[p] {
						src_items[p] = query.NULL
					}
					for prev_rank in 0 ..< len(perm) {
						pgi := perm[prev_rank]
						if pgi == gi {
							break
						}
						for p := groups[pgi].head; p >= 0; p = next_idx[p] {
							src_items[p] = query.NULL
						}
					}
				} else {
					query.release(h, el)
				}
				query.release(h, run)
				query.release(h, out)
				return query.NULL, true, as
			}
			idx = next_idx[idx]
		}
		if as := query.append_owned(h, &out, run); as != .Ok {
			query.release(h, run)
			query.release(h, out)
			return query.NULL, true, as
		}
	}
	if can_move {
		for &el in src_items {
			el = query.NULL
		}
	}
	return out, true, .Ok
}

@(private)
v_flatten :: proc(m: ^Machine, b: ^Builtin, x: query.Value, args: []query.Value) -> (res: query.Value, status: query.Status) {
	// jq counts the depth down by one until it is zero, which a fractional depth never reaches.
	depth := query.as_f64(args[0])
	return query.flatten(m.h, x, int(query.trunc_i64(args[0])) if depth == math.trunc(depth) else -1)
}

@(private)
v_setpath :: proc(m: ^Machine, b: ^Builtin, x: query.Value, args: []query.Value) -> (res: query.Value, status: query.Status) {
	return query.set_path(m.h, x, args[0], query.retain(args[1]))
}

@(private)
v_delpaths :: proc(m: ^Machine, b: ^Builtin, x: query.Value, args: []query.Value) -> (res: query.Value, status: query.Status) {
	return query.del_paths(m.h, x, args[0])
}

@(private)
v_constant :: proc(m: ^Machine, b: ^Builtin, x: query.Value, args: []query.Value) -> (res: query.Value, status: query.Status) {
	switch b.name {
	case "infinite":
		return query.double_value(math.inf_f64(1)), .Ok
	case "nan":
		return query.double_value(math.nan_f64()), .Ok
	case "have_literal_numbers":
		return query.TRUE, .Ok
	case "have_decnum":
		// Integers are exact, as decNumber keeps them.
		return query.TRUE, .Ok
	case "input_line_number":
		if m.hooks != nil && m.hooks.input_line_number != nil {
			return query.int_value(m.hooks.input_line_number(m.hooks.data)), .Ok
		}
		return query.int_value(0), .Ok
	case "input_filename":
		if m.hooks != nil && m.hooks.input_filename != nil {
			return m.hooks.input_filename(m.hooks.data, m.h)
		}
	case "now":
		if m.hooks != nil && m.hooks.now != nil {
			return query.double_value(m.hooks.now(m.hooks.data)), .Ok
		}
		return query.double_value(0), .Ok
	}
	return query.NULL, .Ok
}

// `where`: source location of `.` (or its nearest enclosing document-origin value along active pipes), or `null`.
// Text formats return `{"line": L, "column": C}` (with `"file": F` when known); binary formats (`line == 0`) return
// `{"offset": N}` (with `"file": F` when known), matching v1.
@(private)
v_where :: proc(m: ^Machine, b: ^Builtin, x: query.Value, args: []query.Value) -> (res: query.Value, status: query.Status) {
	h := m.h
	at := x if query.has_doc_origin(x) else m.origin
	file_val := query.ABSENT
	defer query.release(h, file_val)
	file := ""
	place: tape.Place
	ok := false
	if m.hooks != nil && m.hooks.place != nil {
		file, place, ok = m.hooks.place(m.hooks.data, at, h)
	} else {
		place, ok = query.value_place(h, at)
		if ok && m.hooks != nil && m.hooks.input_filename != nil {
			fs: query.Status
			file_val, fs = m.hooks.input_filename(m.hooks.data, h)
			if fs != .Ok {
				return query.NULL, fs
			}
			if query.is_text(file_val) {
				file = query.text_of(file_val)
			}
		}
	}
	if !ok {
		return query.NULL, .Ok
	}
	fields := 2 + int(file != "")
	out := query.make_object(h, fields) or_return
	defer if status != .Ok {
		query.release(h, out)
	}
	if file != "" {
		fv := query.text_value(h, file) or_return
		query.object_put_fresh(h, &out, query.text_borrowed("file"), fv) or_return
	}
	if place.line == 0 {
		query.object_put_fresh(h, &out, query.text_borrowed("offset"), query.int_value(i64(place.byte))) or_return
	} else {
		query.object_put_fresh(h, &out, query.text_borrowed("line"), query.int_value(i64(place.line))) or_return
		query.object_put_fresh(h, &out, query.text_borrowed("column"), query.int_value(i64(place.col))) or_return
	}
	return out, .Ok
}

@(private)
v_number_class :: proc(m: ^Machine, b: ^Builtin, x: query.Value, args: []query.Value) -> (res: query.Value, status: query.Status) {
	if query.type_of(x) != .Number {
		return query.FALSE, .Ok
	}
	if x.kind == .Big {
		return query.bool_value(b.name == "isnormal"), .Ok
	}
	if (x.kind == .Node || x.kind == .Overlay) && query.is_integer(x) {
		if _, ok := query.as_i64(x); !ok {
			return query.bool_value(b.name == "isnormal"), .Ok
		}
	}
	f := query.as_f64(x)
	switch b.name {
	case "isinfinite":
		return query.bool_value(math.is_inf(f)), .Ok
	case "isnan":
		return query.bool_value(math.is_nan(f)), .Ok
	}
	return query.bool_value(math.classify(f) == .Normal), .Ok
}

@(private)
v_frexp :: proc(m: ^Machine, b: ^Builtin, x: query.Value, args: []query.Value) -> (res: query.Value, status: query.Status) {
	h := m.h
	if query.type_of(x) != .Number {
		return query.NULL, raise_typed(m, x, " number required")
	}
	a := query.as_f64(x)
	out := query.make_array(h, 2) or_return
	defer if status != .Ok {
		query.release(h, out)
	}
	switch b.name {
	case "frexp":
		fr, e := math.frexp(a)
		query.append_owned(h, &out, query.double_value(fr)) or_return
		query.append_owned(h, &out, query.int_value(i64(e))) or_return
	case "modf":
		ip, fr := math.modf(a)
		if math.is_inf(a) {
			ip, fr = a, math.copy_sign(0, a)
		}
		query.append_owned(h, &out, query.double_value(fr)) or_return
		query.append_owned(h, &out, query.double_value(ip)) or_return
	case:
		r, sign := math.lgamma(a)
		query.append_owned(h, &out, query.double_value(r)) or_return
		query.append_owned(h, &out, query.int_value(i64(sign))) or_return
	}
	return out, .Ok
}

@(private)
v_builtins :: proc(m: ^Machine, b: ^Builtin, x: query.Value, args: []query.Value) -> (res: query.Value, status: query.Status) {
	h := m.h
	out := query.make_array(h, len(BUILTINS)) or_return
	defer if status != .Ok {
		query.release(h, out)
	}
	for &e in BUILTINS {
		if len(e.name) > 0 && e.name[0] == '_' {
			continue
		}
		query.append_owned(h, &out, name_arity(h, e.name, int(e.arity)) or_return) or_return
	}
	for d := m.prog.prelude; d != nil; d = d.a {
		if fn := d.fn; len(fn.name) > 0 && fn.name[0] != '_' {
			query.append_owned(h, &out, name_arity(h, fn.name, len(fn.params)) or_return) or_return
		}
	}
	return out, .Ok
}

// `name/arity` as a text value.
@(private)
name_arity :: proc(h: ^query.Heap, name: string, arity: int) -> (res: query.Value, status: query.Status) {
	v, out := query.make_text(h, len(name) + (3 if arity >= 10 else 2)) or_return
	copy(out[:len(name)], name)
	out[len(name)] = '/'
	if arity >= 10 {
		out[len(name) + 1] = u8('0' + arity / 10)
	}
	out[len(name) + (2 if arity >= 10 else 1)] = u8('0' + arity % 10)
	return v, .Ok
}

// Raises a message the caller made, copied into the heap.
@(private)
raise_owned_text :: proc(m: ^Machine, text: string) -> query.Status {
	t, s := query.text_value(m.h, text)
	if s != .Ok {
		return s
	}
	defer query.release(m.h, t)
	return raise(m.h, t)
}

// `a` rounded to the nearest integer, a tie to the even one.
@(private)
round_even :: proc(a: f64) -> f64 {
	if math.is_inf(a) || math.is_nan(a) {
		return a
	}
	f := math.floor(a)
	switch d := a - f; {
	case d > 0.5:
		return f + 1
	case d < 0.5:
		return f
	}
	return f if math.floor(f / 2) * 2 == f else f + 1
}
