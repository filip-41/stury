package yaml

import "stury:lib/base/spell"
import "stury:lib/core/tape"

// YAML 1.2 Core Schema resolution, tag handle matching, `!!binary` base64 validation, and number parsing.

// What a plain scalar's decoded text resolves to under the YAML 1.2 Core Schema.
@(private)
Class :: enum u8 {
	Text,
	Null,
	False,
	True,
	Decimal, // integer or float (leading zeros allowed, `+`, `.5`, `5.`)
	Hex,
	Octal,
	Inf,
	Nan,
}

@(private, rodata)
RESOLVABLE_LEAD := [256]bool {
	'0' ..= '9' = true,
	'+' = true, '-' = true, '.' = true, '~' = true,
	'n' = true, 'N' = true,
	't' = true, 'T' = true,
	'f' = true, 'F' = true,
}

@(private)
classify :: proc "contextless" (text: []u8) -> Class {
	class, _, _, _, _, _, _ := classify_number_lexical(text)
	return class
}

@(private = "file")
word_class :: #force_inline proc "contextless" (text: []u8) -> Class {
	if len(text) < 3 || len(text) > 5 {
		return .Text
	}
	switch string(text) {
	case "null", "Null", "NULL":
		return .Null
	case "true", "True", "TRUE":
		return .True
	case "false", "False", "FALSE":
		return .False
	case ".inf", ".Inf", ".INF", "+.inf", "+.Inf", "+.INF", "-.inf", "-.Inf", "-.INF":
		return .Inf
	case ".nan", ".NaN", ".NAN":
		return .Nan
	}
	return .Text
}

// Single-pass lexical YAML 1.2 Core Schema classifier with ZERO binary64 conversion: returns `class`, whether a
// `Decimal` is an integer (`[-+]?[0-9]+`), whether `spell.number_strict` accepts it verbatim (`strict`), and the
// decimal part shape (`int_d`, `frac_d`, `has_exp`, `has_point`) for `tape.number_spelling`.
@(private)
classify_number_lexical :: proc "contextless" (text: []u8) -> (class: Class, integer, strict: bool, int_d, frac_d: u64, has_exp, has_point: bool) #no_bounds_check {
	n := len(text)
	if n == 0 {
		return .Null, false, false, 0, 0, false, false
	}
	switch text[0] {
	case '0' ..= '9':
		if n > 2 && text[0] == '0' {
			switch text[1] {
			case 'x':
				return .Hex if all_digits(text[2:], 16) else .Text, false, false, 0, 0, false, false
			case 'o':
				return .Octal if all_digits(text[2:], 8) else .Text, false, false, 0, 0, false, false
			}
		}
	case '~':
		return .Null if n == 1 else .Text, false, false, 0, 0, false, false
	case 'n', 'N', 't', 'T', 'f', 'F':
		return word_class(text), false, false, 0, 0, false, false
	case '+', '-', '.':
		if w := word_class(text); w != .Text {
			return w, false, false, 0, 0, false, false
		}
	case:
		return .Text, false, false, 0, 0, false, false
	}

	i := 0
	has_plus := false
	if text[0] == '+' || text[0] == '-' {
		has_plus = text[0] == '+'
		i = 1
		if i >= n {
			return .Text, false, false, 0, 0, false, false
		}
	}
	int_start := i
	for i < n && text[i] >= '0' && text[i] <= '9' {
		i += 1
	}
	int_digits := i - int_start
	has_dot := false
	frac_digits := 0
	if i < n && text[i] == '.' {
		has_dot = true
		i += 1
		frac_start := i
		for i < n && text[i] >= '0' && text[i] <= '9' {
			i += 1
		}
		frac_digits = i - frac_start
	}
	if int_digits + frac_digits == 0 {
		return .Text, false, false, 0, 0, false, false
	}
	has_e := false
	if i < n && (text[i] == 'e' || text[i] == 'E') {
		has_e = true
		i += 1
		if i < n && (text[i] == '+' || text[i] == '-') {
			i += 1
		}
		exp_start := i
		for i < n && text[i] >= '0' && text[i] <= '9' {
			i += 1
		}
		if i == exp_start {
			return .Text, false, false, 0, 0, false, false
		}
	}
	if i != n {
		return .Text, false, false, 0, 0, false, false
	}
	integer = !has_dot && !has_e
	has_point = has_dot && frac_digits == 0
	strict = !has_plus && int_digits > 0 && !(int_digits > 1 && text[int_start] == '0') && !has_point
	return .Decimal, integer, strict, u64(int_digits), u64(frac_digits), has_e, has_point
}

// `classify`, returning a `Decimal`'s `spell.Number`, whether the Core Schema reads a `Decimal` as an integer
// (`[-+]?[0-9]+`), and whether `spell.number_strict` accepts the bytes verbatim (RFC 8259 decimal).
@(private)
classify_number :: proc "contextless" (text: []u8) -> (class: Class, num: spell.Number, integer, strict: bool) #no_bounds_check {
	if len(text) == 0 {
		return .Null, {}, false, false
	}
	switch text[0] {
	case '0' ..= '9':
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
	case 'n', 'N', 't', 'T', 'f', 'F':
		return word_class(text), {}, false, false
	case '+', '-', '.':
		if w := word_class(text); w != .Text {
			return w, {}, false, false
		}
		return decimal(text)
	}
	return .Text, {}, false, false

	decimal :: proc "contextless" (text: []u8) -> (class: Class, num: spell.Number, integer, strict: bool) #no_bounds_check {
		// Try RFC 8259 strict number first.
		if snum, ok := spell.number_strict(text, 0, u64(len(text))); ok {
			is_int := true
			for b in text {
				if b == '.' || b == 'e' || b == 'E' {
					is_int = false
					break
				}
			}
			if is_int && snum.kind == .Uint {
				return .Decimal, snum, true, true
			}
			return .Decimal, snum, is_int, true
		}
		// YAML 1.2 Core Schema decimal: `[-+]?(\.[0-9]+|[0-9]+(\.[0-9]*)?)([eE][-+]?[0-9]+)?`.
		n, is_int, ok := yaml_decimal(text)
		if !ok {
			return .Text, {}, false, false
		}
		return .Decimal, n, is_int, false
	}
}

// Parses a non-strict YAML 1.2 Core Schema decimal (allows `+`, leading zeros `007`/`-00`, `.5`, `5.`).
@(private)
yaml_decimal :: proc "contextless" (text: []u8) -> (num: spell.Number, integer, ok: bool) #no_bounds_check {
	n := len(text)
	if n == 0 {
		return
	}
	i := 0
	neg := false
	if text[0] == '+' || text[0] == '-' {
		neg = text[0] == '-'
		i += 1
		if i >= n {
			return
		}
	}
	int_start := i
	for i < n && text[i] >= '0' && text[i] <= '9' {
		i += 1
	}
	int_digits := i - int_start
	has_dot := false
	frac_digits := 0
	if i < n && text[i] == '.' {
		has_dot = true
		i += 1
		frac_start := i
		for i < n && text[i] >= '0' && text[i] <= '9' {
			i += 1
		}
		frac_digits = i - frac_start
	}
	if int_digits + frac_digits == 0 {
		return
	}
	has_exp := false
	if i < n && (text[i] == 'e' || text[i] == 'E') {
		has_exp = true
		i += 1
		if i < n && (text[i] == '+' || text[i] == '-') {
			i += 1
		}
		exp_start := i
		for i < n && text[i] >= '0' && text[i] <= '9' {
			i += 1
		}
		if i == exp_start {
			return
		}
	}
	if i != n {
		return
	}
	// Strip leading `+`, leading redundant `0`s before first nonzero digit (for spell.number_strict), add `0` before `.` or after trailing `.`.
	// Normalize into a stack buffer for `spell.number_strict` if short, or fallback for >4096 digits.
	if !has_dot && !has_exp {
		// Integer in YAML Core Schema.
		k := int_start
		for k < i && text[k] == '0' {
			k += 1
		}
		if k == i {
			return {0, .Int}, true, true
		}
		sig := i - k
		if sig <= 19 {
			val: u64
			for c in text[k:i] {
				val = val * 10 + u64(c - '0')
			}
			if !neg && val <= u64(max(i64)) {
				return {val, .Int}, true, true
			}
			if neg && val <= u64(1) << 63 {
				return {u64(0) - val, .Int}, true, true
			}
		}
		if sig <= 4096 {
			norm: [4104]u8 = ---
			m := 0
			if neg {
				norm[0] = '-'
				m = 1
			}
			copy(norm[m:], text[k:i])
			m += sig
			snum, _ := spell.number_strict(norm[:m], 0, u64(m))
			return snum, true, true
		}
		return {0, .Wide}, true, true
	}
	// Float: normalize into `spell.number_strict` format: optional `-`, integer digits (`0` or `[1-9]...`), optional `.digits`, optional `e...`.
	k := int_start
	for k < int_start + int_digits && text[k] == '0' {
		k += 1
	}
	clean_int := int_start + int_digits - k
	need := 1 + max(clean_int, 1) + 1 + max(frac_digits, 1) + (n - (int_start + int_digits + int(has_dot) + frac_digits))
	if need > 4200 {
		// Let `number_strict` decide via truncated check or Wide.
		return {0, .Wide}, false, true
	}
	norm: [4224]u8 = ---
	m := 0
	if neg {
		norm[m] = '-'
		m += 1
	}
	if clean_int == 0 {
		norm[m] = '0'
		m += 1
	} else {
		copy(norm[m:], text[k:int_start + int_digits])
		m += clean_int
	}
	if has_dot {
		norm[m] = '.'
		m += 1
		if frac_digits == 0 {
			norm[m] = '0'
			m += 1
		} else {
			copy(norm[m:], text[int_start + int_digits + 1:int_start + int_digits + 1 + frac_digits])
			m += frac_digits
		}
	}
	rest_start := int_start + int_digits + int(has_dot) + frac_digits
	if rest_start < n {
		copy(norm[m:], text[rest_start:n])
		m += n - rest_start
	}
	snum, _ := spell.number_strict(norm[:m], 0, u64(m))
	if snum.kind == .Int || snum.kind == .Uint {
		f := f64(i64(snum.bits)) if snum.kind == .Int else f64(snum.bits)
		if neg && f == 0 {
			f = -0.0
		}
		return {transmute(u64)f, .Float}, false, true
	}
	return snum, false, true
}

@(private)
all_digits :: proc "contextless" (s: []u8, base: u8) -> bool {
	if len(s) == 0 {
		return false
	}
	for b in s {
		if spell.HEX_NIBBLE[b] >= base {
			return false
		}
	}
	return true
}

// Core and binary YAML schema tags recognized during the walk.
@(private)
Core_Type :: enum u8 {
	None,   // custom/local tag or collection tag
	Str,    // !!str
	Int,    // !!int
	Float,  // !!float
	Bool,   // !!bool
	Null,   // !!null
	Binary, // !!binary
}

@(private, rodata)
CORE_TAGS := [Core_Type]string {
	.None   = "",
	.Str    = "tag:yaml.org,2002:str",
	.Int    = "tag:yaml.org,2002:int",
	.Float  = "tag:yaml.org,2002:float",
	.Bool   = "tag:yaml.org,2002:bool",
	.Null   = "tag:yaml.org,2002:null",
	.Binary = "tag:yaml.org,2002:binary",
}

@(private)
CORE_PREFIX :: "tag:yaml.org,2002:"

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

@(private)
tag_head :: #force_inline proc "contextless" (handle: string) -> string {
	return CORE_PREFIX if handle == "!!" else handle
}

@(private)
core_type :: proc "contextless" (head, suffix: string) -> Core_Type {
	for name, ct in CORE_TAGS {
		if ct != .None && is_named(head, suffix, name) {
			return ct
		}
	}
	return .None
}

@(private)
is_named :: #force_inline proc "contextless" (head, suffix, name: string) -> bool {
	return len(head) + len(suffix) == len(name) && name[:len(head)] == head && name[len(head):] == suffix
}

@(private)
holds :: proc "contextless" (ct: Core_Type, class: Class, integer: bool) -> bool {
	switch ct {
	case .None, .Str:
		return true
	case .Int:
		return class == .Hex || class == .Octal || class == .Decimal && integer
	case .Float:
		return class == .Decimal || class == .Inf || class == .Nan
	case .Bool:
		return class == .True || class == .False
	case .Null:
		return class == .Null
	case .Binary:
		return false // handled explicitly via `base64_valid`
	}
	return false
}

// Validates YAML `!!binary` base64 text (ignoring ASCII whitespace `' '`, `'\t'`, `'\n'`, `'\r'`), returning decoded
// byte count and whether it is well-formed base64.
@(private)
base64_valid :: proc "contextless" (text: []u8) -> (decoded_len: int, ok: bool) #no_bounds_check {
	quad := 0
	pad := 0
	for b in text {
		switch b {
		case ' ', '\t', '\n', '\r':
			continue
		case '=':
			if pad >= 2 || quad == 0 || quad == 1 {
				return 0, false
			}
			pad += 1
			quad += 1
			if quad == 4 {
				decoded_len += 3 - pad
				quad = 0
				// Once padded at end, no further non-whitespace groups are allowed.
			}
		case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '+', '/':
			if pad != 0 {
				return 0, false
			}
			quad += 1
			if quad == 4 {
				decoded_len += 3
				quad = 0
			}
		case:
			return 0, false
		}
	}
	if quad != 0 {
		return 0, false
	}
	return decoded_len, true
}

// Computes numeric value of YAML `.Number` token `t` in `src`.
@(private)
number_value :: proc "contextless" (src: []u8, t: tape.Node) -> spell.Number #no_bounds_check {
	nk := Number_Spelling(t.spelling & tape.NUMBER_KIND)
	#partial switch nk {
	case .Plain:
		n, _ := spell.number_strict(src, t.lo, t.lo + u64(t.n))
		return n
	case .Inf, .Quoted_Inf:
		span := src[t.lo:][:t.n]
		neg := t.n > 0 && span[0] == '-'
		return {0x7ff0_0000_0000_0000 | u64(neg) << 63, .Float}
	case .Nan, .Quoted_Nan:
		return {0x7ff8_0000_0000_0001, .Float}
	}
	stack: [256]u8 = ---
	text: []u8
	span := src[t.lo:][:t.n]
	if scalar_needs_decode(t) {
		if t.n <= 256 {
			s, ok := decode_number_scalar_bytes(src, t, stack[:])
			if !ok {
				return {kind = .Wide}
			}
			text = transmute([]u8)s
		} else {
			big: [4300]u8 = ---
			s, ok := decode_number_scalar_bytes(src, t, big[:])
			if !ok {
				return {kind = .Wide}
			}
			text = transmute([]u8)s
		}
	} else {
		text = span
	}
	class, num, _, _ := classify_number(text)
	switch class {
	case .Decimal:
		if number_is_forced_float(nk) {
			return force_float(num, len(text) > 0 && text[0] == '-')
		}
		return num
	case .Hex:
		r := radix_number(text[2:], 16)
		return force_float(r, false) if number_is_forced_float(nk) else r
	case .Octal:
		r := radix_number(text[2:], 8)
		return force_float(r, false) if number_is_forced_float(nk) else r
	case .Inf:
		return {0x7ff0_0000_0000_0000 | u64(len(text) > 0 && text[0] == '-') << 63, .Float}
	case .Nan:
		return {0x7ff8_0000_0000_0001, .Float}
	case .Text, .Null, .False, .True:
	}
	return {}
}

@(private)
force_float :: #force_inline proc "contextless" (n: spell.Number, minus: bool) -> spell.Number {
	switch n.kind {
	case .Int:
		if n.bits == 0 && minus {
			return {u64(1) << 63, .Float}
		}
		return {transmute(u64)f64(i64(n.bits)), .Float}
	case .Uint:
		return {transmute(u64)f64(n.bits), .Float}
	case .Float, .Wide:
		return n
	}
	return n
}

@(private)
radix_number :: proc "contextless" (digits: []u8, base: u64) -> spell.Number #no_bounds_check {
	value, wide: u64
	approx: f64
	for b in digits {
		d := u64(spell.HEX_NIBBLE[b])
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
		// Return Float when past i64, matching YAML Core Schema int limits vs u64 or Float? Wait: Uint is supported in v2 spell.Number!
		// Keep .Uint for u64-fitting hex/octal so int_value / uint conversion works accurately in v2 typed/write!
		return {value, .Uint}
	}
	return {value, .Int}
}

// YAML 1.1 timestamp shape recognized on foreign `.Tag` facts ("datetime" / etc.) when writing `!!timestamp`.
@(private)
Timestamp_Kind :: enum u8 {
	None,
	Datetime,
	Local_Datetime,
	Local_Date,
}

@(private)
timestamp_kind :: proc "contextless" (s: string) -> Timestamp_Kind #no_bounds_check {
	run :: proc "contextless" (s: string, at: ^int, lo, hi: int) -> bool #no_bounds_check {
		n := 0
		for at^ < len(s) && n < hi && s[at^] >= '0' && s[at^] <= '9' {
			at^ += 1
			n += 1
		}
		return n >= lo
	}
	at_byte :: proc "contextless" (s: string, at: ^int, b: u8) -> bool #no_bounds_check {
		if at^ < len(s) && s[at^] == b {
			at^ += 1
			return true
		}
		return false
	}
	blanks :: proc "contextless" (s: string, at: ^int) -> int #no_bounds_check {
		from := at^
		for at^ < len(s) && (s[at^] == ' ' || s[at^] == '\t') {
			at^ += 1
		}
		return at^ - from
	}
	at := 0
	if !run(s, &at, 4, 4) || !at_byte(s, &at, '-') || !run(s, &at, 1, 2) || !at_byte(s, &at, '-') || !run(s, &at, 1, 2) {
		return .None
	}
	if at == len(s) {
		return .Local_Date if at == 10 else .None
	}
	if !at_byte(s, &at, 'T') && !at_byte(s, &at, 't') && blanks(s, &at) == 0 {
		return .None
	}
	if !run(s, &at, 1, 2) || !at_byte(s, &at, ':') || !run(s, &at, 2, 2) || !at_byte(s, &at, ':') || !run(s, &at, 2, 2) {
		return .None
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
			return .None
		}
	}
	return .Datetime if at == len(s) else .None
}
