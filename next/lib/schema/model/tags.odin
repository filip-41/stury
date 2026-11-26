// `model:` and format struct tag parsing and compile-time satisfiability checks.
package model

import "base:intrinsics"
import "base:runtime"
import "core:strings"
import "stury:lib/base/regex"
import "stury:lib/base/spell"
import "stury:lib/schema/rules"

@(private)
Value_Kind :: enum u8 { Text, Integer, Float, List, Map }

@(private)
Value_Kinds :: bit_set[Value_Kind; u8]

// What a rule can be checked against at compile time.
@(private)
Subject :: struct {
	kinds:   Value_Kinds,
	length:  Maybe(u64),
	limits:  Maybe([2]string),
	nilable: bool,
}

// Parsed rules for one struct member or standalone type.
@(private)
Member_Rule :: struct {
	rules:    rules.Rules,
	optional: bool,
	not_null: bool,
	access:   Access,
	refused:  string,
}

// Parsed format struct tag (`json:"..."`, `toml:"..."`, `stury:"..."`, etc.).
@(private)
Format_Tag :: struct {
	name:                                                string,
	has_name, skip, omit_empty, omit_unset, required, unknown: bool,
}

// Parses format tag `tag_key` (falling back to `"stury"`) from Odin struct tag string `raw_tag`.
@(private)
parse_format_tag :: proc(raw_tag, tag_key: string) -> (ft: Format_Tag) {
	val, found := tag_lookup(raw_tag, tag_key)
	if !found && tag_key != "stury" { val, found = tag_lookup(raw_tag, "stury") }
	if !found || len(val) == 0 { return }
	if val == "-" { ft.skip = true; return }
	first := true
	for rest := val; len(rest) > 0; {
		comma := strings.index_byte(rest, ',')
		part := rest[:comma] if comma >= 0 else rest
		rest = rest[comma + 1:] if comma >= 0 else ""
		if first {
			first = false
			if len(part) > 0 { ft.name, ft.has_name = part, true }
			continue
		}
		switch strings.trim_space(part) {
		case "omitempty": ft.omit_empty = true
		case "omitunset": ft.omit_unset = true
		case "required":  ft.required = true
		case "unknown":   ft.unknown = true
		}
	}
	return
}

// Looks up `key:"value"` inside an Odin struct tag string.
@(private)
tag_lookup :: proc(tag, key: string) -> (string, bool) {
	for t := tag; len(t) > 0; {
		t = strings.trim_left(t, " ")
		k := 0
		for k < len(t) && t[k] > ' ' && t[k] != ':' && t[k] != '"' { k += 1 }
		if k == 0 || k + 1 >= len(t) || t[k] != ':' || t[k + 1] != '"' { return "", false }
		name := t[:k]; t = t[k + 2:]
		e := 0
		for e < len(t) && t[e] != '"' { if t[e] == '\\' { e += 1 }; e += 1 }
		if e >= len(t) { return "", false }
		if name == key { return t[:e], true }
		t = t[e + 1:]
	}
	return "", false
}

// The value kinds `ti` can hold, traversing `Maybe`/pointer wrappers and union arms.
@(private)
value_kinds :: proc(ti: ^runtime.Type_Info, reg: ^Registry) -> (k: Value_Kinds) {
	if ti == nil { return {} }
	id := carried(reg, ti.id)
	if c, is_carrier := carrier_of(id); is_carrier { return c.subject }
	if id != ti.id { return value_kinds(type_info_of(id), reg) }
	if is_number_text_type(ti) { return {.Float} }
	#partial switch v in runtime.type_info_base(ti).variant {
	case ^runtime.Type_Info_String:  k = {.Text}
	case ^runtime.Type_Info_Integer: k = {.Integer}
	case ^runtime.Type_Info_Float:   k = {.Float}
	case ^runtime.Type_Info_Slice:   k = {.Text} if runtime.type_info_base(ti).id == []u8 else {.List}
	case ^runtime.Type_Info_Dynamic_Array, ^runtime.Type_Info_Array, ^runtime.Type_Info_Enumerated_Array, ^runtime.Type_Info_Fixed_Capacity_Dynamic_Array, ^runtime.Type_Info_Bit_Set:
		k = {.List}
	case ^runtime.Type_Info_Map:     k = {.Map}
	case ^runtime.Type_Info_Pointer: k = value_kinds(v.elem, reg) if v.elem != nil else {}
	case ^runtime.Type_Info_Union:   for arm in v.variants { k += value_kinds(arm, reg) }
	}
	return
}

// Compile-time subject of `ti` through its `Maybe`/pointer wrappers.
@(private)
subject_of :: proc(ti: ^runtime.Type_Info, reg: ^Registry) -> (s: Subject) {
	if ti == nil { return }
	s.kinds = value_kinds(ti, reg)
	s.nilable = held_type(ti) != nil || is_number_text_type(ti)
	if str, is_str := runtime.type_info_base(ti).variant.(^runtime.Type_Info_String); is_str && str.is_cstring { s.nilable = true }
	base := ti
	for next := held_type(base); next != nil; next = held_type(base) { base = next }
	#partial switch v in runtime.type_info_base(base).variant {
	case ^runtime.Type_Info_Array:   s.length = u64(v.count)
	case ^runtime.Type_Info_Integer: if base.size <= 8 { s.limits = LIMITS[intrinsics.count_trailing_zeros(base.size) + (0 if v.signed else 4)] }
	}
	return
}

// Parses a `model:` tag into `r` for a value of `subject`.
// Under `swallows`, refuses a `pattern=` whose text after a comma parses as another tag item.
@(private)
read_tag :: proc(tag: string, subject: Subject, member: bool, r: ^Member_Rule, scratch: runtime.Allocator, swallows := false) -> bool {
	for rest := tag; len(rest) > 0; {
		item := rest
		if pattern, is_pattern := keyed(strings.trim_left_space(rest), "pattern"); !is_pattern {
			comma := strings.index_byte(rest, ',')
			item = rest[:comma] if comma >= 0 else rest
			rest = rest[comma + 1:] if comma >= 0 else ""
		} else {
			rest = ""
			if swallows && holds_item(pattern, scratch) { r.refused = strings.trim_space(item); return false }
		}
		item = strings.trim_space(item)
		if len(item) > 0 && !read_item(item, subject, member, r, scratch) { r.refused = item; return false }
	}
	return true
}

@(private)
holds_item :: proc(pattern: string, scratch: runtime.Allocator) -> bool {
	any_value := Subject{kinds = {.Text, .Integer, .Float, .List, .Map}, nilable = true}
	rest := pattern
	for comma := strings.index_byte(rest, ','); comma >= 0; comma = strings.index_byte(rest, ',') {
		rest = rest[comma + 1:]
		next := strings.index_byte(rest, ',')
		item := strings.trim_space(rest[:next] if next >= 0 else rest)
		tmp: Member_Rule
		if len(item) > 0 && read_item(item, any_value, true, &tmp, scratch) { return true }
	}
	return false
}

@(private)
keyed :: proc(item, key: string) -> (value: string, ok: bool) {
	if !strings.has_prefix(item, key) { return }
	rest := strings.trim_left_space(item[len(key):])
	if !strings.has_prefix(rest, "=") { return }
	return strings.trim_space(rest[1:]), true
}

@(private)
read_item :: proc(item: string, subject: Subject, member: bool, r: ^Member_Rule, scratch: runtime.Allocator) -> bool {
	kinds := subject.kinds
	switch {
	case item == "optional" && member: r.optional = true; return true
	case item == "not_null" && member: r.not_null = true; return subject.nilable
	case (item == "read_only" || item == "write_only") && member:
		role := Access.Read_Only if item == "read_only" else .Write_Only
		if r.access != .Read_Write && r.access != role { return false }
		r.access = role; return true
	}
	one: rules.Rules
	format, is_format := keyed(item, "format")
	pattern, is_pattern := keyed(item, "pattern")
	divisor, is_divisor := keyed(item, "multiple_of")
	switch {
	case item == "unique":
		one.unique = true; if .List not_in kinds { return false }
	case is_format:
		one.format, one.assert_format = format, true; if .Text not_in kinds || rules.format_of(format) == .None { return false }
	case is_pattern:
		one.pattern = pattern
		if .Text not_in kinds || len(pattern) == 0 || regex.refusal(pattern, .Ecma, {}, scratch, scratch).kind != .None { return false }
	case is_divisor:
		one.multiple_of = divisor; d := rules.decimal_of(divisor)
		if !number_fits(divisor, kinds) || d.neg || d.head == "" { return false }
	case strings.has_prefix(item, "len"):
		if kinds & {.Text, .List, .Map} == {} || !read_counts(strings.trim_space(item[3:]), kinds, &one) { return false }
	case:
		if !read_bounds(item, kinds, &one) { return false }
	}
	base_node := rules.Node{rules = r.rules}
	merged_rules, clash := rules.merged(&base_node, one)
	if clash != "" || unsatisfiable(merged_rules, subject) { return false }
	r.rules = merged_rules
	return true
}

@(private)
unsatisfiable :: proc(r: rules.Rules, subject: Subject) -> bool {
	past :: proc(low, high: string, exclusive: bool) -> bool {
		order := rules.decimal_compare(rules.decimal_of(low), rules.decimal_of(high))
		return order > 0 || order == 0 && exclusive
	}
	if r.minimum != "" && r.maximum != "" && past(r.minimum, r.maximum, r.exclusive_minimum || r.exclusive_maximum) { return true }
	if limits, bounded := subject.limits.?; bounded {
		if r.minimum != "" && past(r.minimum, limits[1], r.exclusive_minimum) || r.maximum != "" && past(limits[0], r.maximum, r.exclusive_maximum) { return true }
	}
	for c in ([?]struct { low: u64, high: Maybe(u64) }{{r.min_length, r.max_length}, {r.min_items, r.max_items}, {r.min_members, r.max_members}}) {
		if high, bounded := c.high.?; bounded && c.low > high { return true }
	}
	n, fixed := subject.length.?
	return fixed && (r.min_items > n || (r.max_items.? or_else n) < n)
}

@(private)
read_bounds :: proc(item: string, kinds: Value_Kinds, r: ^rules.Rules) -> bool {
	if low, high, upto, ranged := range_of(item); ranged {
		r.minimum, r.maximum, r.exclusive_maximum = low, high, upto
		return number_fits(low, kinds) && number_fits(high, kinds)
	}
	if len(item) == 0 { return false }
	op := item[:2] if strings.has_prefix(item, ">=") || strings.has_prefix(item, "<=") else item[:1]
	value := strings.trim_space(item[len(op):])
	switch op {
	case ">=", ">": r.minimum, r.exclusive_minimum = value, op == ">"
	case "<=", "<": r.maximum, r.exclusive_maximum = value, op == "<"
	case: return false
	}
	return number_fits(value, kinds)
}

@(private)
read_counts :: proc(text: string, kinds: Value_Kinds, r: ^rules.Rules) -> bool {
	low, high: Maybe(u64)
	if a, b, upto, ranged := range_of(text[1:] if strings.has_prefix(text, "=") else ""); ranged {
		lo, lo_ok := count_of(a); hi, hi_ok := count_of(b)
		if !lo_ok || !hi_ok || upto && hi == 0 { return false }
		low, high = lo, hi - 1 if upto else hi
	} else {
		op := text[:2] if strings.has_prefix(text, ">=") || strings.has_prefix(text, "<=") else text[:min(len(text), 1)]
		n, ok := count_of(strings.trim_space(text[len(op):]))
		switch {
		case !ok:                             return false
		case op == "=":                       low, high = n, n
		case op == ">=" || op == ">" && n < max(u64): low = n + 1 if op == ">" else n
		case op == "<=" || op == "<" && n > 0: low, high = nil, n - 1 if op == "<" else n
		case:                                 return false
		}
	}
	for at in ([?]struct { kind: Value_Kind, lo: ^u64, hi: ^Maybe(u64) }{{.Text, &r.min_length, &r.max_length}, {.List, &r.min_items, &r.max_items}, {.Map, &r.min_members, &r.max_members}}) {
		if at.kind in kinds { at.lo^ = low.? or_else 0; at.hi^ = high }
	}
	return true
}

@(private)
range_of :: proc(text: string) -> (low, high: string, upto, ok: bool) {
	at := strings.index(text, "..")
	if at < 0 || at + 2 >= len(text) || text[at + 2] != '=' && text[at + 2] != '<' { return }
	return strings.trim_space(text[:at]), strings.trim_space(text[at + 3:]), text[at + 2] == '<', true
}

@(private)
count_of :: proc(text: string) -> (n: u64, ok: bool) {
	ok = len(text) > 0 && (text[0] != '0' || len(text) == 1)
	for c in transmute([]u8)text {
		ok &&= c >= '0' && c <= '9' && n <= (max(u64) - u64(c - '0')) / 10
		n = n * 10 + u64(c - '0')
	}
	return
}

@(private)
number_fits :: proc(text: string, kinds: Value_Kinds) -> bool {
	if _, ok := spell.number_strict(transmute([]u8)text, 0, u64(len(text))); !ok || kinds & {.Integer, .Float} == {} { return false }
	return .Float in kinds || rules.integral(rules.decimal_of(text))
}
