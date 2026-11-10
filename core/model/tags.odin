package model

import "base:intrinsics"
import "base:runtime"
import "core:strings"
import regex "../regex"
import spell "../spell"
import rules "../rules"
import typed "../typed"

// What a type's values can be that a rule judges: text, an integer, a float, or a list or a map, which have a count.
@(private)
Value_Kind :: enum {
	Text,
	Integer,
	Float,
	List,
	Map,
}

@(private)
Value_Kinds :: bit_set[Value_Kind]

// The kinds a value of `ti` can be, through its `Maybe`s and pointers and each arm of a union.
@(private)
value_kinds :: proc(ti: ^runtime.Type_Info) -> (k: Value_Kinds) {
	#partial switch v in runtime.type_info_base(ti).variant {
	case runtime.Type_Info_String:
		k = {.Text}
	case runtime.Type_Info_Integer:
		k = {.Integer}
	case runtime.Type_Info_Float:
		k = {.Float}
	case runtime.Type_Info_Slice, runtime.Type_Info_Dynamic_Array, runtime.Type_Info_Array, runtime.Type_Info_Enumerated_Array, runtime.Type_Info_Fixed_Capacity_Dynamic_Array:
		k = {.List}
	case runtime.Type_Info_Map:
		k = {.Map}
	case runtime.Type_Info_Pointer:
		k = value_kinds(v.elem) if v.elem != nil else {}
	case runtime.Type_Info_Union:
		for arm in v.variants {
			k += value_kinds(arm)
		}
	}
	return
}

// What a rule can be checked against at compile time: the kinds of a value, the length of a fixed array and the limits of
// an integer type, each where the type is exactly one.
@(private)
Subject :: struct {
	kinds:  Value_Kinds,
	length: Maybe(u64),
	limits: Maybe([2]string),
}

// The subject of a value of `ti`, through its `Maybe`s and pointers.
@(private)
subject_of :: proc(ti: ^runtime.Type_Info) -> (s: Subject) {
	s.kinds = value_kinds(ti)
	base := ti
	for next := held(base); next != nil; next = held(base) {
		base = next
	}
	#partial switch v in runtime.type_info_base(base).variant {
	case runtime.Type_Info_Array:
		s.length = u64(v.count)
	case runtime.Type_Info_Integer:
		if base.size <= 8 {
			s.limits = LIMITS[intrinsics.count_trailing_zeros(base.size) + (0 if v.signed else 4)]
		}
	}
	return
}

// Reads a `model:` tag into `r`, for a value of `subject`, and for a member when `member`: items separated by commas,
// each a flag (`optional`, `extra`, `read_only`, `write_only`, or `-` alone), `alias=` and a name, a bound (`>=N`, `>N`, `<=N`,
// `<N`, a range `A..=B` or `A..<B`), `multiple_of=` and a divisor, the same bounds after `len` on a count of code points,
// elements or members (`len=N` for one count), `format=` and a format's name, or `pattern=` and an ECMA-262 pattern,
// which takes the rest of the tag, commas included. Spaces around an item, an operator and an operand are dropped. A
// rule tightens the rules `r` holds. The flags and `alias` are a member's. A bound on an integer is integral, and no
// rule may leave a value that passes. Returns false with the item it cannot read in `r.refused`.
@(private)
read_tag :: proc(tag: string, subject: Subject, member: bool, r: ^typed.Member_Rule) -> bool {
	rest := tag
	items, dashed := 0, false
	for len(rest) > 0 {
		item := rest
		if _, is_pattern := keyed(strings.trim_left_space(rest), "pattern"); !is_pattern {
			comma := strings.index_byte(rest, ',')
			item, rest = rest[:comma] if comma >= 0 else rest, rest[comma + 1:] if comma >= 0 else ""
		} else {
			rest = ""
		}
		item = strings.trim_space(item)
		if len(item) == 0 {
			continue
		}
		items += 1
		dashed ||= item == "-"
		if !read_item(item, subject, member, r) {
			r.refused = item
			return false
		}
	}
	if dashed && items > 1 {
		r.refused = "-"
		return false
	}
	return true
}

// The value of `item` when it is `key`, spaces, `=` and the value.
@(private)
keyed :: proc(item, key: string) -> (value: string, ok: bool) {
	if !strings.has_prefix(item, key) {
		return
	}
	rest := strings.trim_left_space(item[len(key):])
	if !strings.has_prefix(rest, "=") {
		return
	}
	return strings.trim_space(rest[1:]), true
}

@(private)
read_item :: proc(item: string, subject: Subject, member: bool, r: ^typed.Member_Rule) -> bool {
	kinds := subject.kinds
	alias, is_alias := keyed(item, "alias")
	switch {
	case r.skip && item != "-":
		return false
	case item == "optional" && member:
		r.optional = true
		return true
	case item == "-" && member:
		r.skip = true
		return !r.optional && r.name == "" && r.access == .Read_Write
	case item == "extra" && member:
		r.extra = true
		return true
	case (item == "read_only" || item == "write_only") && member:
		role := typed.Access.Read_Only if item == "read_only" else .Write_Only
		if r.access != .Read_Write && r.access != role {
			return false
		}
		r.access = role
		return true
	case is_alias && member:
		r.name, r.alias = alias, item
		return len(alias) > 0
	}
	one: rules.Rules
	format, is_format := keyed(item, "format")
	pattern, is_pattern := keyed(item, "pattern")
	divisor, is_divisor := keyed(item, "multiple_of")
	switch {
	case is_format:
		one.format, one.assert_format = format, true
		if .Text not_in kinds || rules.format_of(format) == .None {
			return false
		}
	case is_pattern:
		one.pattern = pattern
		if .Text not_in kinds || len(pattern) == 0 || !regex.valid(pattern, {ecma = true}) {
			return false
		}
	case is_divisor:
		one.multiple_of = divisor
		if !number_fits(divisor, kinds) || spell.decimal_of(divisor).neg || spell.decimal_of(divisor).head == "" {
			return false
		}
	case strings.has_prefix(item, "len"):
		if kinds & {.Text, .List, .Map} == {} || !read_counts(strings.trim_space(item[3:]), kinds, &one) {
			return false
		}
	case:
		if !read_bounds(item, kinds, &one) {
			return false
		}
	}
	merged, clash := rules.merged(&rules.Node{rules = r.rules}, one)
	if clash != "" || unsatisfiable(merged, subject) {
		return false
	}
	r.rules = merged
	return true
}

// Whether no value of `subject` passes `r`: a bound or a count above its other end, a count a fixed array's length is
// outside of, or a bound past the limits of an integer type.
@(private)
unsatisfiable :: proc(r: rules.Rules, subject: Subject) -> bool {
	past :: proc(low, high: string, exclusive: bool) -> bool {
		order := spell.decimal_compare(spell.decimal_of(low), spell.decimal_of(high))
		return order > 0 || order == 0 && exclusive
	}
	if r.minimum != "" && r.maximum != "" && past(r.minimum, r.maximum, r.exclusive_minimum || r.exclusive_maximum) {
		return true
	}
	if limits, bounded := subject.limits.?; bounded {
		if r.minimum != "" && past(r.minimum, limits[1], r.exclusive_minimum) || r.maximum != "" && past(limits[0], r.maximum, r.exclusive_maximum) {
			return true
		}
	}
	for c in ([?]struct {
			low:  u64,
			high: Maybe(u64),
		}{{r.min_length, r.max_length}, {r.min_items, r.max_items}, {r.min_members, r.max_members}}) {
		if high, bounded := c.high.?; bounded && c.low > high {
			return true
		}
	}
	n, fixed := subject.length.?
	return fixed && (r.min_items > n || (r.max_items.? or_else n) < n)
}

// Reads `>=N`, `>N`, `<=N`, `<N` or a range on a number into `r`.
@(private)
read_bounds :: proc(item: string, kinds: Value_Kinds, r: ^rules.Rules) -> bool {
	if low, high, upto, ranged := range_of(item); ranged {
		r.minimum, r.maximum, r.exclusive_maximum = low, high, upto
		return number_fits(low, kinds) && number_fits(high, kinds)
	}
	op := item[:2] if strings.has_prefix(item, ">=") || strings.has_prefix(item, "<=") else item[:1]
	value := strings.trim_space(item[len(op):])
	switch op {
	case ">=", ">":
		r.minimum, r.exclusive_minimum = value, op == ">"
	case "<=", "<":
		r.maximum, r.exclusive_maximum = value, op == "<"
	case:
		return false
	}
	return number_fits(value, kinds)
}

// Reads what follows `len` into `r`'s counts of what `kinds` count: a bound, `=N`, or `=` and a range.
@(private)
read_counts :: proc(text: string, kinds: Value_Kinds, r: ^rules.Rules) -> bool {
	low, high: Maybe(u64)
	if a, b, upto, ranged := range_of(text[1:] if strings.has_prefix(text, "=") else ""); ranged {
		lo, lo_ok := count_of(a)
		hi, hi_ok := count_of(b)
		if !lo_ok || !hi_ok || upto && hi == 0 {
			return false
		}
		low, high = lo, hi - 1 if upto else hi
	} else {
		op := text[:2] if strings.has_prefix(text, ">=") || strings.has_prefix(text, "<=") else text[:min(len(text), 1)]
		n, ok := count_of(strings.trim_space(text[len(op):]))
		switch {
		case !ok:
			return false
		case op == "=":
			low, high = n, n
		case op == ">=" || op == ">" && n < max(u64):
			low = n + 1 if op == ">" else n
		case op == "<=" || op == "<" && n > 0:
			high = n - 1 if op == "<" else n
		case:
			return false
		}
	}
	for at in ([?]struct {
			kind:     Value_Kind,
			min:      ^u64,
			max:      ^Maybe(u64),
		}{{.Text, &r.min_length, &r.max_length}, {.List, &r.min_items, &r.max_items}, {.Map, &r.min_members, &r.max_members}}) {
		if at.kind in kinds {
			at.min^ = low.? or_else 0
			at.max^ = high
		}
	}
	return true
}

// Splits `A..=B` or `A..<B` into its ends, with `upto` for `..<`.
@(private)
range_of :: proc(text: string) -> (low, high: string, upto, ok: bool) {
	at := strings.index(text, "..")
	if at < 0 || at + 2 >= len(text) || text[at + 2] != '=' && text[at + 2] != '<' {
		return
	}
	return strings.trim_space(text[:at]), strings.trim_space(text[at + 3:]), text[at + 2] == '<', true
}

// A count: ASCII digits with no leading zero that a u64 holds.
@(private)
count_of :: proc(text: string) -> (n: u64, ok: bool) {
	ok = len(text) > 0 && (text[0] != '0' || len(text) == 1)
	for c in transmute([]u8)text {
		ok &&= c >= '0' && c <= '9' && n <= (max(u64) - u64(c - '0')) / 10
		n = n * 10 + u64(c - '0')
	}
	return
}

// Whether `text` is a JSON number that bounds a value of `kinds`: one that may be a number, and integral when it can
// only be an integer.
@(private)
number_fits :: proc(text: string, kinds: Value_Kinds) -> bool {
	if _, ok := spell.number_strict(transmute([]u8)text, 0, u64(len(text))); !ok || kinds & {.Integer, .Float} == {} {
		return false
	}
	return .Float in kinds || rules.integral(spell.decimal_of(text))
}
