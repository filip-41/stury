package yaml

import "core:math"
import spell "../core/spell"
import core "../core"
import write "../core/write"

// What a plain scalar's text is under the YAML core schema.
@(private)
Class :: enum u8 {
	Text,
	Null,
	False,
	True,
	Decimal, // an integer or a float, in the forms `spell.number_loose` reads
	Hex,
	Octal,
	Inf,
	Nan,
}

@(private)
classify :: proc(text: []u8) -> Class {
	class, _, _, _ := classify_number(text)
	return class
}

// `classify`, with a `Decimal` text's value, whether it is a plain integer and whether the strict grammar reads it,
// as `spell.number_loose` gives them.
@(private)
classify_number :: proc(text: []u8) -> (class: Class, num: core.Number, integer, strict: bool) {
	if len(text) == 0 {
		return .Null, {}, false, false
	}
	switch text[0] {
	case '0' ..= '9':
		// No word of the schema starts with a digit.
		if len(text) > 2 && text[0] == '0' {
			switch text[1] {
			case 'x':
				return .Hex if all_digits(text[2:], 16) else .Text, {}, false, false
			case 'o':
				return .Octal if all_digits(text[2:], 8) else .Text, {}, false, false
			}
		}
		return decimal(text)
	case '~':
		if len(text) == 1 {
			return .Null, {}, false, false
		}
		return .Text, {}, false, false
	}
	switch string(text) {
	case "null", "Null", "NULL":
		return .Null, {}, false, false
	case "true", "True", "TRUE":
		return .True, {}, false, false
	case "false", "False", "FALSE":
		return .False, {}, false, false
	case ".inf", ".Inf", ".INF", "+.inf", "+.Inf", "+.INF", "-.inf", "-.Inf", "-.INF":
		return .Inf, {}, false, false
	case ".nan", ".NaN", ".NAN":
		return .Nan, {}, false, false
	}
	switch text[0] {
	case '+', '-', '.':
		return decimal(text)
	}
	return .Text, {}, false, false

	decimal :: proc(text: []u8) -> (class: Class, num: core.Number, integer, strict: bool) {
		ok: bool
		num, integer, strict, ok = spell.number_loose(text, 0, u64(len(text)))
		return .Decimal if ok else .Text, num, integer, strict
	}
}

@(private)
all_digits :: proc "contextless" (s: []u8, base: u8) -> bool {
	for b in s {
		d := b - '0' if b <= '9' else (b | 0x20) - 'a' + 10
		if b < '0' || b > '9' && (b | 0x20) < 'a' || d >= base {
			return false
		}
	}
	return true
}

// The core schema types a tag may name.
@(private)
Core_Type :: enum u8 {
	None, // a tag of no core type: local, of another schema, or of a collection
	Str,
	Int,
	Float,
	Bool,
	Null,
}

// Each core type's tag in full.
@(private, rodata)
CORE_TAGS := [Core_Type]string {
	.None  = "",
	.Str   = "tag:yaml.org,2002:str",
	.Int   = "tag:yaml.org,2002:int",
	.Float = "tag:yaml.org,2002:float",
	.Bool  = "tag:yaml.org,2002:bool",
	.Null  = "tag:yaml.org,2002:null",
}

@(private)
CORE_PREFIX :: "tag:yaml.org,2002:"

// A tag's handle and suffix: `!!int` is `!!` and `int`, `!x` is `!` and `x`, and `!<uri>` is no handle and the uri.
@(private)
tag_parts :: proc "contextless" (tag: string) -> (handle, suffix: string) {
	if len(tag) > 1 && tag[1] == '<' {
		return "", tag[2:len(tag) - 1]
	}
	for k := len(tag) - 1; k > 0; k -= 1 {
		if tag[k] == '!' {
			return tag[:k + 1], tag[k + 1:]
		}
	}
	return tag[:1], tag[1:]
}

// The core type the tag of `handle` and `suffix` names, where `prefix` is what a `%TAG` directive made the handle and
// `declared` says one did. With no directive `!!` is `tag:yaml.org,2002:` and `!` is itself.
@(private)
core_type :: proc "contextless" (handle, suffix, prefix: string, declared: bool) -> Core_Type {
	head := prefix
	if !declared {
		head = CORE_PREFIX if handle == "!!" else handle
	}
	for name, ct in CORE_TAGS {
		if ct != .None && len(head) + len(suffix) == len(name) && name[:len(head)] == head && name[len(head):] == suffix {
			return ct
		}
	}
	return .None
}

// The prefix the `%TAG` directive of `src`'s document gives `handle`. The directives are the lines starting with `%`
// before the document's first other content line.
@(private)
declared_prefix :: proc "contextless" (src: []u8, handle: string) -> (prefix: string, found: bool) {
	i := int(core.text_start(src, 0))
	for i < len(src) {
		e := i
		for e < len(src) && src[e] != '\n' && src[e] != '\r' {
			e += 1
		}
		line := string(src[i:e])
		i = e + 1
		lead := 0
		for lead < len(line) && (line[lead] == ' ' || line[lead] == '\t') {
			lead += 1
		}
		if lead == len(line) || line[lead] == '#' {
			continue
		}
		if line[0] != '%' {
			return
		}
		h, rest := directive_word(line[1:])
		if h != "TAG" {
			continue
		}
		h, rest = directive_word(rest)
		if h == handle {
			prefix, _ = directive_word(rest)
			return prefix, true
		}
	}
	return
}

// The first word of `s` past its white space, and the text after it.
@(private)
directive_word :: proc "contextless" (s: string) -> (word, rest: string) {
	i := 0
	for i < len(s) && (s[i] == ' ' || s[i] == '\t') {
		i += 1
	}
	j := i
	for j < len(s) && s[j] != ' ' && s[j] != '\t' {
		j += 1
	}
	return s[i:j], s[j:]
}

// The core type the tag `tag` names in the document of `src`.
@(private)
doc_core_type :: proc "contextless" (src: []u8, tag: string) -> Core_Type {
	handle, suffix := tag_parts(tag)
	prefix: string
	declared: bool
	if handle != "" {
		prefix, declared = declared_prefix(src, handle)
	}
	return core_type(handle, suffix, prefix, declared)
}

// Whether a scalar of `class` has core type `type`. `integer` says a `Decimal` has no fraction or exponent.
@(private)
holds :: proc "contextless" (ct: Core_Type, class: Class, integer: bool) -> bool {
	switch ct {
	case .None, .Str: return true
	case .Int:        return class == .Hex || class == .Octal || class == .Decimal && integer
	case .Float:      return class == .Decimal || class == .Inf || class == .Nan
	case .Bool:       return class == .True || class == .False
	case .Null:       return class == .Null
	}
	return false
}

// The text of scalar `t`: its span, or its decode in `stack` when that fits and else in the temp allocator.
@(private)
scalar_text :: proc(src: []u8, t: core.Token, stack: []u8) -> string {
	span := src[t.lo:t.lo + u64(t.n)]
	if t.spelling & core.SPELLING_DECODE == 0 {
		return string(span)
	}
	if s, fits := decode(span, t.spelling, stack); fits {
		return s
	}
	s, _ := decode(span, t.spelling, make([]u8, 3 * len(span) + 4, context.temp_allocator))
	return s
}

// YAML's `Readers.text`, exported so a caller that knows the format calls it without the table. A plain scalar on one
// line returns its span, and any other scalar is decoded into `buf`, which `core.text_room` sizes. A container returns
// false.
text :: proc(v: ^core.Token_View, t: core.Token, buf: []u8) -> (s: string, ok: bool) {
	if t.kind > .Plain {
		return "", false
	}
	span := v.src[t.lo:t.lo + u64(t.n)]
	if t.spelling & core.SPELLING_DECODE == 0 {
		return string(span), true
	}
	return decode(span, t.spelling, buf)
}

// YAML's `Readers.resolve`: the kind a plain scalar has under the core schema. A key is text. A core tag gives its
// type, which the walk has checked the text holds, and any other tag makes the node text. A quoted scalar is `Plain`
// only under a core tag other than `!!str`.
@(private)
spelling_resolve :: proc(doc: ^core.Document, i: core.Node_Index) -> core.Kind {
	n := doc.nodes[i]
	if n.role != .Value {
		return .String
	}
	if len(doc.facts) != 0 {
		if tag, tagged := core.fact_value(doc, i, .Tag); tagged {
			#partial switch doc_core_type(doc.src, tag.text) {
			case .None, .Str:   return .String
			case .Int, .Float:  return .Number
			}
		}
	}
	stack: [64]u8 = ---
	switch classify(transmute([]u8)scalar_text(doc.src, n, stack[:])) {
	case .Text:                              return .String
	case .Null:                              return .Null
	case .False:                             return .False
	case .True:                              return .True
	case .Decimal, .Hex, .Octal, .Inf, .Nan: return .Number
	}
	return .String
}

// YAML's `Readers.number`, exported so a caller that knows the format calls it without the table: the value of a plain
// scalar that resolves to a number, in every form the core schema has.
number :: proc(v: ^core.Token_View, t: core.Token) -> (core.Number, bool) {
	if t.kind != .Plain && t.kind != .Number || t.role != .Value {
		return {}, false
	}
	stack: [64]u8 = ---
	text := transmute([]u8)scalar_text(v.src, t, stack[:])
	class, n, integer, _ := classify_number(text)
	switch class {
	case .Decimal:
		if integer && n.kind == .Float && n.bits == 1 << 63 {
			return {0, .Int}, true
		}
		return n, true
	case .Hex:
		return radix_number(text[2:], 16), true
	case .Octal:
		return radix_number(text[2:], 8), true
	case .Inf:
		return {transmute(u64)math.inf_f64(-1 if text[0] == '-' else 1), .Float}, true
	case .Nan:
		return {transmute(u64)math.nan_f64(), .Float}, true
	case .Text, .Null, .False, .True:
	}
	return {}, false
}

// YAML's `Readers.number_text`: the JSON digits of a plain scalar that resolves to a number. A decimal JSON reads
// returns its text, another decimal form, a hex and an octal integer are written into `buf`, and an infinity and a
// NaN, which have no digits, return an empty text.
@(private)
number_text :: proc(v: ^core.Token_View, t: core.Token, buf: []u8) -> (s: string, ok: bool) {
	stack: [64]u8 = ---
	text := scalar_text(v.src, t, stack[:])
	class, _, _, strict := classify_number(transmute([]u8)text)
	switch class {
	case .Decimal:
		if !strict {
			return json_decimal(text, buf)
		}
		if t.spelling & core.SPELLING_DECODE == 0 {
			return string(v.src[t.lo:t.lo + u64(t.n)]), true
		}
		if len(buf) < len(text) {
			return "", false
		}
		return string(buf[:copy(buf, text)]), true
	case .Hex, .Octal:
		// `write.number_text` writes into a reservation of this many bytes.
		if len(buf) < 48 {
			return "", false
		}
		size, _ := write.number_text(raw_data(buf), radix_number(transmute([]u8)text[2:], 16 if text[1] == 'x' else 8))
		return string(buf[:size]), true
	case .Inf, .Nan:
		return "", true
	case .Text, .Null, .False, .True:
	}
	return "", true
}

// Decimal `text` as JSON writes it, into `buf`: no `+`, no leading zeros, a digit on each side of a point.
@(private)
json_decimal :: proc "contextless" (text: string, buf: []u8) -> (s: string, ok: bool) {
	if len(buf) < len(text) + 1 {
		return "", false
	}
	out := 0
	k := 0
	if text[0] == '+' || text[0] == '-' {
		if text[0] == '-' {
			buf[0] = '-'
			out = 1
		}
		k = 1
	}
	lead := k
	for k < len(text) && text[k] >= '0' && text[k] <= '9' {
		k += 1
	}
	whole := text[lead:k]
	for len(whole) > 1 && whole[0] == '0' {
		whole = whole[1:]
	}
	if len(whole) == 0 {
		whole = "0"
	}
	out += copy(buf[out:], whole)
	if k < len(text) && text[k] == '.' {
		k += 1
		lo := k
		for k < len(text) && text[k] >= '0' && text[k] <= '9' {
			k += 1
		}
		if k > lo {
			buf[out] = '.'
			out += 1
			out += copy(buf[out:], text[lo:k])
		}
	}
	out += copy(buf[out:], text[k:])
	return string(buf[:out]), true
}

@(private)
radix_number :: proc "contextless" (digits: []u8, base: u64) -> core.Number {
	value, wide: u64
	approx: f64
	for b in digits {
		d := u64(b - '0') if b <= '9' else u64((b | 0x20) - 'a' + 10)
		approx = approx * f64(base) + f64(d)
		if value > (max(u64) - d) / base {
			wide = 1
		}
		value = value * base + d
	}
	if wide != 0 {
		return {transmute(u64)approx, .Float}
	}
	if value > u64(max(i64)) {
		return {value, .Uint}
	}
	return {value, .Int}
}

// YAML's `Readers.fact`: `Style` names how a scalar or a collection is written.
@(private)
spelling_fact :: proc(doc: ^core.Document, i: core.Node_Index, name: core.Fact_Name) -> (core.Fact_Value, bool) {
	if name != .Style {
		return {}, false
	}
	t := doc.nodes[i]
	switch t.kind {
	case .Array, .Object:
		return {text = "flow" if is_flow(doc, t) else "block"}, true
	case .Plain, .String, .Null, .False, .True, .Number:
		style := style_of(t.spelling)
		if style == .Block {
			return {text = "folded" if doc.src[t.lo] == '>' else "literal"}, true
		}
		return {text = STYLE_NAMES[style]}, true
	case .End:
	}
	return {}, false
}

@(private, rodata)
STYLE_NAMES := [Style]string {
	.Plain  = "plain",
	.Single = "single",
	.Double = "double",
	.Block  = "block",
}
