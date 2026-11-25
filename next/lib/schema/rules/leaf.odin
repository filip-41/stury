package rules

import "base:runtime"
import "core:slice"
import "core:strings"
import "stury:lib/base/kernel"
import "stury:lib/base/regex"
import "stury:lib/core/tape"

// Why a check refused a value or a rule failed.
Error_Kind :: enum u8 {
	None,
	Wrong_Kind,
	Not_Allowed,
	Below_Minimum,
	Above_Maximum,
	Not_Multiple,
	Too_Short,
	Too_Long,
	No_Match,
	Pattern_Undecided,
	Bad_Format,
	Too_Few,
	Too_Many,
	Not_Unique,
	Not_A_Member,
	Missing_Field,
	No_Arm,
	Many_Arms,
	Duplicate_Key,
	Exceeded,
	Walk,
	No_Memory,
	Bad_Option,
	Unsupported,
}

// The rules that a value fails, as a bit set of error kinds.
Failures :: bit_set[Error_Kind; u64]

// A bound as the check compares it: its exact decimal, and its value in `int` when `whole` says an i64 holds it.
Bound :: struct {
	set, exclusive, whole: bool,
	int:                   i64,
	exact:                 Decimal,
}

// The rules of one use of a node compiled for the check.
Leaf :: struct {
	kinds:                  Kinds,
	plain:                  Kinds, // `kinds` narrowed by the kinds of `enum`/`const` operands, for `Plain` tokens
	integer_spelled:        bool,
	has_enum:               bool,
	constant:               bool, // the enum index holds a `const`
	fast:                   bool,
	minimum, maximum:       Bound,
	multiple_of:            Maybe(Decimal),
	min_length, max_length: u64,
	min_items, max_items:   u64,
	min_members:            u64,
	max_members:            u64,
	pattern:                ^regex.Regex,
	formats:                bit_set[String_Format; u32], // every format the node or its use asserts
	enum_keys:              []string,
}

// The compiled `^regex.Regex` of each ECMA expression a plan reads, by expression, so that each is compiled once
// however many uses read it.
Programs :: map[string]^regex.Regex

// The `^regex.Regex` of the ECMA expression `expression`, compiled into `allocator` and kept in `programs`, when it
// is not nil, the first time it is asked for, or the error. Working memory for DFA construction comes from `scratch`.
program_of :: proc(programs: ^Programs, expression: string, allocator: runtime.Allocator, scratch := context.allocator) -> (re: ^regex.Regex, err: regex.Error) {
	if programs != nil {
		if kept, seen := programs[expression]; seen {
			return kept, {}
		}
	}
	compiled: regex.Regex
	if compiled, err = regex.compile(expression, .Ecma, {}, allocator, scratch); err.kind != .None {
		return nil, err
	}
	allocated: runtime.Allocator_Error
	re, allocated = new_clone(compiled, allocator)
	if allocated != nil {
		return nil, {.Memory, "out of memory"}
	}
	if programs != nil {
		programs[expression] = re
	}
	return re, {}
}

// The rules of `n` with the rules `edge` of one use added: the tighter bound and count of each pair.
merged :: proc(n: ^Node, edge: Rules) -> (r: Rules, refused: string) {
	r = n.rules
	if r.multiple_of != "" && edge.multiple_of != "" {
		if !valid_decimal_text(r.multiple_of) || !valid_decimal_text(edge.multiple_of) || decimal_compare(decimal_of(r.multiple_of), decimal_of(edge.multiple_of)) != 0 {
			return {}, "multipleOf"
		}
	}
	if r.pattern != "" && edge.pattern != "" && r.pattern != edge.pattern {
		return {}, "pattern"
	}
	r_assert := r.assert_format && !r.format_foreign && format_of(r.format) != .None
	e_assert := edge.assert_format && !edge.format_foreign && format_of(edge.format) != .None
	if r_assert && e_assert && format_of(r.format) != format_of(edge.format) {
		return {}, "format"
	}
	if r.markup != .Any && edge.markup != .Any && r.markup != edge.markup {
		return {}, "markup"
	}
	tighten(&r.minimum, &r.exclusive_minimum, edge.minimum, edge.exclusive_minimum, true)
	tighten(&r.maximum, &r.exclusive_maximum, edge.maximum, edge.exclusive_maximum, false)
	r.multiple_of = r.multiple_of if r.multiple_of != "" else edge.multiple_of
	r.pattern = r.pattern if r.pattern != "" else edge.pattern
	if e_assert && !r_assert {
		r.format, r.assert_format, r.format_foreign = edge.format, true, false
	} else if edge.format != "" && r.format == "" {
		r.format, r.assert_format, r.format_foreign = edge.format, edge.assert_format, edge.format_foreign
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
least :: proc "contextless" (a, b: Maybe(u64)) -> Maybe(u64) {
	x, have_a := a.?
	y, have_b := b.?
	return min(x, y) if have_a && have_b else (a if have_a else b)
}

// Compiles node `n`'s rules with the rules `edge` of its use added, allocating with `allocator`. A pattern that does
// not compile, an operand that is a container, and a `multipleOf`, `pattern`, `format`, or `markup` that both the node
// and the use set to conflicting values come back as the keyword the check does not judge.
leaf_of :: proc(n: ^Node, edge: Rules, allocator := context.allocator, programs: ^Programs = nil, scratch := context.allocator) -> (l: Leaf, refused: string) {
	r, clash := merged(n, edge)
	if clash != "" {
		return {}, clash
	}
	l, refused = kept_leaf(r, n.kinds, allocator, programs, scratch)
	l.integer_spelled = n.integer_spelled
	if edge.assert_format && !edge.format_foreign {
		l.formats += {format_of(edge.format)} - {.None}
	}
	operands := n.enum_of
	l.has_enum, l.constant = n.const_of != nil || n.has_enum, n.const_of != nil
	if c, has := n.const_of.?; has {
		operands = {c}
		if n.has_enum && !operand_in(c, n.enum_of, scratch) {
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
		k := value_kind(v)
		if k == .Object || k == .Array {
			delete(keys)
			return l, "const" if n.const_of != nil else "enum"
		}
		#partial switch k {
		case .Null:         held += {.Null}
		case .True, .False: held += {.Bool}
		case .Number:       held += {.Integer, .Number}
		case .String:       held += {.String}
		}
		if _, aerr := append(&keys, operand_key(v, k, allocator, scratch)); aerr != nil {
			delete(keys)
			return l, "enum"
		}
	}
	l.enum_keys, l.plain = keys[:], l.kinds & held
	enum_sort(l.enum_keys)
	return
}

// Whether scalar operand `c` is in `operands` by its enum index key, false for a container.
@(private)
operand_in :: proc(c: Value, operands: []Value, scratch: runtime.Allocator) -> bool {
	k := value_kind(c)
	if k == .Object || k == .Array {
		return false
	}
	want := operand_key(c, k, scratch, scratch)
	defer delete(want, scratch)
	for v in operands {
		vk := value_kind(v)
		if vk == k {
			other := operand_key(v, vk, scratch, scratch)
			same := other == want
			delete(other, scratch)
			if same {
				return true
			}
		}
	}
	return false
}

// Compiles the rules `r` on a value of `kinds`, allocating a pattern with `allocator`.
rules_leaf :: proc(r: Rules, kinds: Kinds, allocator := context.allocator, scratch := context.allocator) -> (l: Leaf, refused: string) {
	return kept_leaf(r, kinds, allocator, nil, scratch)
}

@(private = "file")
kept_leaf :: proc(r: Rules, kinds: Kinds, allocator: runtime.Allocator, programs: ^Programs, scratch: runtime.Allocator) -> (l: Leaf, refused: string) {
	l.kinds, l.plain = kinds, kinds
	// Clone decimal strings into `allocator` so `Decimal.{head,tail,wide}` never dangle after `Description` is destroyed!
	if r.minimum != "" {
		if !valid_decimal_text(r.minimum) {
			return l, "exclusiveMinimum" if r.exclusive_minimum else "minimum"
		}
		cloned, err := strings.clone(r.minimum, allocator)
		if err != nil {
			return l, "minimum"
		}
		l.minimum = bound_of(cloned, r.exclusive_minimum)
	}
	if r.maximum != "" {
		if !valid_decimal_text(r.maximum) {
			return l, "exclusiveMaximum" if r.exclusive_maximum else "maximum"
		}
		cloned, err := strings.clone(r.maximum, allocator)
		if err != nil {
			return l, "maximum"
		}
		l.maximum = bound_of(cloned, r.exclusive_maximum)
	}
	if r.multiple_of != "" {
		if !valid_decimal_text(r.multiple_of) {
			return l, "multipleOf"
		}
		cloned, err := strings.clone(r.multiple_of, allocator)
		if err != nil {
			return l, "multipleOf"
		}
		d := decimal_of(cloned)
		if !divisor_judged(d) {
			return l, "multipleOf"
		}
		l.multiple_of = d
	}
	l.fast = l.multiple_of == nil && (!l.minimum.set || l.minimum.whole) && (!l.maximum.set || l.maximum.whole)
	l.min_length, l.max_length = r.min_length, r.max_length.? or_else max(u64)
	l.min_items, l.max_items = r.min_items, r.max_items.? or_else max(u64)
	l.min_members, l.max_members = r.min_members, r.max_members.? or_else max(u64)
	if r.assert_format && !r.format_foreign {
		l.formats = {format_of(r.format)} - {.None}
	}
	if r.pattern != "" {
		err: regex.Error
		if l.pattern, err = program_of(programs, r.pattern, allocator, scratch); err.kind != .None {
			return l, "pattern"
		}
	}
	return
}

// Whether `l` judges nothing: it takes every kind and holds no rule.
trivial :: proc "contextless" (l: ^Leaf) -> bool {
	return l.kinds == EVERY_KIND && !l.has_enum && !l.minimum.set && !l.maximum.set && l.multiple_of == nil && l.pattern == nil && l.formats == {} && l.min_length == 0 && l.max_length == max(u64) && l.min_items == 0 && l.max_items == max(u64) && l.min_members == 0 && l.max_members == max(u64)
}

// The rules of `l` a string of `text`, decoded, fails. `steps` bounds regex search work (0 = engine default).
// Returns `.Pattern_Undecided` when the regex engine hits a step/memory limit (with `regex_err` set).
judge_string :: proc(l: ^Leaf, text: string, scratch: ^regex.Scratch, steps: u64 = 0, format_scratch := context.allocator) -> (fails: Failures, regex_err: regex.Error) {
	if l.min_length > 0 || l.max_length < max(u64) {
		n := u64(kernel.count_chars(transmute([]u8)text))
		if n < l.min_length {
			fails += {.Too_Short}
		}
		if n > l.max_length {
			fails += {.Too_Long}
		}
	}
	if l.pattern != nil {
		found: bool
		found, regex_err = regex.search(l.pattern, text, 0, nil, scratch, steps)
		if regex_err.kind != .None {
			fails += {.Pattern_Undecided}
		} else if !found {
			fails += {.No_Match}
		}
	}
	for f in l.formats {
		if !format_valid(f, text, format_scratch) {
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

// What a value that fails as `kind` should have met of `l`, spelled for a message. Allocated with `allocator`.
operand_text :: proc(l: ^Leaf, kind: Error_Kind, members: bool, allocator: runtime.Allocator) -> string {
	b := strings.builder_make(allocator)
	bound :: proc(b: ^strings.Builder, least: bool, n: u64, noun: string) {
		strings.write_string(b, "at least " if least else "at most ")
		strings.write_u64(b, n)
		if noun != "" {
			strings.write_byte(b, ' ')
			strings.write_string(b, noun)
			if n != 1 {
				strings.write_byte(b, 's')
			}
		}
	}
	#partial switch kind {
	case .Wrong_Kind:
		names := [Kind]string{.Null = "null", .Bool = "boolean", .Integer = "integer", .Number = "number", .String = "string", .Array = "array", .Object = "object"}
		kinds := l.kinds - ({.Integer} if .Number in l.kinds else {})
		k := 0
		for kd in kinds {
			strings.write_string(&b, (" or " if k == card(kinds) - 1 else ", ") if k > 0 else "")
			strings.write_string(&b, names[kd])
			k += 1
		}
	case .Too_Short:
		bound(&b, true, l.min_length, "character")
	case .Too_Long:
		bound(&b, false, l.max_length, "character")
	case .Too_Few:
		bound(&b, true, l.min_members if members else l.min_items, "member" if members else "element")
	case .Too_Many:
		bound(&b, false, l.max_members if members else l.max_items, "member" if members else "element")
	case .Below_Minimum, .Above_Maximum:
		low := kind == .Below_Minimum
		x := l.minimum if low else l.maximum
		strings.write_string(&b, ("greater than " if low else "less than ") if x.exclusive else "at least " if low else "at most ")
		if x.whole {
			strings.write_i64(&b, x.int)
		} else {
			write_decimal(&b, x.exact)
		}
	}
	return strings.to_string(b)
}

@(private)
tighten :: proc(have: ^string, flag: ^bool, text: string, strict, lower: bool) {
	if text != "" && (have^ == "" || tighter(text, have^, strict, flag^, lower) > 0) {
		have^, flag^ = text, strict
	}
}

// How bound `x` compares to `y` as a limit: >0 when `x` takes fewer values, <0 when more.
tighter :: proc "contextless" (x, y: string, strict_x, strict_y, lower: bool) -> int {
	order := decimal_compare(decimal_of(x), decimal_of(y))
	order = order if lower else -order
	switch {
	case order != 0:
		return order
	case strict_x != strict_y:
		return 1 if strict_x else -1
	}
	return 0
}

@(private)
bound_of :: proc "contextless" (text: string, exclusive: bool) -> (b: Bound) {
	if text == "" {
		return
	}
	b.set, b.exclusive, b.exact = true, exclusive, decimal_of(text)
	b.int, b.whole = decimal_i64(b.exact)
	return
}

// The number rules of `l` the number spelled `text` fails. `small` is its value when the text is a plain integer an
// i64 holds, which then decides a whole bound with no decimal read.
judge_number :: proc "contextless" (l: ^Leaf, text: string, small: Maybe(i64)) -> (fails: Failures) {
	if !l.minimum.set && !l.maximum.set && l.multiple_of == nil {
		return
	}
	v, is_small := small.?
	d: Decimal
	if l.minimum.set && !(is_small && l.minimum.whole) || l.maximum.set && !(is_small && l.maximum.whole) || l.multiple_of != nil {
		d = decimal_of(text)
	}
	if order := bound_order(l.minimum, v, is_small, d); l.minimum.set && (order < 0 || order == 0 && l.minimum.exclusive) {
		fails += {.Below_Minimum}
	}
	if order := bound_order(l.maximum, v, is_small, d); l.maximum.set && (order > 0 || order == 0 && l.maximum.exclusive) {
		fails += {.Above_Maximum}
	}
	if m, has := l.multiple_of.?; has {
		if whole, _ := decimal_multiple_of(d, m); !whole {
			fails += {.Not_Multiple}
		}
	}
	return
}

@(private = "file")
bound_order :: proc "contextless" (b: Bound, small: i64, is_small: bool, d: Decimal) -> int {
	if !b.set {
		return 0
	}
	if is_small && b.whole {
		return -1 if small < b.int else (1 if small > b.int else 0)
	}
	return decimal_compare(d, b.exact)
}

// Writes the key a scalar of kind `kind` has in an enum index: a letter for its kind, then a string's decoded `text`
// or a number's exact decimal as its digits and point, so that `1`, `1.0` and `10e-1` have one key.
enum_key :: proc(b: ^strings.Builder, kind: tape.Kind, text: string) {
	#partial switch kind {
	case .String:
		strings.write_byte(b, 's')
		strings.write_string(b, text)
	case .Number:
		d := decimal_of(text)
		strings.write_string(b, "n-" if d.neg else "n")
		strings.write_string(b, d.head)
		strings.write_string(b, d.tail)
		strings.write_byte(b, 'e')
		if d.head != "" {
			write_point(b, d)
		} else {
			strings.write_byte(b, '0')
		}
	case .True:
		strings.write_byte(b, 't')
	case .False:
		strings.write_byte(b, 'f')
	case:
		strings.write_byte(b, 'z')
	}
}

// Whether a scalar of kind `kind` and text `text`, a string's decoded, is in `l`'s enum index.
enum_has :: proc(l: ^Leaf, kind: tape.Kind, text: string, scratch := context.allocator) -> bool {
	_, found := enum_find(l.enum_keys, kind, text, scratch)
	return found
}

// The place among `keys`, sorted by `enum_sort`, of the key a scalar of kind `kind` and text `text` has in an enum
// index, and whether it is there. Allocates from `scratch` only for texts longer than 64 bytes, and frees before return.
enum_find :: proc(keys: []string, kind: tape.Kind, text: string, scratch := context.allocator) -> (int, bool) {
	if kind == .Object || kind == .Array {
		return 0, false
	}
	buf: [96]u8 = ---
	b := strings.builder_from_bytes(buf[:])
	heap := false
	if len(text) > 64 {
		b = strings.builder_make(0, len(text) + 32, scratch)
		heap = true
	}
	defer if heap {
		strings.builder_destroy(&b)
	}
	enum_key(&b, kind, text)
	return slice.binary_search_by(keys, strings.to_string(b), key_order)
}

// Sorts `keys`, an enum index's keys, in the index's order.
enum_sort :: proc(keys: []string) {
	slice.sort_by(keys, proc(a, b: string) -> bool {
		return key_order(a, b) == .Less
	})
}

@(private = "file")
key_order :: proc(a, b: string) -> slice.Ordering {
	if len(a) != len(b) {
		return .Less if len(a) < len(b) else .Greater
	}
	return slice.Ordering(strings.compare(a, b))
}

@(private = "file")
operand_key :: proc(v: Value, k: Value_Kind, allocator, scratch: runtime.Allocator) -> string {
	buf: [128]u8 = ---
	text := ""
	owned := false
	tk := value_to_tape_kind(k)
	#partial switch k {
	case .String:
		text, owned, _ = value_string(v, buf[:], scratch)
	case .Number:
		text, owned, _ = value_number_text(v, buf[:], scratch)
	}
	defer if owned {
		delete(text, scratch)
	}
	b := strings.builder_make(allocator)
	enum_key(&b, tk, text)
	return strings.to_string(b)
}
