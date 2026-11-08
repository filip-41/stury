package jq

// The `@format` string conversions.

import "core:encoding/base64"
import "core:math"
import "core:strings"
import "core:unicode/utf8"
import "../../../core/spell"

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
				return nil, fail(ip, "string (%s) is not valid base64 data", brief(ip, s))
			}
			code, have = code << 6 | u32(d), have + 1
			if have == 4 {
				append(&b, byte(code >> 16), byte(code >> 8), byte(code))
				code, have = 0, 0
			}
		}
		switch have {
		case 1:
			return nil, fail(ip, "string (%s) trailing base64 byte found", brief(ip, s))
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
				hi, lo = spell.HEX_NIBBLE[s[i + 1]], spell.HEX_NIBBLE[s[i + 2]]
			}
			if hi | lo > 15 {
				return nil, fail(ip, "string (%s) is not a valid uri encoding", brief(ip, s))
			}
			append(&b, hi << 4 | lo)
			i += 2
		}
		if !utf8.valid_string(string(b[:])) {
			return nil, fail(ip, "string (%s) is not a valid uri encoding", brief(ip, s))
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
		return nil, fail(ip, "%s (%s) cannot be %s-formatted, only array", type_name(v), brief(ip, v), name)
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
			return nil, fail(ip, "%s (%s) is not valid in a csv row", type_name(m), brief(ip, m))
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
			return nil, fail(ip, "%s (%s) can not be escaped for shell", type_name(m), brief(ip, m))
		}
	}
	return strings.to_string(b), .Go
}
