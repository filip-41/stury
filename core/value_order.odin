package core

// The order, equality and hash of values, in either form. The order is jq's: null < false < true < numbers < strings
// < arrays < objects, with a binary format's byte strings between the numbers and the strings, in the order of their
// payloads, arrays member by member, objects by their sorted key sets and then their values in key order. An object's
// repeated key counts once, with its last value, or its first where `dups` is `.First`. A number literal is the decimal
// it spells at any size, so `1.0` equals `1`, `100000000000000000001` is above `100000000000000000000`, `1e400` is below
// `1e401` and `1e-400` is above `0`. A double is its shortest decimal, and an infinity is no decimal: it is above every literal, `-inf` below.
// A trail is the array of its keys.

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

// The room `double_of` needs in `buf` to give a prefixed integer's digits: a sign and the 39 digits of 2^128 - 1.
HEX_ROOM :: 40

// The double of number `v` and the digits it keeps: a `Number_View`'s or a number node's text, none for a double or a
// number whose text is no decimal. A decimal a format spells with a sign, a point of its own, leading zeros or
// underscores (`+1e400`, `.5`, `1_000`) keeps the JSON number it spells, written in `buf` when that holds the text and
// one byte more, and else its text, or none when the text holds an underscore. A hex, octal or binary integer of any
// size (`0x10`, `0o17`) keeps its decimal digits in `buf` when that holds them, and has none without room. A number of a
// format whose span is not its text, which has a `number_text`, keeps the digits that spells when they lie in the
// source or `buf` holds them, and is its double otherwise.
double_of :: proc(v: Value, buf: []u8 = nil) -> (f: f64, digits: string, ok: bool) {
	#partial switch x in plain(v) {
	case f64:
		return x, "", true
	case Number_View:
		return view_f64(x), view_text(x), true
	case Node_Ref:
		if int(x.node) >= len(x.doc.nodes) {
			return 0, "", false
		}
		node := x.doc.nodes[x.node]
		if node.kind != .Number && doc_kind(x.doc, x.node) != .Number {
			return 0, "", false
		}
		if x.doc.readers.number_text != nil {
			return spelled_double(x.doc, x.node, buf)
		}
		// A number node is read by its document's reader, which its spelling makes cheaper than reading its text again.
		text := string(span(x.doc, x.node))
		n, _ := doc_number(x.doc, x.node)
		f = number_f64(n, text)
		// The `NUMBER_*` layout holds only for a `.Number` token.
		kind := node.spelling & NUMBER_KIND_MASK if node.kind == .Number else 0
		switch {
		case kind == NUMBER_DECIMAL:
			if json, fits := json_decimal(text, buf); fits {
				return f, json, true
			}
			return f, "" if strings.index_byte(text, '_') >= 0 else text, true
		case kind > NUMBER_DECIMAL:
			decimal, _ := prefixed_decimal(text, buf)
			return f, decimal, true
		}
		return f, text, true
	}
	return 0, "", false
}

// The room in which `spelled_double` reads a number's digits before it grows: every format's integer, float and hex
// integer fits.
@(private = "file")
SPELLED_ROOM :: 64

// The most digits `spelled_double` reads to round a number no binary64 holds.
@(private = "file")
SPELLED_MAX :: 1 << 26

// `double_of` of number node `i` of a document whose format spells its digits with `number_text`. The digits are kept
// when they are a decimal that lies in the source or fits `buf`. A number too wide for binary64 is rounded from its
// digits, read into the temp allocator past `SPELLED_ROOM` bytes, and `ok` is false when they cannot be read.
@(private = "file")
spelled_double :: proc(doc: ^Document, i: Node_Index, buf: []u8) -> (f: f64, digits: string, ok: bool) {
	n, _ := doc_number(doc, i)
	room: [SPELLED_ROOM]u8
	text, fit := doc_number_text(doc, i, room[:])
	for size := 4 * SPELLED_ROOM; !fit && n.kind == .Wide && size <= SPELLED_MAX; size *= 4 {
		grown, err := make([]u8, size, context.temp_allocator)
		if err != nil {
			return 0, "", false
		}
		text, fit = doc_number_text(doc, i, grown)
	}
	if !fit || len(text) == 0 {
		// An integer or a binary64 is its bits, and a number with no digits is the infinity or NaN its bits hold.
		return number_f64(n, "0"), "", n.kind != .Wide
	}
	f = number_f64(n, text)
	if c := text[1] if text[0] == '-' && len(text) > 1 else text[0]; c < '0' || c > '9' {
		return f, "", true
	}
	lo, at := uintptr(raw_data(doc.src)), uintptr(raw_data(text))
	switch {
	case at >= lo && at + uintptr(len(text)) <= lo + uintptr(len(doc.src)):
		digits = text
	case len(text) <= len(buf):
		digits = string(buf[:copy(buf, text)])
	}
	return f, digits, true
}

// The decimal digits of the hex, octal or binary integer `text`, `0x`, `0o` or `0b` and digits an underscore may
// separate, with a sign when it is negative and not zero, written at the end of `buf`, which needs about 1.21 bytes per
// digit and two more. `ok` is false for any other text, when `buf` is too small and when the work words cannot be held.
prefixed_decimal :: proc(text: string, buf: []u8) -> (digits: string, ok: bool) {
	WORD :: 1_000_000_000
	s, neg := text, false
	if len(s) > 0 && (s[0] == '-' || s[0] == '+') {
		neg, s = s[0] == '-', s[1:]
	}
	if len(s) < 3 || s[0] != '0' {
		return
	}
	base: u64
	switch s[1] | 0x20 {
	case 'x': base = 16
	case 'o': base = 8
	case 'b': base = 2
	case: return
	}
	// Least significant word first, each word nine decimal digits.
	stack: [16]u32
	words := stack[:]
	if len(s) / 7 + 1 > len(stack) {
		made, err := make([]u32, len(s) / 7 + 1)
		if err != nil {
			return
		}
		words = made
	}
	defer if raw_data(words) != raw_data(stack[:]) {
		delete(words)
	}
	n := 0
	for c in transmute([]u8)s[2:] {
		if c == '_' {
			continue
		}
		d := u64(spell.HEX_NIBBLE[c])
		if d >= base {
			return
		}
		for &w in words[:n] {
			x := u64(w) * base + d
			w, d = u32(x % WORD), x / WORD
		}
		if d > 0 {
			words[n] = u32(d)
			n += 1
		}
	}
	at := len(buf)
	for k in 0 ..< n {
		w := words[k]
		for _ in 0 ..< 9 {
			if k + 1 == n && w == 0 {
				break
			}
			if at == 0 {
				return
			}
			at -= 1
			buf[at], w = u8('0' + w % 10), w / 10
		}
	}
	if n == 0 || neg {
		if at == 0 {
			return
		}
		at -= 1
		buf[at] = '0' if n == 0 else '-'
	}
	return string(buf[at:]), true
}

// The JSON number that `lit`, a decimal a format spells with a sign, a point of its own, leading zeros or underscores,
// spells, written in `buf`: `+1` as `1`, `.5` as `0.5`, `5.` as `5.0`, `007` as `7`, `1_0` as `10`, and `-0` as `0` when
// it is an integer. `ok` is false when `buf` holds fewer bytes than `lit` and one more.
json_decimal :: proc(lit: string, buf: []u8) -> (json: string, ok: bool) {
	if len(lit) == 0 || len(buf) <= len(lit) {
		return
	}
	n := 0
	p := 1 if lit[0] == '+' || lit[0] == '-' else 0
	if lit[0] == '-' && !integer_zero(lit[p:]) {
		buf[n] = '-'
		n += 1
	}
	if p < len(lit) && lit[p] == '.' {
		buf[n] = '0'
		n += 1
	}
	leading := true
	for k in p ..< len(lit) {
		if lit[k] == '_' {
			continue
		}
		// A zero is leading while a digit follows it, past any underscores.
		next := k + 1
		for next < len(lit) && lit[next] == '_' {
			next += 1
		}
		if leading && lit[k] == '0' && next < len(lit) && lit[next] - '0' < 10 {
			continue
		}
		leading = false
		buf[n] = lit[k]
		n += 1
		// A point with no digit after it still makes a float, so it keeps a zero.
		if lit[k] == '.' && (k + 1 == len(lit) || lit[k + 1] - '0' >= 10) {
			buf[n] = '0'
			n += 1
		}
	}
	return string(buf[:n]), true
}

// Whether `digits` is an integer zero: zeros and underscores, which a sign does not make negative.
@(private = "file")
integer_zero :: proc(digits: string) -> bool {
	for c in transmute([]u8)digits {
		if c != '0' && c != '_' {
			return false
		}
	}
	return len(digits) > 0
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
// compare equal. A plain node of a delimited text is the string its format gives it, as it is in the command line, unless
// `read_plain` reads it as the number, boolean or null it is compared with, by a schema's plain rule.
compare :: proc(a, b: Value, depth := 0, eq := false, too_deep: ^bool = nil, max_depth := MAX_DEPTH, read_plain := false, dups := Duplicates.Last) -> int {
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
		if read_plain {
			if c, read := compare_plain(a, ka, b, kb); read {
				return c
			}
		}
		return -1 if ka < kb else 1
	}
	#partial switch ka {
	case .Number:
		hex: [2][HEX_ROOM]u8
		x, lx, _ := double_of(a, hex[0][:])
		y, ly, _ := double_of(b, hex[1][:])
		// nan is below every number, itself included.
		if math.is_nan(x) {
			return -1
		}
		if math.is_nan(y) {
			return 1
		}
		return compare_numbers(x, lx, y, ly)
	case .String, .Bytes:
		return text_order(string_text(a), string_text(b))
	case .Array:
		if x, a_arr := plain(a).(^Array); a_arr {
			if y, b_arr := plain(b).(^Array); b_arr {
				return compare_items(x.items[:], y.items[:], depth, eq, too_deep, max_depth, read_plain, dups)
			}
		}
		_, a_trail := a.(Trail)
		_, b_trail := b.(Trail)
		if a_trail || b_trail {
			return compare_trails(a, b, depth, eq, too_deep, max_depth, read_plain)
		}
		na, nb := value_length(a), value_length(b)
		ia, ib := value_children(a), value_children(b)
		for _ in 0 ..< min(na, nb) {
			x, _ := value_child_next(&ia)
			y, _ := value_child_next(&ib)
			if c := compare(x, y, depth + 1, eq, too_deep, max_depth, read_plain, dups); c != 0 {
				return c
			}
		}
		return -1 if na < nb else (1 if na > nb else 0)
	case .Object:
		if is_wide(a) && is_wide(b) {
			ma, mb := sorted_members(a, dups), sorted_members(b, dups)
			defer delete(ma)
			defer delete(mb)
			return compare_members(ma, mb, depth, eq, too_deep, max_depth, read_plain, dups)
		}
		ka, kb := sorted_keys(a), sorted_keys(b)
		defer delete(ka)
		defer delete(kb)
		for i in 0 ..< min(len(ka), len(kb)) {
			if c := text_order(ka[i], kb[i]); c != 0 {
				return c
			}
		}
		if len(ka) != len(kb) {
			return -1 if len(ka) < len(kb) else 1
		}
		for k in ka {
			x, _ := value_member(a, k, dups)
			y, _ := value_member(b, k, dups)
			if c := compare(x, y, depth + 1, eq, too_deep, max_depth, read_plain, dups); c != 0 {
				return c
			}
		}
	}
	return 0
}

// The kind and the double a cell `v`, a `Plain` node of a delimited text, reads as against a value of kind `like`, by the cell
// rule of a schema: a number operand reads the text, quotes cut, with the loose grammar, a boolean one `true` and `false`, and a
// null one an unquoted `null`. `ok` is false for a value that is no such cell or whose text does not read so, which stays
// the string its format gives it. The digits of a number are `text`'s, which may live in `buf`.
@(private = "file")
plain_reading :: proc(v: Value, like: Kind, buf: []u8) -> (kind: Kind, f: f64, digits: string, ok: bool) {
	r, is_node := plain(v).(Node_Ref)
	if !is_node || int(r.node) >= len(r.doc.nodes) || r.doc.nodes[r.node].kind != .Plain {
		return
	}
	n := r.doc.nodes[r.node]
	text, got := doc_text(r.doc, r.node, buf)
	if !got {
		return
	}
	#partial switch like {
	case .Number:
		if num, _, _, loose := spell.number_loose(transmute([]u8)text, 0, u64(len(text))); loose {
			return .Number, number_f64(num, text), text, true
		}
	case .True, .False:
		if text == "true" || text == "false" {
			return .True if text == "true" else .False, 0, "", true
		}
	case .Null:
		if text == "null" && n.spelling & SPELLING_QUOTED == 0 {
			return .Null, 0, "", true
		}
	}
	return
}

// The order of `a` and `b` whose kinds differ, when one is a cell that reads as the other's kind. `read` is false otherwise.
@(private = "file")
compare_plain :: proc(a: Value, ka: Kind, b: Value, kb: Kind) -> (order: int, read: bool) {
	buf: [64]u8
	if kind, x, lx, ok := plain_reading(a, kb, buf[:]); ok {
		if kind != kb {
			return -1 if kind < kb else 1, true
		}
		if kind == .Number {
			hex: [HEX_ROOM]u8
			y, ly, _ := double_of(b, hex[:])
			return compare_numbers(x, lx, y, ly), true
		}
		return 0, true
	}
	if kind, y, ly, ok := plain_reading(b, ka, buf[:]); ok {
		if kind != ka {
			return -1 if ka < kind else 1, true
		}
		if kind == .Number {
			hex: [HEX_ROOM]u8
			x, lx, _ := double_of(a, hex[:])
			return compare_numbers(x, lx, y, ly), true
		}
		return 0, true
	}
	return 0, false
}

// The order of two numbers read as doubles `x` and `y` and the digits `lx` and `ly` they keep, "" for a double with
// none. Neither double is nan. Doubles of two numbers are ordered as the numbers are, so only numbers of one double
// are told apart, by their decimals, and a double stands for its shortest decimal.
@(private = "file")
compare_numbers :: proc(x: f64, lx_in: string, y: f64, ly_in: string) -> int {
	lx, ly := lx_in, ly_in
	if x != y {
		return -1 if x < y else 1
	}
	if lx == ly {
		return 0
	}
	buf: [spell.F64_ROOM]u8
	if math.is_inf(x) {
		// An infinity is above every literal, and below none.
		if lx == "" || ly == "" {
			return (1 if x > 0 else -1) * (1 if lx == "" else -1)
		}
	} else if lx == "" || ly == "" {
		short := string(buf[:spell.f64_text(&buf[0], x)])
		lx, ly = lx if lx != "" else short, ly if ly != "" else short
	}
	return spell.decimal_compare(spell.decimal_of(lx), spell.decimal_of(ly))
}

// Whether `a` and `b` are equal: `compare` with `eq` gives 0.
equal :: proc(a, b: Value, too_deep: ^bool = nil, max_depth := MAX_DEPTH, read_plain := false, dups := Duplicates.Last) -> bool {
	return compare(a, b, eq = true, too_deep = too_deep, max_depth = max_depth, read_plain = read_plain, dups = dups) == 0
}

// Whether numbers `a` and `b` are of one type, an integer or a float, as TOML, YAML and CBOR tell them apart: a number
// spelled with a point, an exponent or a word (`1.0`, `1e2`, `inf`) is a float, and a hex, octal or binary one is an
// integer. A double, a number computed and spelled by no text, takes either, as does a number whose text does not fit
// the room read here.
same_number_type :: proc(a, b: Value) -> bool {
	fa, ka := float_spelled(a)
	fb, kb := float_spelled(b)
	return !ka || !kb || fa == fb
}

@(private = "file")
float_spelled :: proc(v: Value) -> (float, known: bool) {
	text: string
	buf: [64]u8
	#partial switch x in plain(v) {
	case Number_View:
		text = view_text(x)
	case Node_Ref:
		text = doc_number_text(x.doc, x.node, buf[:]) or_return
	case:
		return false, false
	}
	if len(text) > 0 && (text[0] == '-' || text[0] == '+') {
		text = text[1:]
	}
	if prefix := text[1] | 0x20 if len(text) > 2 && text[0] == '0' else 0; prefix == 'x' || prefix == 'o' || prefix == 'b' {
		return false, true
	}
	return text == "" || text[0] - '0' >= 10 || strings.contains_any(text, ".eE"), true
}

// Whether each number of `want` is of the type of the number at its place in `got`, a value equal to it, as
// `same_number_type` tells them apart.
same_number_types :: proc(want, got: Value, depth := 0) -> bool {
	if depth > MAX_DEPTH {
		return true
	}
	#partial switch value_kind(want) {
	case .Number:
		return same_number_type(want, got)
	case .Array:
		mine, theirs := value_children(want), value_children(got)
		for x in value_child_next(&mine) {
			y, _ := value_child_next(&theirs)
			if !same_number_types(x, y, depth + 1) {
				return false
			}
		}
	case .Object:
		it := value_pairs(want)
		for k, x in value_pair_next(&it) {
			y, _ := value_member(got, k)
			if !same_number_types(x, y, depth + 1) {
				return false
			}
		}
	}
	return true
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
compare_items :: proc(xs, ys: []Value, depth: int, eq: bool, too_deep: ^bool = nil, max_depth := MAX_DEPTH, read_plain := false, dups := Duplicates.Last) -> int {
	for i in 0 ..< min(len(xs), len(ys)) {
		if c := compare(xs[i], ys[i], depth + 1, eq, too_deep, max_depth, read_plain, dups); c != 0 {
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
compare_trails :: proc(a, b: Value, depth: int, eq: bool, too_deep: ^bool, max_depth: int, read_plain: bool) -> int {
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
				if c := compare_steps(sa, sb, depth, eq, too_deep, max_depth, read_plain); c != 0 {
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
	return compare_items(xs[0], xs[1], depth, eq, too_deep, max_depth, read_plain)
}

@(private = "file")
trail_depth :: #force_inline proc(t: Trail) -> int {
	return t.depth if t != nil else 0
}

// `compare` of the keys of two steps as deep, from the root. Steps both trails share are equal, so only the keys below
// them are compared.
@(private = "file")
compare_steps :: proc(a, b: ^Trail_Step, depth: int, eq: bool, too_deep: ^bool, max_depth: int, read_plain: bool) -> int {
	if a == b {
		return 0
	}
	if c := compare_steps(a.parent, b.parent, depth, eq, too_deep, max_depth, read_plain); c != 0 {
		return c
	}
	return compare(a.key, b.key, depth + 1, eq, too_deep, max_depth, read_plain)
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

// An object's members sorted by their keys' bytes, each key once with its last value, or its first under `.First`, in a
// slice made in the context allocator.
sorted_members :: proc(v: Value, dups := Duplicates.Last) -> []Member {
	ms := make([dynamic]Member, 0, value_length(v))
	it := value_pairs(v)
	for k, m in value_pair_next(&it) {
		append(&ms, Member{k, m})
	}
	slice.stable_sort_by(ms[:], proc(a, b: Member) -> bool {return a.key < b.key})
	// Of a run of one key, the first is the member that was added first and the last the member added last.
	kept := 0
	for m, i in ms {
		if dups == .First && i > 0 && ms[i - 1].key == m.key || dups != .First && i + 1 < len(ms) && ms[i + 1].key == m.key {
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
compare_members :: proc(a, b: []Member, depth: int, eq: bool, too_deep: ^bool = nil, max_depth := MAX_DEPTH, read_plain := false, dups := Duplicates.Last) -> int {
	for i in 0 ..< min(len(a), len(b)) {
		if c := text_order(a[i].key, b[i].key); c != 0 {
			return c
		}
	}
	if len(a) != len(b) {
		return -1 if len(a) < len(b) else 1
	}
	for m, i in a {
		if c := compare(m.val, b[i].val, depth + 1, eq, too_deep, max_depth, read_plain, dups); c != 0 {
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

// A hash of `v` that two equal values share: a number's is its double's when its literal is that double's shortest
// decimal, and its exact decimal otherwise. With `like` the value `v` is to be equal to, a cell reads as `like`'s kind
// as `compare` reads it, and a container's members read as the members of `like` at their keys or positions.
hash :: proc(v: Value, seed := u64(0xcbf29ce484222325), like: Value = nil, dups := Duplicates.Last) -> u64 {
	h := seed
	k := value_kind(v)
	f: f64
	digits: string
	read: bool
	buf: [64]u8
	hex: [HEX_ROOM]u8
	if like != nil && k != value_kind(like) {
		if kind, x, text, ok := plain_reading(v, value_kind(like), buf[:]); ok {
			k, f, digits, read = kind, x, text, true
		}
	}
	h = mix(h, u64(k))
	#partial switch k {
	case .Number:
		if !read {
			f, digits, _ = double_of(v, hex[:])
		}
		// A literal of at most DBL_DIG characters inside the normal range is its double's shortest decimal.
		if a := abs(f); digits != "" && !(len(digits) <= 15 && a > 1e-300 && a < 1e300) {
			if d := spell.decimal_of(digits); !shortest_of_double(d, f) {
				return mix_decimal(h, d)
			}
		}
		h = mix(h, transmute(u64)(f + 0)) // + 0: -0 and 0 are one number
	case .String, .Bytes:
		s := string_text(v)
		for b in transmute([]u8)s {
			h = mix(h, u64(b))
		}
		h = mix(h, u64(len(s)))
	case .Array:
		it, other := value_children(v), value_children(like) if value_kind(like) == .Array else Value_Iter{}
		for m in value_child_next(&it) {
			twin, _ := value_child_next(&other)
			h = mix(h, hash(m, seed, twin, dups))
		}
	case .Object:
		// The members are summed, so their order does not count. A repeated key counts once, with the value `dups` keeps.
		sum: u64
		members := sorted_members(v, dups)
		defer delete(members)
		for m in members {
			twin: Value
			if value_kind(like) == .Object {
				twin, _ = value_member(like, m.key, dups)
			}
			sum += mix(hash(m.key, seed), hash(m.val, seed, twin, dups))
		}
		h = mix(h, sum)
	}
	return h
}

// The points from which `mix_decimal` mixes only the sign of a point: no wide point is below them in magnitude.
@(private = "file")
POINT_CLASS :: i128(1e29)

// The hash `h` mixed with the exact value of `d`: its digits and its point, whichever way the literal splits its digits.
// A point past `POINT_CLASS` in magnitude is mixed as its sign, so no exponent is summed to hash it.
@(private = "file")
mix_decimal :: proc(seed: u64, d: spell.Decimal) -> u64 {
	h := mix(seed, u64(d.neg))
	for part in ([2]string{d.head, d.tail}) {
		for b in transmute([]u8)part {
			h = mix(h, u64(b))
		}
	}
	if d.wide == "" && abs(d.point) < POINT_CLASS {
		return mix(h, u64(d.point))
	}
	negative := d.wide_neg if d.wide != "" else d.point < 0
	return mix(mix(h, 0x7e57), u64(negative))
}

// Whether decimal `d`, a literal read as the double `f`, is the shortest decimal that double reads back from.
@(private = "file")
shortest_of_double :: proc(d: spell.Decimal, f: f64) -> bool {
	if d.head == "" {
		return true
	}
	if math.is_inf(f) || f == 0 {
		return false
	}
	if a := abs(f); len(d.head) + len(d.tail) <= 15 && a > 1e-300 && a < 1e300 {
		return true // at most DBL_DIG digits
	}
	buf: [spell.F64_ROOM]u8
	short := spell.decimal_of(string(buf[:spell.f64_text(&buf[0], f)]))
	return spell.decimal_compare(d, short) == 0
}

@(private = "file")
mix :: #force_inline proc(h, x: u64) -> u64 {
	return (h ~ x) * 0x100000001b3
}
