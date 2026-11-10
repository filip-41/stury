package rules

import "base:runtime"
import "core:slice"
import "core:strings"
import regex "../regex"
import spell "../spell"
import core "../"

// A bound as the check compares it: its exact decimal, and its value in `int` when `whole` says an i64 holds it.
Bound :: struct {
	set, exclusive, whole: bool,
	int:                   i64,
	exact:                 spell.Decimal,
}

// The rules of one use of a node compiled for the check. A count is the elements of an array or the members of an
// object. `enum_keys` is the enum index: `enum_key` of each scalar operand of `enum` or `const`, by length and then by
// bytes, with `has_enum` set when the node has either. `integer_spelled` is draft 4's integer, which `1.0` is not.
// `fast` holds when an integer an i64 holds is judged by its value alone: no enum, no `multipleOf`, and every bound set
// is whole. `pattern` is the compiled `^regex.Regex`.
Leaf :: struct {
	kinds:                  Kinds,
	plain:                  Kinds, // `kinds` narrowed by the kinds of the `enum` and `const` operands, as a `Plain` token reads
	integer_spelled:        bool,
	has_enum:               bool,
	constant:               bool, // the enum index holds a `const`
	fast:                   bool,
	minimum, maximum:       Bound,
	multiple_of:            Maybe(spell.Decimal),
	min_length, max_length: u64,
	min_items, max_items:   u64,
	min_members:            u64,
	max_members:            u64,
	pattern:                rawptr,
	formats:                bit_set[String_Format; u32], // every format the node or its use asserts
	enum_keys:              []string,
}

// The rules of a number that a value fails, as the error kinds that report them.
Failures :: bit_set[core.Typed_Error_Kind; u64]

// The rules of `n` with the rules `edge` of one use added: the tighter bound and count of each pair. A `multipleOf` or
// `pattern` that both set to different values is `refused`, since both would hold. An asserted `format` of the use
// replaces a node's annotation.
merged :: proc(n: ^Node, edge: Rules) -> (r: Rules, refused: string) {
	r = n.rules
	if r.multiple_of != "" && edge.multiple_of != "" && r.multiple_of != edge.multiple_of {
		return {}, "multipleOf"
	}
	if r.pattern != "" && edge.pattern != "" && r.pattern != edge.pattern {
		return {}, "pattern"
	}
	tighten(&r.minimum, &r.exclusive_minimum, edge.minimum, edge.exclusive_minimum, true)
	tighten(&r.maximum, &r.exclusive_maximum, edge.maximum, edge.exclusive_maximum, false)
	r.multiple_of = r.multiple_of if r.multiple_of != "" else edge.multiple_of
	r.pattern = r.pattern if r.pattern != "" else edge.pattern
	if edge.format != "" && (r.format == "" || (edge.assert_format && !r.assert_format)) {
		r.format, r.assert_format = edge.format, edge.assert_format
	}
	r.unique ||= edge.unique
	r.read_only ||= edge.read_only
	r.write_only ||= edge.write_only
	r.markup = r.markup if r.markup != .Any else edge.markup
	r.min_length, r.min_items, r.min_members = max(r.min_length, edge.min_length), max(r.min_items, edge.min_items), max(r.min_members, edge.min_members)
	r.max_length, r.max_items, r.max_members = least(r.max_length, edge.max_length), least(r.max_items, edge.max_items), least(r.max_members, edge.max_members)
	return
}

@(private = "file")
least :: proc(a, b: Maybe(u64)) -> Maybe(u64) {
	x, have_a := a.?
	y, have_b := b.?
	return min(x, y) if have_a && have_b else (a if have_a else b)
}

// Compiles node `n`'s rules with the rules `edge` of its use added, allocating with `allocator`. A pattern that does
// not compile, an operand that is a container, and a `multipleOf` or `pattern` that both the node and the use set
// to different values come back as the keyword the check does not judge.
leaf_of :: proc(n: ^Node, edge: Rules, allocator := context.allocator) -> (l: Leaf, refused: string) {
	r, clash := merged(n, edge)
	if clash != "" {
		return {}, clash
	}
	l, refused = rules_leaf(r, n.kinds, allocator)
	l.integer_spelled = n.integer_spelled
	if edge.assert_format {
		l.formats += {format_of(edge.format)} - {.None}
	}
	operands := n.enum_of
	l.has_enum, l.constant = n.const_of != nil || n.has_enum, n.const_of != nil
	if c, has := n.const_of.?; has {
		// A `const` beside an `enum` takes its one value only when the enum holds it too, and else no value, as the enum.
		operands = {c}
		if n.has_enum && !operand_in(c, n.enum_of, allocator) {
			operands, l.constant = nil, false
		}
	}
	l.fast &&= !l.has_enum
	if !l.has_enum || refused != "" {
		return
	}
	keys := make([dynamic]string, 0, len(operands), allocator)
	held: Kinds
	for v in operands {
		k := core.value_kind(v)
		if k == .Object || k == .Array {
			return l, "const" if n.const_of != nil else "enum"
		}
		#partial switch k {
		case .Null:           held += {.Null}
		case .True, .False:   held += {.Bool}
		case .Number:         held += {.Integer, .Number}
		case .String:         held += {.String}
		}
		b := strings.builder_make(allocator)
		operand_key(&b, v, k, allocator)
		append(&keys, strings.to_string(b))
	}
	l.enum_keys, l.plain = keys[:], l.kinds & held
	slice.sort_by(l.enum_keys, key_less)
	return
}

// Whether the operand `c` is one of `operands` by the enum index's key, false for a container, which no index holds.
@(private)
operand_in :: proc(c: core.Value, operands: []core.Value, allocator: runtime.Allocator) -> bool {
	k := core.value_kind(c)
	if k == .Object || k == .Array {
		return false
	}
	want := strings.builder_make(allocator)
	operand_key(&want, c, k, allocator)
	for v in operands {
		if vk := core.value_kind(v); vk == k {
			b := strings.builder_make(allocator)
			operand_key(&b, v, vk, allocator)
			if strings.to_string(b) == strings.to_string(want) {
				return true
			}
		}
	}
	return false
}

// Compiles the rules `r` on a value of `kinds`, allocating a pattern with `allocator`. A pattern that does not compile
// comes back as "pattern", and a divisor `spell.decimal_multiple_of` does not judge exactly as "multipleOf".
rules_leaf :: proc(r: Rules, kinds: Kinds, allocator := context.allocator) -> (l: Leaf, refused: string) {
	l.kinds, l.plain = kinds, kinds
	l.minimum, l.maximum = bound_of(r.minimum, r.exclusive_minimum), bound_of(r.maximum, r.exclusive_maximum)
	if r.multiple_of != "" {
		d := spell.decimal_of(r.multiple_of)
		if d.saturated || len(d.head) + len(d.tail) > spell.MULTIPLE_DIGITS {
			return l, "multipleOf"
		}
		l.multiple_of = d
	}
	l.fast = l.multiple_of == nil && (!l.minimum.set || l.minimum.whole) && (!l.maximum.set || l.maximum.whole)
	l.min_length, l.max_length = r.min_length, r.max_length.? or_else max(u64)
	l.min_items, l.max_items = r.min_items, r.max_items.? or_else max(u64)
	l.min_members, l.max_members = r.min_members, r.max_members.? or_else max(u64)
	if r.assert_format {
		l.formats = {format_of(r.format)} - {.None}
	}
	if r.pattern != "" {
		re, err := regex.compile(r.pattern, {ecma = true}, allocator)
		if err != "" {
			return l, "pattern"
		}
		l.pattern = new_clone(re, allocator)
	}
	return
}

// Whether `l` judges nothing: it takes every kind and holds no rule.
trivial :: proc(l: ^Leaf) -> bool {
	return l.kinds == EVERY_KIND && !l.has_enum && !l.minimum.set && !l.maximum.set && l.multiple_of == nil && l.pattern == nil && l.formats == {} && l.min_length == 0 && l.max_length == max(u64) && l.min_items == 0 && l.max_items == max(u64) && l.min_members == 0 && l.max_members == max(u64)
}

// The rules of `l` a string of `text`, decoded, fails. A pattern the regex gives up on fails it.
judge_string :: proc(l: ^Leaf, text: string, scratch: ^regex.Scratch) -> (fails: Failures) {
	if l.min_length > 0 || l.max_length < max(u64) {
		n := code_points(text)
		if n < l.min_length {
			fails += {.Too_Short}
		}
		if n > l.max_length {
			fails += {.Too_Long}
		}
	}
	if l.pattern != nil {
		caps: [2]int
		if found, err := regex.search((^regex.Regex)(l.pattern), text, 0, caps[:], scratch); !found || err != "" {
			fails += {.No_Match}
		}
	}
	for f in l.formats {
		if !format_valid(f, text) {
			fails += {.Bad_Format}
		}
	}
	return
}

// Whether a count `n` of elements or members is below `low` or above `high`.
judge_count :: #force_inline proc "contextless" (n, low, high: u64) -> (fails: Failures) {
	if n < low {
		fails += {.Too_Few}
	}
	if n > high {
		fails += {.Too_Many}
	}
	return
}

// Narrows a bound in `have` to `text` where that is tighter, as two lower bounds or two upper bounds combine.
@(private)
tighten :: proc(have: ^string, flag: ^bool, text: string, strict, lower: bool) {
	if text == "" {
		return
	}
	if have^ != "" {
		order, _ := spell.decimal_compare(spell.decimal_of(text), spell.decimal_of(have^))
		if order == 0 {
			flag^ = flag^ || strict
			return
		}
		if (order > 0) != lower {
			return
		}
	}
	have^, flag^ = text, strict
}

@(private)
bound_of :: proc(text: string, exclusive: bool) -> (b: Bound) {
	if text == "" {
		return
	}
	b.set, b.exclusive, b.exact = true, exclusive, spell.decimal_of(text)
	b.int, b.whole = decimal_i64(b.exact)
	return
}

// The i64 an integral decimal holds, false for a fraction and past an i64.
decimal_i64 :: proc(d: spell.Decimal) -> (v: i64, ok: bool) {
	digits := len(d.head) + len(d.tail)
	if d.head == "" {
		return 0, true
	}
	if d.point < i128(digits) || d.point > 19 {
		return 0, false
	}
	m := u128(0)
	for s in ([2]string{d.head, d.tail}) {
		for c in transmute([]u8)s {
			m = m * 10 + u128(c - '0')
		}
	}
	for _ in digits ..< int(d.point) {
		m *= 10
	}
	if m > u128(max(i64)) + (1 if d.neg else 0) {
		return 0, false
	}
	return -i64(m) if d.neg else i64(m), true
}

// Whether a number is an integer: zero, or a decimal with no digit past its point.
integral :: proc(d: spell.Decimal) -> bool {
	return d.head == "" || d.point >= i128(len(d.head) + len(d.tail))
}

// The number rules of `l` the number spelled `text` fails. `small` is its value when the text is a plain integer an
// i64 holds, which then decides a whole bound with no decimal read.
judge_number :: proc(l: ^Leaf, text: string, small: Maybe(i64)) -> (fails: Failures) {
	if !l.minimum.set && !l.maximum.set && l.multiple_of == nil {
		return
	}
	v, is_small := small.?
	d: spell.Decimal
	if l.minimum.set && !(is_small && l.minimum.whole) || l.maximum.set && !(is_small && l.maximum.whole) || l.multiple_of != nil {
		d = spell.decimal_of(text)
	}
	if order := bound_order(l.minimum, v, is_small, d); l.minimum.set && (order < 0 || order == 0 && l.minimum.exclusive) {
		fails += {.Below_Minimum}
	}
	if order := bound_order(l.maximum, v, is_small, d); l.maximum.set && (order > 0 || order == 0 && l.maximum.exclusive) {
		fails += {.Above_Maximum}
	}
	if m, has := l.multiple_of.?; has && !multiple(d, m) {
		fails += {.Not_Multiple}
	}
	return
}

// The order of a number against bound `b`: by `small` when both are whole, else by the decimal `d`.
@(private)
bound_order :: proc(b: Bound, small: i64, is_small: bool, d: spell.Decimal) -> int {
	if !b.set {
		return 0
	}
	if is_small && b.whole {
		return -1 if small < b.int else (1 if small > b.int else 0)
	}
	order, _ := spell.decimal_compare(d, b.exact)
	return order
}

// Whether `x` is a whole multiple of `m`. A number whose exponent saturates is not judged exactly, and is no multiple.
@(private)
multiple :: proc(x, m: spell.Decimal) -> bool {
	whole, exact := spell.decimal_multiple_of(x, m)
	return whole && exact
}

// The code points of the UTF-8 text `s`.
@(private)
code_points :: proc "contextless" (s: string) -> u64 {
	n := u64(0)
	for i in 0 ..< len(s) {
		n += u64(s[i] & 0xC0 != 0x80)
	}
	return n
}

// Writes the key a scalar of kind `kind` has in an enum index: a letter for its kind, then a string's decoded `text`
// or a number's exact decimal as its digits and point, so that `1`, `1.0` and `10e-1` have one key.
@(private)
enum_key :: proc(b: ^strings.Builder, kind: core.Kind, text: string) {
	#partial switch kind {
	case .String:
		strings.write_byte(b, 's')
		strings.write_string(b, text)
	case .Number:
		d := spell.decimal_of(text)
		strings.write_string(b, "n-" if d.neg else "n")
		strings.write_string(b, d.head)
		strings.write_string(b, d.tail)
		strings.write_byte(b, 'e')
		strings.write_i64(b, i64(d.point) if d.head != "" else 0)
	case .True:
		strings.write_byte(b, 't')
	case .False:
		strings.write_byte(b, 'f')
	case:
		strings.write_byte(b, 'z')
	}
}

// Whether a scalar of kind `kind` and text `text`, a string's decoded, is in `l`'s enum index.
enum_has :: proc(l: ^Leaf, kind: core.Kind, text: string) -> bool {
	if kind == .Object || kind == .Array {
		return false
	}
	// A number's key is at most its text, its sign, the point's digits and a letter.
	buf: [96]u8
	b := strings.builder_from_bytes(buf[:])
	if len(text) > 64 {
		b = strings.builder_make(context.temp_allocator)
	}
	enum_key(&b, kind, text)
	_, found := slice.binary_search_by(l.enum_keys, strings.to_string(b), key_order)
	return found
}

@(private)
key_less :: proc(a, b: string) -> bool {
	return key_order(a, b) == .Less
}

@(private)
key_order :: proc(a, b: string) -> slice.Ordering {
	if len(a) != len(b) {
		return .Less if len(a) < len(b) else .Greater
	}
	return slice.Ordering(strings.compare(a, b))
}

@(private)
operand_key :: proc(b: ^strings.Builder, v: core.Value, k: core.Kind, allocator := context.allocator) {
	text: string
	#partial switch k {
	case .String:
		if r, is_node := core.plain(v).(core.Node_Ref); is_node {
			text, _ = core.text_clone(r.doc, r.node, allocator)
		} else {
			text, _ = core.text(v, nil)
		}
	case .Number:
		f, digits, _ := core.double_of(v)
		text = digits
		if digits == "" {
			buf := make([]u8, spell.F64_ROOM, allocator)
			text = string(buf[:spell.f64_text(&buf[0], f)])
		}
	}
	enum_key(b, k, text)
}
