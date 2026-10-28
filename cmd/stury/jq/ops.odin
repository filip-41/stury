package jq

// Arithmetic, comparison and the `@format` string conversions.

import "core:encoding/base64"
import "core:math"
import "core:strings"
import "core:unicode/utf8"
import core_pkg "../../../core"

// Whether `compare`'s result `c` on two values holds the comparison `op` between them.
compared :: proc(op: Op, c: int) -> bool {
	#partial switch op {
	case .Eq:
		return c == 0
	case .Ne:
		return c != 0
	case .Lt:
		return c < 0
	case .Le:
		return c <= 0
	case .Gt:
		return c > 0
	}
	return c >= 0
}

// The error of the comparisons since `too_deep` was cleared, if one met nesting past MAX_DEPTH, as jq's do.
compare_failed :: proc(ip: ^Interp, eq: bool) -> Signal {
	if !too_deep {
		return .Go
	}
	return fail(ip, "Equality check too deep" if eq else "Comparison too deep")
}

// With `owned`, `+` and `*` change `a` in place where `a` is or holds a container the set names (modify.odin).
binary_op :: proc(ip: ^Interp, op: Op, a, b: Value, owned: ^Owned = nil) -> (Value, Signal) {
	#partial switch op {
	case .Eq, .Ne, .Lt, .Le, .Gt, .Ge:
		too_deep = false
		c := compare(a, b, eq = op == .Eq || op == .Ne)
		if sig := compare_failed(ip, op == .Eq || op == .Ne); sig != .Go {
			return nil, sig
		}
		return compared(op, c), .Go
	case .Add:
		return add(ip, a, b, owned)
	case .Sub:
		return subtract(ip, a, b)
	case .Mul:
		return multiply(ip, a, b, owned)
	case .Div:
		return divide(ip, a, b)
	case .Mod:
		return modulo(ip, a, b)
	}
	return nil, fail(ip, "unknown operator")
}

@(private = "file")
cannot :: proc(ip: ^Interp, a, b: Value, what: string) -> (Value, Signal) {
	return nil, fail(ip, "%s (%s) and %s (%s) cannot be %s", type_name(a), brief(a), type_name(b), brief(b), what)
}

add :: proc(ip: ^Interp, a, b: Value, owned: ^Owned = nil) -> (Value, Signal) {
	ka, kb := kind(a), kind(b)
	switch {
	case ka == .Null:
		return b, .Go
	case kb == .Null, kb == ka && (kb == .Array || kb == .Object) && is_empty(b):
		return a, .Go // jq appends b's members to a itself, so a path expression keeps a's path
	case ka == .Number && kb == .Number:
		x, _ := number_of(a)
		y, _ := number_of(b)
		return num(x.f + y.f), .Go
	case ka == .String && kb == .String:
		x, _ := string_of(a)
		y, _ := string_of(b)
		if owned != nil {
			return append_owned(ip, x, y, owned), .Go
		}
		return strings.concatenate({x, y}), .Go
	case ka == .Array && kb == .Array:
		if owned != nil {
			r := owned_copy(a, owned).(^Array)
			// `. + .` on the state itself is left to the loop, which reads the array as it grows.
			if x, is_array := b.(^Array); is_array && x != r {
				append(&r.items, ..x.items[:])
				return r, .Go
			}
			it := iterate(b)
			for _, m in next_member(&it) {
				append(&r.items, m)
			}
			return r, .Go
		}
		r := new_array(length_of(a) + length_of(b))
		for v in ([]Value{a, b}) {
			if x, is_array := v.(^Array); is_array {
				append(&r.items, ..x.items[:]) // a block copy, not a member at a time
				continue
			}
			it := iterate(v)
			for _, m in next_member(&it) {
				append(&r.items, m)
			}
		}
		return r, .Go
	case ka == .Object && kb == .Object:
		r := (owned_copy(a, owned) if owned != nil else own(a)).(^Object)
		it := iterate(b)
		for k, m in next_member(&it) {
			object_put(r, k, m)
		}
		return r, .Go
	}
	return cannot(ip, a, b, "added")
}

// Whether `add` takes `a` and `b` rather than fails.
addable :: proc(a, b: Value) -> bool {
	ka, kb := kind(a), kind(b)
	return ka == .Null || kb == .Null || ka == kb && (ka == .Number || ka == .String || ka == .Array || ka == .Object)
}

subtract :: proc(ip: ^Interp, a, b: Value) -> (Value, Signal) {
	ka, kb := kind(a), kind(b)
	switch {
	case ka == .Number && kb == .Number:
		x, _ := number_of(a)
		y, _ := number_of(b)
		return num(x.f - y.f), .Go
	case ka == .Array && kb == .Array:
		r := new_array()
		too_deep = false
		xs, ys := elements(a), elements(b)
		indexed := worth_indexing(len(ys), len(xs))
		ix: Scalar_Index
		if indexed {
			ix = index_scalars(ys)
		}
		outer: for m in xs {
			if indexed {
				found, scalar := index_has(&ix, m)
				if found {
					continue outer
				}
				if scalar {
					append(&r.items, m)
					continue outer
				}
			}
			for x in ys {
				if equal(m, x) {
					continue outer
				}
			}
			append(&r.items, m)
		}
		return r, compare_failed(ip, true)
	}
	return cannot(ip, a, b, "subtracted")
}

multiply :: proc(ip: ^Interp, a, b: Value, owned: ^Owned = nil) -> (Value, Signal) {
	ka, kb := kind(a), kind(b)
	switch {
	case ka == .Number && kb == .Number:
		x, _ := number_of(a)
		y, _ := number_of(b)
		return num(x.f * y.f), .Go
	case ka == .String && kb == .Number, ka == .Number && kb == .String:
		s, _ := string_of(a if ka == .String else b)
		n, _ := number_of(b if ka == .String else a)
		if n.f < 0 || math.is_nan(n.f) {
			return nil, .Go
		}
		times := int(min(n.f, f64(max(i32))))
		if len(s) * times >= int(max(i32)) - 8 { // jq's string length limit, an int less its header
			return nil, fail(ip, "Repeat string result too long")
		}
		return strings.repeat(s, times), .Go
	case ka == .Object && kb == .Object:
		if is_empty(b) {
			return a, .Go // a itself, as `+`
		}
		if r := (owned_copy(a, owned) if owned != nil else own(a)).(^Object); merge_into(r, b, owned) {
			return r, .Go
		}
		return nil, fail(ip, "Object merge too deep")
	}
	return cannot(ip, a, b, "multiplied")
}

// `b` merged into `r` itself, objects within objects too. It returns false if they nest deeper than jq merges. Given
// an `owned` set, the objects within `r` are merged into in place, each copied only the first time.
merge_into :: proc(r: ^Object, b: Value, owned: ^Owned = nil, depth := 0) -> bool {
	if depth > MAX_DEPTH {
		return false
	}
	it := iterate(b)
	for k, m in next_member(&it) {
		old, has := object_get(r, k)
		if has && kind(old) == .Object && kind(m) == .Object {
			inner := (owned_copy(old, owned) if owned != nil else own(old)).(^Object)
			if !merge_into(inner, m, owned, depth + 1) {
				return false
			}
			object_put(r, k, inner)
		} else {
			object_put(r, k, m)
		}
	}
	return true
}

divide :: proc(ip: ^Interp, a, b: Value) -> (Value, Signal) {
	ka, kb := kind(a), kind(b)
	switch {
	case ka == .Number && kb == .Number:
		x, _ := number_of(a)
		y, _ := number_of(b)
		if y.f == 0 {
			return cannot(ip, a, b, "divided because the divisor is zero")
		}
		return num(x.f / y.f), .Go
	case ka == .String && kb == .String:
		x, _ := string_of(a)
		y, _ := string_of(b)
		return split_string(x, y), .Go
	}
	return cannot(ip, a, b, "divided")
}

modulo :: proc(ip: ^Interp, a, b: Value) -> (Value, Signal) {
	if kind(a) != .Number || kind(b) != .Number {
		return cannot(ip, a, b, "divided (remainder)")
	}
	x, _ := number_of(a)
	y, _ := number_of(b)
	if math.is_nan(x.f) || math.is_nan(y.f) {
		return num(math.nan_f64()), .Go
	}
	xi, yi := double_to_i64(x.f), double_to_i64(y.f)
	if yi == 0 {
		return cannot(ip, a, b, "divided (remainder) because the divisor is zero")
	}
	if yi == -1 { // jq's guard against min(i64) % -1
		return num(0), .Go
	}
	return num(f64(xi % yi)), .Go
}

// A double cut toward zero to a 64-bit integer: saturated past `[min(i64), max(i64)]`, NaN as 0.
double_to_i64 :: proc(f: f64) -> i64 {
	switch {
	case math.is_nan(f):
		return 0
	case f >= 1 << 63:
		return max(i64)
	case f < -(1 << 63):
		return min(i64)
	}
	return i64(f)
}

split_string :: proc(s, sep: string) -> Value {
	a := new_array()
	if s == "" {
		return a
	}
	if sep == "" {
		for r, i in s {
			_ = r
			n := i + 1
			for n < len(s) && s[n] & 0xc0 == 0x80 {
				n += 1
			}
			append(&a.items, s[i:n])
		}
		return a
	}
	for part in strings.split(s, sep) {
		append(&a.items, part)
	}
	return a
}

format :: proc(ip: ^Interp, name: string, v: Value) -> (Value, Signal) {
	switch name {
	case "text":
		return text_of(v), .Go
	case "json":
		return to_json(v), .Go
	case "html":
		b := strings.builder_make()
		write_escaped(&b, text_of(v), "<>&'\"\x00", {"&lt;", "&gt;", "&amp;", "&apos;", "&quot;", `\0`})
		return strings.to_string(b), .Go
	case "uri":
		HEX := "0123456789ABCDEF"
		b := strings.builder_make()
		s := text_of(v)
		for i in 0 ..< len(s) {
			c := s[i]
			if (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~' {
				strings.write_byte(&b, c)
			} else {
				strings.write_byte(&b, '%')
				strings.write_byte(&b, HEX[c >> 4])
				strings.write_byte(&b, HEX[c & 15])
			}
		}
		return strings.to_string(b), .Go
	case "csv", "tsv":
		return delimited(ip, name, v)
	case "sh":
		return shell_quote(ip, v)
	case "base64":
		s := text_of(v)
		return base64.encode(transmute([]byte)s), .Go
	case "base64d":
		// jq's decoder: up to the first `=`, a lone last digit an error, bad UTF-8 replaced.
		B64 :: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
		s := text_of(v)
		b := make([dynamic]byte, 0, len(s) * 3 / 4 + 1)
		code, have := u32(0), 0
		for i := 0; i < len(s) && s[i] != '='; i += 1 {
			d := strings.index_byte(B64, s[i])
			if d < 0 {
				return nil, fail(ip, "string (%s) is not valid base64 data", brief(s))
			}
			code, have = code << 6 | u32(d), have + 1
			if have == 4 {
				append(&b, byte(code >> 16), byte(code >> 8), byte(code))
				code, have = 0, 0
			}
		}
		switch have {
		case 1:
			return nil, fail(ip, "string (%s) trailing base64 byte found", brief(s))
		case 2:
			append(&b, byte(code >> 4))
		case 3:
			append(&b, byte(code >> 10), byte(code >> 2))
		}
		return valid_utf8(string(b[:])), .Go
	case "urid":
		s := text_of(v)
		b := make([dynamic]byte, 0, len(s))
		for i := 0; i < len(s); i += 1 {
			if s[i] != '%' {
				append(&b, s[i])
				continue
			}
			hi, lo: u8 = 0xFF, 0xFF // not a nibble
			if i + 2 < len(s) {
				hi, lo = core_pkg.HEX_NIBBLE[s[i + 1]], core_pkg.HEX_NIBBLE[s[i + 2]]
			}
			if hi | lo > 15 {
				return nil, fail(ip, "string (%s) is not a valid uri encoding", brief(s))
			}
			append(&b, hi << 4 | lo)
			i += 2
		}
		if !utf8.valid_string(string(b[:])) {
			return nil, fail(ip, "string (%s) is not a valid uri encoding", brief(s))
		}
		return string(b[:]), .Go
	}
	return nil, fail(ip, "%s is not a valid format", name)
}

// `s` written with each byte of `from` written as its `to`. The bytes are ASCII and a value's strings valid
// UTF-8, so none is inside a character.
@(private = "file")
write_escaped :: proc(b: ^strings.Builder, s: string, from: string, to: []string) {
	done := 0
	for c, i in transmute([]byte)s {
		if k := strings.index_byte(from, c); k >= 0 {
			strings.write_string(b, s[done:i])
			strings.write_string(b, to[k])
			done = i + 1
		}
	}
	strings.write_string(b, s[done:])
}

@(private = "file")
delimited :: proc(ip: ^Interp, name: string, v: Value) -> (Value, Signal) {
	if kind(v) != .Array {
		return nil, fail(ip, "%s (%s) cannot be %s-formatted, only array", type_name(v), brief(v), name)
	}
	b := strings.builder_make()
	for m, i in elements(v) {
		if i > 0 {
			strings.write_byte(&b, ',' if name == "csv" else '\t')
		}
		switch kind(m) {
		case .Null:
		case .Number:
			// jq writes NaN as an empty cell, like null.
			if n, _ := number_of(m); !math.is_nan(n.f) {
				strings.write_string(&b, to_json(m))
			}
		case .False, .True:
			strings.write_string(&b, to_json(m))
		case .String:
			s, _ := string_of(m)
			if name == "csv" {
				strings.write_byte(&b, '"')
				write_escaped(&b, s, "\"\x00", {`""`, `\0`})
				strings.write_byte(&b, '"')
			} else {
				write_escaped(&b, s, "\\\t\n\r\x00", {`\\`, `\t`, `\n`, `\r`, `\0`})
			}
		case .Array, .Object:
			return nil, fail(ip, "%s (%s) is not valid in a csv row", type_name(m), brief(m))
		}
	}
	return strings.to_string(b), .Go
}

@(private = "file")
shell_quote :: proc(ip: ^Interp, v: Value) -> (Value, Signal) {
	b := strings.builder_make()
	for m, i in (elements(v) if kind(v) == .Array else []Value{v}) {
		if i > 0 {
			strings.write_byte(&b, ' ')
		}
		switch kind(m) {
		case .String:
			s, _ := string_of(m)
			strings.write_byte(&b, '\'')
			write_escaped(&b, s, "'\x00", {`'\''`, `\0`})
			strings.write_byte(&b, '\'')
		case .Null, .False, .True, .Number:
			strings.write_string(&b, to_json(m))
		case .Array, .Object:
			return nil, fail(ip, "%s (%s) can not be escaped for shell", type_name(m), brief(m))
		}
	}
	return strings.to_string(b), .Go
}
