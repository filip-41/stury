package core

// The order, equality and hash of values, in either form. The order is jq's: null < false < true < numbers < strings
// < arrays < objects, arrays member by member, objects by their sorted key sets and then their values in key order.
// An object's repeated key counts once, with its last value. Two numbers of one double compare as decimals when both
// keep their digits, as two literals do, so `100000000000000000001` is above `100000000000000000000` and `1.0` equals `1`. A trail is
// the array of its keys.

import "base:runtime"
import "core:math"
import "core:slice"
import "core:strconv"
import "core:strings"
import "spell"

// The members from which `compare` sorts keys and values together: a key lookup in a document object scans every
// member, so past this many one walk over both sorted lists beats a lookup per key. Below it, a key-only sort and a few
// lookups are cheaper than sorting pairs.
@(private = "file")
WIDE_OBJECT :: 64

// The double of number `v` and the digits it keeps: a `Number_Text`'s or a number node's text, none for a double or a
// number spelled other than as a JSON number (JSON5's `0x10`).
double_of :: proc(v: Value) -> (f: f64, digits: string, ok: bool) {
	#partial switch x in plain(v) {
	case f64:
		return x, "", true
	case ^Number_Text:
		return x.double, x.text, true
	case Node_Ref:
		if int(x.node) >= len(x.doc.nodes) {
			return 0, "", false
		}
		node := x.doc.nodes[x.node]
		if node.kind != .Number && doc_kind(x.doc, x.node) != .Number {
			return 0, "", false
		}
		// A number node is read by its document's reader, which its spelling makes cheaper than reading its text again.
		text := string(span(x.doc, x.node))
		n, _ := doc_number(x.doc, x.node)
		f = number_f64(n, text)
		// The `NUMBER_*` layout holds only for a `.Number` token.
		if node.kind == .Number && node.spelling & NUMBER_KIND_MASK != 0 {
			return f, "", true
		}
		return f, text, true
	}
	return 0, "", false
}

// The binary64 of `n`, a number spelled `text`.
number_f64 :: proc(n: Number, text: string) -> f64 {
	switch n.kind {
	case .Int:
		// `-0` is an integer whose bits carry no sign
		return -0.0 if n.bits == 0 && text[0] == '-' else f64(i64(n.bits))
	case .Uint:
		return f64(n.bits)
	case .Float:
		return transmute(f64)n.bits
	case .Wide:
	}
	// past binary64's digits or range, `1e400` among them, which strconv reads as infinity
	f, _ := strconv.parse_f64(text)
	return f
}

// The double of `text`, a JSON number.
text_f64 :: proc(text: string) -> f64 {
	// A number of at most 15 digits and no exponent, a program's `1` or `2.5` mostly, is read here, as arithmetic reads
	// a literal at each use: its digits and a power of ten are exact doubles, so one division rounds it correctly.
	if len(text) <= 17 {
		s := text
		neg := len(s) > 0 && s[0] == '-'
		if neg {
			s = s[1:]
		}
		m: u64
		point := -1
		for c, i in transmute([]byte)s {
			switch {
			case '0' <= c && c <= '9':
				m = m * 10 + u64(c - '0')
			case c == '.' && point < 0:
				point = i
			case:
				return text_f64_slow(text)
			}
		}
		if len(s) - int(point >= 0) > 15 {
			return text_f64_slow(text)
		}
		f := f64(m)
		if point >= 0 {
			f /= POW10_EXACT[len(s) - 1 - point]
		}
		return -f if neg else f
	}
	return text_f64_slow(text)
}

@(private = "file", rodata)
POW10_EXACT := [16]f64{1, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12, 1e13, 1e14, 1e15}

@(private = "file")
text_f64_slow :: #force_no_inline proc(text: string) -> f64 {
	n, _ := spell.number_strict(transmute([]byte)text, 0, u64(len(text)))
	return number_f64(n, text)
}

// The order of `a` and `b`: -1, 0 or 1. With `eq` a value equals itself without being read, so `a == a` holds however
// deep `a` is. Past `max_depth` levels the comparison stops: it sets `too_deep`, when given, and the levels below
// compare equal.
compare :: proc(a, b: Value, depth := 0, eq := false, too_deep: ^bool = nil, max_depth := MAX_DEPTH) -> int {
	if depth > max_depth {
		if too_deep != nil {
			too_deep^ = true
		}
		return 0
	}
	if eq && same(a, b) {
		return 0
	}
	ka, kb := value_kind(a), value_kind(b)
	if ka != kb {
		return -1 if ka < kb else 1
	}
	#partial switch ka {
	case .Number:
		x, lx, _ := double_of(a)
		y, ly, _ := double_of(b)
		// nan is below every number, itself included.
		if math.is_nan(x) {
			return -1
		}
		if math.is_nan(y) {
			return 1
		}
		buf: [spell.F64_ROOM]u8
		if x == y && (lx == "") != (ly == "") && !math.is_inf(x) {
			// A `Number_Text` against a double of its own value: the double is its shortest decimal.
			_, a_text := plain(a).(^Number_Text)
			_, b_text := plain(b).(^Number_Text)
			if a_text || b_text {
				short := string(buf[:spell.f64_text(&buf[0], x)])
				lx, ly = lx if lx != "" else short, ly if ly != "" else short
			}
		}
		if x == y && lx != "" && ly != "" {
			return compare_digits(lx, ly)
		}
		return -1 if x < y else (1 if x > y else 0)
	case .String:
		return text_order(string_text(a), string_text(b))
	case .Array:
		if x, a_arr := plain(a).(^Array); a_arr {
			if y, b_arr := plain(b).(^Array); b_arr {
				return compare_items(x.items[:], y.items[:], depth, eq, too_deep, max_depth)
			}
		}
		_, a_trail := a.(Trail)
		_, b_trail := b.(Trail)
		if a_trail || b_trail {
			return compare_trails(a, b, depth, eq, too_deep, max_depth)
		}
		na, nb := value_length(a), value_length(b)
		ia, ib := value_children(a), value_children(b)
		for _ in 0 ..< min(na, nb) {
			x, _ := value_child_next(&ia)
			y, _ := value_child_next(&ib)
			if c := compare(x, y, depth + 1, eq, too_deep, max_depth); c != 0 {
				return c
			}
		}
		return -1 if na < nb else (1 if na > nb else 0)
	case .Object:
		if is_wide(a) && is_wide(b) {
			return compare_members(sorted_members(a), sorted_members(b), depth, eq, too_deep, max_depth)
		}
		ka, kb := sorted_keys(a), sorted_keys(b)
		for i in 0 ..< min(len(ka), len(kb)) {
			if c := text_order(ka[i], kb[i]); c != 0 {
				return c
			}
		}
		if len(ka) != len(kb) {
			return -1 if len(ka) < len(kb) else 1
		}
		for k in ka {
			x, _ := value_member(a, k)
			y, _ := value_member(b, k)
			if c := compare(x, y, depth + 1, eq, too_deep, max_depth); c != 0 {
				return c
			}
		}
	}
	return 0
}

// Whether `a` and `b` are equal: `compare` with `eq` gives 0.
equal :: proc(a, b: Value, too_deep: ^bool = nil, max_depth := MAX_DEPTH) -> bool {
	return compare(a, b, eq = true, too_deep = too_deep, max_depth = max_depth) == 0
}

// Whether `a` and `b` are one container or one document node, not two alike.
same :: proc(a, b: Value) -> bool {
	#partial switch x in a {
	case ^Array:
		y, ok := b.(^Array)
		return ok && x == y
	case ^Object:
		y, ok := b.(^Object)
		return ok && x == y
	case Node_Ref:
		y, ok := b.(Node_Ref)
		return ok && x == y
	case ^Commented:
		y, ok := b.(^Commented)
		return ok && x == y
	case Trail:
		y, ok := b.(Trail)
		return ok && x == y
	}
	return false
}

// Two strings' byte order. Odin's own orders an empty string with no buffer apart from an empty one with a buffer.
text_order :: proc(a, b: string) -> int {
	if len(a) == 0 || len(b) == 0 {
		return int(len(a) > 0) - int(len(b) > 0)
	}
	return strings.compare(a, b)
}

// `compare` of two arrays' members, then of their lengths.
@(private = "file")
compare_items :: proc(xs, ys: []Value, depth: int, eq: bool, too_deep: ^bool = nil, max_depth := MAX_DEPTH) -> int {
	for i in 0 ..< min(len(xs), len(ys)) {
		if c := compare(xs[i], ys[i], depth + 1, eq, too_deep, max_depth); c != 0 {
			return c
		}
	}
	return -1 if len(xs) < len(ys) else (1 if len(xs) > len(ys) else 0)
}

// The trail keys `compare_trails` reads onto the stack. A longer trail's go into a heap block freed on return.
@(private = "file")
TRAIL_KEYS_ON_STACK :: 32

// `compare` of two arrays one of which is a trail. Two trails of at most `TRAIL_KEYS_ON_STACK` steps are compared in
// place, and any other's keys are read into the stack or a heap block, as a sort compares trails often and an arena
// frees no block.
@(private = "file", cold)
compare_trails :: proc(a, b: Value, depth: int, eq: bool, too_deep: ^bool, max_depth: int) -> int {
	if x, a_trail := a.(Trail); a_trail {
		if y, b_trail := b.(Trail); b_trail {
			da, db := trail_depth(x), trail_depth(y)
			if da <= TRAIL_KEYS_ON_STACK && db <= TRAIL_KEYS_ON_STACK {
				sa, sb := (^Trail_Step)(x), (^Trail_Step)(y)
				for i := da; i > db; i -= 1 {
					sa = sa.parent
				}
				for i := db; i > da; i -= 1 {
					sb = sb.parent
				}
				if c := compare_steps(sa, sb, depth, eq, too_deep, max_depth); c != 0 {
					return c
				}
				return -1 if da < db else (1 if da > db else 0)
			}
		}
	}
	bufs: [2][TRAIL_KEYS_ON_STACK]Value
	xs: [2][]Value
	for v, i in ([2]Value{a, b}) {
		if t, is_trail := v.(Trail); is_trail {
			xs[i] = bufs[i][:t.depth] if t.depth <= TRAIL_KEYS_ON_STACK else make([]Value, t.depth, runtime.heap_allocator())
			trail_keys(t, xs[i])
		} else {
			// an array of a document or of comments
			x := make([]Value, value_length(v), runtime.heap_allocator())
			it := value_children(v)
			for j := 0; j < len(x); j += 1 {
				x[j], _ = value_child_next(&it)
			}
			xs[i] = x
		}
	}
	defer for v, i in ([2]Value{a, b}) {
		if t, is_trail := v.(Trail); !is_trail || t.depth > TRAIL_KEYS_ON_STACK {
			delete(xs[i], runtime.heap_allocator())
		}
	}
	return compare_items(xs[0], xs[1], depth, eq, too_deep, max_depth)
}

@(private = "file")
trail_depth :: #force_inline proc(t: Trail) -> int {
	return t.depth if t != nil else 0
}

// `compare` of the keys of two steps as deep, from the root. Steps both trails share are equal, so only the keys below
// them are compared.
@(private = "file")
compare_steps :: proc(a, b: ^Trail_Step, depth: int, eq: bool, too_deep: ^bool, max_depth: int) -> int {
	if a == b {
		return 0
	}
	if c := compare_steps(a.parent, b.parent, depth, eq, too_deep, max_depth); c != 0 {
		return c
	}
	return compare(a.key, b.key, depth + 1, eq, too_deep, max_depth)
}

// Whether object `v` has at least `WIDE_OBJECT` members, a repeated key's each time.
is_wide :: proc(v: Value) -> bool {
	return value_kind(v) == .Object && value_length(v) >= WIDE_OBJECT
}

// One member of an object, as `sorted_members` lists it.
Member :: struct {
	key: string,
	val: Value,
}

// An object's members sorted by their keys' bytes, each key once with its last value, in a slice made in the context
// allocator.
sorted_members :: proc(v: Value) -> []Member {
	ms := make([dynamic]Member, 0, value_length(v))
	it := value_pairs(v)
	for k, m in value_pair_next(&it) {
		append(&ms, Member{k, m})
	}
	slice.stable_sort_by(ms[:], proc(a, b: Member) -> bool {return a.key < b.key})
	// Of a run of one key, the last is the member that was added last.
	kept := 0
	for m, i in ms {
		if i + 1 < len(ms) && ms[i + 1].key == m.key {
			continue
		}
		ms[kept] = m
		kept += 1
	}
	return ms[:kept]
}

// An object's keys sorted by their bytes, each once, in a slice made in the context allocator.
sorted_keys :: proc(v: Value) -> []string {
	ks := make([dynamic]string, 0, value_length(v))
	it := value_pairs(v)
	for k in value_pair_next(&it) {
		append(&ks, k)
	}
	slice.sort(ks[:])
	kept := 0
	for k, i in ks {
		if i > 0 && ks[i - 1] == k {
			continue
		}
		ks[kept] = k
		kept += 1
	}
	return ks[:kept]
}

// The order of two objects from their sorted members: the key sets, then the values in key order.
compare_members :: proc(a, b: []Member, depth: int, eq: bool, too_deep: ^bool = nil, max_depth := MAX_DEPTH) -> int {
	for i in 0 ..< min(len(a), len(b)) {
		if c := text_order(a[i].key, b[i].key); c != 0 {
			return c
		}
	}
	if len(a) != len(b) {
		return -1 if len(a) < len(b) else 1
	}
	for m, i in a {
		if c := compare(m.val, b[i].val, depth + 1, eq, too_deep, max_depth); c != 0 {
			return c
		}
	}
	return 0
}

// The text of string `v`, a node's decoded into the context allocator when it needs decoding.
@(private = "file")
string_text :: proc(v: Value) -> string {
	#partial switch x in plain(v) {
	case string:
		return x
	case Node_Ref:
		return node_string(x.doc, x.node)
	}
	return ""
}

// A hash of `v` that two equal values share: a number's is its double's, so two literals of one double share it.
hash :: proc(v: Value, seed := u64(0xcbf29ce484222325)) -> u64 {
	h := seed
	k := value_kind(v)
	h = mix(h, u64(k))
	#partial switch k {
	case .Number:
		f, _, _ := double_of(v)
		h = mix(h, transmute(u64)(f + 0)) // + 0: -0 and 0 are one number
	case .String:
		s := string_text(v)
		for b in transmute([]u8)s {
			h = mix(h, u64(b))
		}
		h = mix(h, u64(len(s)))
	case .Array:
		it := value_children(v)
		for m in value_child_next(&it) {
			h = mix(h, hash(m, seed))
		}
	case .Object:
		// The members are summed, so their order does not count. A repeated key counts once, with its last value.
		sum: u64
		members := sorted_members(v)
		defer delete(members)
		for m in members {
			sum += mix(hash(m.key, seed), hash(m.val, seed))
		}
		h = mix(h, sum)
	}
	return h
}

@(private = "file")
mix :: #force_inline proc(h, x: u64) -> u64 {
	return (h ~ x) * 0x100000001b3
}

// `lit` as a decimal in decNumber's range, which jq keeps a literal inside: past an adjusted exponent of 999999999 the
// number keeps no literal (false), and below -1147483646 it is a zero.
@(private = "file")
decimal_in_range :: proc(lit: string) -> (d: spell.Decimal, ok: bool) {
	d = spell.decimal_of(lit)
	switch {
	case d.head == "":
	case d.point - 1 > 999999999:
		return d, false
	case d.point - 1 < -1147483646:
		d = {}
	}
	return d, true
}

// The order of two numbers of one double that keep their digits (`la`, `lb`): they compare as decimals, unless one is
// past decNumber's range and so a plain double.
@(private = "file")
compare_digits :: proc(la, lb: string) -> int {
	if la == lb {
		return 0
	}
	dx, x_ok := decimal_in_range(la)
	dy, y_ok := decimal_in_range(lb)
	if x_ok && y_ok {
		order, _ := spell.decimal_compare(dx, dy)
		return order
	}
	return 0
}
