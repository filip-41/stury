package yaml

import "core:math"
import spell "../core/spell"
import core "../core"

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

// What tag handle `handle` stands for with no `%TAG` directive: `!!` is `tag:yaml.org,2002:` and any other is itself.
@(private)
tag_head :: #force_inline proc "contextless" (handle: string) -> string {
	return CORE_PREFIX if handle == "!!" else handle
}

// What tag handle `handle` stands for under the `%TAG` directives of `src`'s document.
@(private)
declared_head :: proc "contextless" (src: []u8, handle: string) -> string {
	if handle != "" {
		if prefix, declared := declared_prefix(src, handle); declared {
			return prefix
		}
	}
	return tag_head(handle)
}

// The core type of the tag whose handle stands for `head` and whose suffix is `suffix`.
@(private)
core_type :: proc "contextless" (head, suffix: string) -> Core_Type {
	for name, ct in CORE_TAGS {
		if ct != .None && is_named(head, suffix, name) {
			return ct
		}
	}
	return .None
}

// Whether a tag whose handle stands for `head` and whose suffix is `suffix` is the tag `name` in full.
@(private)
is_named :: #force_inline proc "contextless" (head, suffix, name: string) -> bool {
	return len(head) + len(suffix) == len(name) && name[:len(head)] == head && name[len(head):] == suffix
}

// YAML's `Readers.tag_meaning`: `!!binary`, and `!!timestamp` on a scalar whose text is a timestamp, as its kind, under
// the names the document's `%TAG` directives give.
@(private)
tag_meaning :: proc(doc: ^core.Document, i: core.Node_Index, tag: string) -> core.Tag_Meaning {
	n := doc.nodes[i]
	handle, suffix := tag_parts(tag)
	if n.kind != .String && n.kind != .Plain || len(suffix) < 6 {
		return .Own
	}
	head := declared_head(directive_source(doc), handle)
	if is_named(head, suffix, CORE_PREFIX + "binary") {
		return .Binary
	}
	if !is_named(head, suffix, CORE_PREFIX + "timestamp") {
		return .Own
	}
	stack: [64]u8 = ---
	return timestamp_kind(scalar_text(doc.src, n, stack[:]))
}

// The kind of timestamp `s` is by YAML 1.1's timestamp type: a date alone is `.Local_Date`, a date and a time
// `.Local_Datetime`, and one with a zone `.Datetime`. A text of neither form is `.Own`.
@(private)
timestamp_kind :: proc "contextless" (s: string) -> core.Tag_Meaning {
	at := 0
	if !run(s, &at, 4, 4) || !at_byte(s, &at, '-') || !run(s, &at, 1, 2) || !at_byte(s, &at, '-') || !run(s, &at, 1, 2) {
		return .Own
	}
	if at == len(s) {
		return .Local_Date if at == 10 else .Own
	}
	if !at_byte(s, &at, 'T') && !at_byte(s, &at, 't') && blanks(s, &at) == 0 {
		return .Own
	}
	if !run(s, &at, 1, 2) || !at_byte(s, &at, ':') || !run(s, &at, 2, 2) || !at_byte(s, &at, ':') || !run(s, &at, 2, 2) {
		return .Own
	}
	if at_byte(s, &at, '.') {
		run(s, &at, 0, len(s))
	}
	if at == len(s) {
		return .Local_Datetime
	}
	zone := at
	blanks(s, &at)
	if !at_byte(s, &at, 'Z') {
		at = zone
		if !at_byte(s, &at, '+') && !at_byte(s, &at, '-') || !run(s, &at, 1, 2) || at_byte(s, &at, ':') && !run(s, &at, 2, 2) {
			return .Own
		}
	}
	return .Datetime if at == len(s) else .Own

	run :: proc "contextless" (s: string, at: ^int, lo, hi: int) -> bool {
		n := 0
		for at^ < len(s) && n < hi && s[at^] >= '0' && s[at^] <= '9' {
			at^ += 1
			n += 1
		}
		return n >= lo
	}
	at_byte :: proc "contextless" (s: string, at: ^int, b: u8) -> bool {
		if at^ < len(s) && s[at^] == b {
			at^ += 1
			return true
		}
		return false
	}
	blanks :: proc "contextless" (s: string, at: ^int) -> int {
		from := at^
		for at^ < len(s) && (s[at^] == ' ' || s[at^] == '\t') {
			at^ += 1
		}
		return at^ - from
	}
}

// The readers' `tag_fits`: a core schema tag, as written with no `%TAG` directive, stays on a value of its type, and any
// other tag on any value.
@(private)
tag_fits :: proc(tag: string, v: core.Value) -> (string, bool) {
	@(static, rodata)
	kinds := [Core_Type]bit_set[core.Kind]{.None = ~{}, .Str = {.String}, .Int = {.Number}, .Float = {.Number}, .Bool = {.True, .False}, .Null = {.Null}}
	handle, suffix := tag_parts(tag)
	return tag, core.value_kind(v) in kinds[core_type(tag_head(handle), suffix)]
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

// The text whose `%TAG` directives `doc`'s tags resolve by: its state, the directives a stream's member keeps as
// `directives_keep` writes them, or else the start of its text.
@(private)
directive_source :: #force_inline proc "contextless" (doc: ^core.Document) -> []u8 {
	return doc.state if len(doc.state) > 0 else doc.src
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
	return core_type(declared_head(src, handle), suffix)
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
token_text :: proc(v: ^core.Token_View, t: core.Token, buf: []u8) -> (s: string, ok: bool) {
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
			#partial switch doc_core_type(directive_source(doc), tag.text) {
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
token_number :: proc(v: ^core.Token_View, t: core.Token) -> (core.Number, bool) {
	if t.kind != .Plain && t.kind != .Number || t.role != .Value {
		return {}, false
	}
	stack: [64]u8 = ---
	class, n, _ := scalar_value(transmute([]u8)scalar_text(v.src, t, stack[:]))
	return n, class != .Text && class != .Null && class != .False && class != .True
}

// `classify` of `text`, with the value of a text that is a number and whether a `Decimal` is a plain integer.
@(private)
scalar_value :: proc(text: []u8) -> (class: Class, n: core.Number, integer: bool) {
	class, n, integer, _ = classify_number(text)
	switch class {
	case .Decimal:
		if integer && n.kind == .Float && n.bits == 1 << 63 {
			n = {0, .Int}
		}
	case .Hex:
		n = radix_number(text[2:], 16)
	case .Octal:
		n = radix_number(text[2:], 8)
	case .Inf:
		n = {transmute(u64)math.inf_f64(-1 if text[0] == '-' else 1), .Float}
	case .Nan:
		n = {transmute(u64)math.nan_f64(), .Float}
	case .Text, .Null, .False, .True:
		n = {}
	}
	return
}

// YAML's `Readers.number_text`: the JSON digits of a plain scalar that resolves to a number. A decimal JSON reads
// returns its text, another decimal form, a hex and an octal integer are written into `buf`, and an infinity and a
// NaN, which have no digits, return an empty text. A hex or octal integer is exact at any size.
@(private)
number_text :: proc(v: ^core.Token_View, t: core.Token, buf: []u8) -> (s: string, ok: bool) {
	stack: [64]u8 = ---
	text := scalar_text(v.src, t, stack[:])
	class, _, _, strict := classify_number(transmute([]u8)text)
	switch class {
	case .Decimal:
		if !strict {
			return core.json_decimal(text, buf)
		}
		if t.spelling & core.SPELLING_DECODE == 0 {
			return string(v.src[t.lo:t.lo + u64(t.n)]), true
		}
		if len(buf) < len(text) {
			return "", false
		}
		return string(buf[:copy(buf, text)]), true
	case .Hex, .Octal:
		return core.prefixed_decimal(text, buf)
	case .Inf, .Nan:
		return "", true
	case .Text, .Null, .False, .True:
	}
	return "", true
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

// YAML's `Readers.fact`: `Style` names how a scalar or a collection is written, and for a plain hex or octal integer its
// base, `hex` or `octal`, as TOML and JSON5 name it.
@(private)
spelling_fact :: proc(doc: ^core.Document, i: core.Node_Index, name: core.Fact_Kind) -> (core.Fact_Value, bool) {
	if name != .Style {
		return {}, false
	}
	t := doc.nodes[i]
	switch t.kind {
	case .Array, .Object:
		return {text = "flow" if is_flow(doc, t) else "block"}, true
	case .Plain, .String, .Bytes, .Null, .False, .True, .Number:
		style := style_of(t.spelling)
		if style == .Block {
			return {text = "folded" if doc.src[t.lo] == '>' else "literal"}, true
		}
		if style == .Plain && t.n > 2 && doc.src[t.lo] == '0' && (doc.src[t.lo + 1] == 'x' || doc.src[t.lo + 1] == 'o') && core.kind(doc, i) == .Number {
			return {text = "hex" if doc.src[t.lo + 1] == 'x' else "octal"}, true
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
