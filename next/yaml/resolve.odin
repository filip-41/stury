package yaml

import "stury:lib/base/spell"
import "stury:lib/core/tape"

// YAML 1.2 Core Schema resolution, tag handle matching, `!!binary` base64 validation, and number parsing.

@(private)
Class :: enum u8 {
	Text,
	Null,
	False,
	True,
	Decimal,
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
	if len(text) < 3 || len(text) > 5 { return .Text }
	switch string(text) {
	case "null", "Null", "NULL":                                         return .Null
	case "true", "True", "TRUE":                                         return .True
	case "false", "False", "FALSE":                                      return .False
	case ".inf", ".Inf", ".INF", "+.inf", "+.Inf", "+.INF", "-.inf", "-.Inf", "-.INF": return .Inf
	case ".nan", ".NaN", ".NAN":                                         return .Nan
	}
	return .Text
}

@(private = "file")
Dec_Scan :: struct {
	int_start, int_digits, frac_digits: int,
	neg, has_plus, has_dot, has_e, ok:  bool,
}

// Single shared scanner for YAML 1.2 Core decimal grammar `[-+]?(\.[0-9]+|[0-9]+(\.[0-9]*)?)([eE][-+]?[0-9]+)?`.
@(private = "file")
scan_decimal :: #force_inline proc "contextless" (text: []u8) -> (d: Dec_Scan) #no_bounds_check {
	n := len(text)
	if n == 0 { return }
	i := 0
	if text[0] == '+' || text[0] == '-' {
		d.neg, d.has_plus, i = text[0] == '-', text[0] == '+', 1
		if i >= n { return }
	}
	d.int_start = i
	for i < n && text[i] >= '0' && text[i] <= '9' { i += 1 }
	d.int_digits = i - d.int_start
	if i < n && text[i] == '.' {
		d.has_dot = true
		i += 1
		fs := i
		for i < n && text[i] >= '0' && text[i] <= '9' { i += 1 }
		d.frac_digits = i - fs
	}
	if d.int_digits + d.frac_digits == 0 { return }
	if i < n && (text[i] == 'e' || text[i] == 'E') {
		d.has_e = true
		i += 1
		if i < n && (text[i] == '+' || text[i] == '-') { i += 1 }
		es := i
		for i < n && text[i] >= '0' && text[i] <= '9' { i += 1 }
		if i == es { return }
	}
	d.ok = i == n
	return
}

@(private)
classify_number_lexical :: proc "contextless" (text: []u8) -> (class: Class, integer, strict: bool, int_d, frac_d: u64, has_exp, has_point: bool) #no_bounds_check {
	n := len(text)
	if n == 0 { return .Null, false, false, 0, 0, false, false }
	switch text[0] {
	case '0' ..= '9':
		if n > 2 && text[0] == '0' {
			if text[1] == 'x' { return .Hex if all_digits(text[2:], 16) else .Text, false, false, 0, 0, false, false }
			if text[1] == 'o' { return .Octal if all_digits(text[2:], 8) else .Text, false, false, 0, 0, false, false }
		}
	case '~':                         return .Null if n == 1 else .Text, false, false, 0, 0, false, false
	case 'n', 'N', 't', 'T', 'f', 'F': return word_class(text), false, false, 0, 0, false, false
	case '+', '-', '.':
		if w := word_class(text); w != .Text { return w, false, false, 0, 0, false, false }
	case:
		return .Text, false, false, 0, 0, false, false
	}
	d := scan_decimal(text)
	if !d.ok { return .Text, false, false, 0, 0, false, false }
	integer = !d.has_dot && !d.has_e
	has_point = d.has_dot && d.frac_digits == 0
	strict = !d.has_plus && d.int_digits > 0 && !(d.int_digits > 1 && text[d.int_start] == '0') && !has_point
	return .Decimal, integer, strict, u64(d.int_digits), u64(d.frac_digits), d.has_e, has_point
}

@(private)
classify_json_lexical :: proc "contextless" (text: []u8) -> (class: Class, integer: bool, int_d, frac_d: u64, has_exp: bool) #no_bounds_check {
	n := len(text)
	if n == 0 { return .Text, false, 0, 0, false }
	switch text[0] {
	case 'n': return .Null if n == 4 && string(text) == "null" else .Text, false, 0, 0, false
	case 't': return .True if n == 4 && string(text) == "true" else .Text, false, 0, 0, false
	case 'f': return .False if n == 5 && string(text) == "false" else .Text, false, 0, 0, false
	case '-', '0' ..= '9':
	case:     return .Text, false, 0, 0, false
	}
	d := scan_decimal(text)
	if !d.ok || d.has_plus || d.int_digits == 0 || (d.int_digits > 1 && text[d.int_start] == '0') || (d.has_dot && d.frac_digits == 0) {
		return .Text, false, 0, 0, false
	}
	return .Decimal, !d.has_dot && !d.has_e, u64(d.int_digits), u64(d.frac_digits), d.has_e
}

@(private)
yaml_decimal :: proc "contextless" (text: []u8) -> (num: spell.Number, integer, ok: bool) #no_bounds_check {
	d := scan_decimal(text)
	if !d.ok { return }
	n := len(text)
	if !d.has_dot && !d.has_e {
		k := d.int_start
		for k < n && text[k] == '0' { k += 1 }
		if k == n { return {0, .Int}, true, true }
		sig := n - k
		if sig <= 19 {
			val: u64
			for c in text[k:n] { val = val * 10 + u64(c - '0') }
			if !d.neg && val <= u64(max(i64)) { return {val, .Int}, true, true }
			if d.neg && val <= u64(1) << 63 { return {u64(0) - val, .Int}, true, true }
		}
		if sig > 4096 { return {0, .Wide}, true, true }
		norm: [4104]u8 = ---
		m := 0
		if d.neg { norm[0] = '-'; m = 1 }
		copy(norm[m:], text[k:n]); m += sig
		snum, _ := spell.number_strict(norm[:m], 0, u64(m))
		return snum, true, true
	}
	k := d.int_start
	int_end := d.int_start + d.int_digits
	for k < int_end && text[k] == '0' { k += 1 }
	clean_int := int_end - k
	rest_start := int_end + int(d.has_dot) + d.frac_digits
	if 1 + max(clean_int, 1) + 1 + max(d.frac_digits, 1) + (n - rest_start) > 4200 { return {0, .Wide}, false, true }
	norm: [4224]u8 = ---
	m := 0
	if d.neg { norm[m] = '-'; m += 1 }
	if clean_int == 0 { norm[m] = '0'; m += 1 } else { copy(norm[m:], text[k:int_end]); m += clean_int }
	if d.has_dot {
		norm[m] = '.'; m += 1
		if d.frac_digits == 0 { norm[m] = '0'; m += 1 } else { copy(norm[m:], text[int_end + 1:rest_start]); m += d.frac_digits }
	}
	if rest_start < n { copy(norm[m:], text[rest_start:n]); m += n - rest_start }
	snum, _ := spell.number_strict(norm[:m], 0, u64(m))
	if snum.kind == .Int || snum.kind == .Uint {
		f := f64(i64(snum.bits)) if snum.kind == .Int else f64(snum.bits)
		if d.neg && f == 0 { f = -0.0 }
		return {transmute(u64)f, .Float}, false, true
	}
	return snum, false, true
}

@(private)
all_digits :: proc "contextless" (s: []u8, base: u8) -> bool {
	if len(s) == 0 { return false }
	for b in s { if spell.HEX_NIBBLE[b] >= base { return false } }
	return true
}

@(private)
Core_Type :: enum u8 { None, Str, Int, Float, Bool, Null, Binary }

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
	if len(tag) > 1 && tag[1] == '<' { return "", tag[2:len(tag) - 1] }
	for k := len(tag) - 1; k > 0; k -= 1 {
		if tag[k] == '!' { return tag[:k + 1], tag[k + 1:] }
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
		if ct != .None && len(head) + len(suffix) == len(name) && name[:len(head)] == head && name[len(head):] == suffix {
			return ct
		}
	}
	return .None
}

@(private)
holds :: proc "contextless" (ct: Core_Type, class: Class, integer: bool) -> bool {
	switch ct {
	case .None, .Str: return true
	case .Int:        return class == .Hex || class == .Octal || class == .Decimal && integer
	case .Float:      return class == .Decimal || class == .Inf || class == .Nan
	case .Bool:       return class == .True || class == .False
	case .Null:       return class == .Null
	case .Binary:     return false
	}
	return false
}

@(private)
base64_valid :: proc "contextless" (text: []u8) -> (decoded_len: int, ok: bool) #no_bounds_check {
	quad, pad := 0, 0
	for b in text {
		switch b {
		case ' ', '\t', '\n', '\r':
			continue
		case '=':
			if pad >= 2 || quad < 2 { return 0, false }
			pad += 1; quad += 1
			if quad == 4 { decoded_len += 3 - pad; quad = 0 }
		case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '+', '/':
			if pad != 0 { return 0, false }
			quad += 1
			if quad == 4 { decoded_len += 3; quad = 0 }
		case:
			return 0, false
		}
	}
	return decoded_len, quad == 0
}

@(private)
number_value :: proc "contextless" (src: []u8, t: tape.Node) -> spell.Number #no_bounds_check {
	nk := Number_Spelling(t.spelling & tape.NUMBER_KIND)
	#partial switch nk {
	case .Plain:
		n, _ := spell.number_strict(src, t.lo, t.lo + u64(t.n))
		return n
	case .Inf, .Quoted_Inf:
		return {0x7ff0_0000_0000_0000 | u64(t.n > 0 && src[t.lo] == '-') << 63, .Float}
	case .Nan, .Quoted_Nan:
		return {0x7ff8_0000_0000_0001, .Float}
	}
	stack: [256]u8 = ---
	text := src[t.lo:][:t.n]
	if scalar_needs_decode(t) {
		if t.n <= 256 {
			s, ok := decode_number_scalar_bytes(src, t, stack[:])
			if !ok { return {kind = .Wide} }
			text = transmute([]u8)s
		} else {
			big: [4300]u8 = ---
			s, ok := decode_number_scalar_bytes(src, t, big[:])
			if !ok { return {kind = .Wide} }
			text = transmute([]u8)s
		}
	}
	class, _, strict, _, _, _, _ := classify_number_lexical(text)
	switch class {
	case .Decimal:
		num: spell.Number
		if strict { num, _ = spell.number_strict(text, 0, u64(len(text))) } else { num, _, _ = yaml_decimal(text) }
		return force_float(num, len(text) > 0 && text[0] == '-') if number_is_forced_float(nk) else num
	case .Hex, .Octal:
		r := radix_number(text[2:], 16 if class == .Hex else 8)
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
	case .Int:          return {u64(1) << 63, .Float} if n.bits == 0 && minus else {transmute(u64)f64(i64(n.bits)), .Float}
	case .Uint:         return {transmute(u64)f64(n.bits), .Float}
	case .Float, .Wide: return n
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
		if value > (max(u64) - d) / base { wide = 1 }
		value = value * base + d
	}
	if wide != 0 { return {transmute(u64)approx, .Float} }
	return {value, .Uint if value > u64(max(i64)) else .Int}
}

@(private)
Timestamp_Kind :: enum u8 { None, Datetime, Local_Datetime, Local_Date }

@(private)
timestamp_kind :: proc "contextless" (s: string) -> Timestamp_Kind #no_bounds_check {
	run :: proc "contextless" (s: string, at: ^int, lo, hi: int) -> bool #no_bounds_check {
		n := 0
		for at^ < len(s) && n < hi && s[at^] >= '0' && s[at^] <= '9' { at^ += 1; n += 1 }
		return n >= lo
	}
	at_byte :: proc "contextless" (s: string, at: ^int, b: u8) -> bool #no_bounds_check {
		if at^ < len(s) && s[at^] == b { at^ += 1; return true }
		return false
	}
	blanks :: proc "contextless" (s: string, at: ^int) -> int #no_bounds_check {
		from := at^
		for at^ < len(s) && (s[at^] == ' ' || s[at^] == '\t') { at^ += 1 }
		return at^ - from
	}
	at := 0
	if !run(s, &at, 4, 4) || !at_byte(s, &at, '-') || !run(s, &at, 1, 2) || !at_byte(s, &at, '-') || !run(s, &at, 1, 2) { return .None }
	if at == len(s) { return .Local_Date if at == 10 else .None }
	if !at_byte(s, &at, 'T') && !at_byte(s, &at, 't') && blanks(s, &at) == 0 { return .None }
	if !run(s, &at, 1, 2) || !at_byte(s, &at, ':') || !run(s, &at, 2, 2) || !at_byte(s, &at, ':') || !run(s, &at, 2, 2) { return .None }
	if at_byte(s, &at, '.') { run(s, &at, 0, len(s)) }
	if at == len(s) { return .Local_Datetime }
	zone := at
	blanks(s, &at)
	if !at_byte(s, &at, 'Z') {
		at = zone
		if !at_byte(s, &at, '+') && !at_byte(s, &at, '-') || !run(s, &at, 1, 2) || at_byte(s, &at, ':') && !run(s, &at, 2, 2) { return .None }
	}
	return .Datetime if at == len(s) else .None
}
