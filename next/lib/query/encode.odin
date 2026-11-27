package query

import "core:encoding/base32"
import "core:encoding/base64"
import "core:encoding/hex"
import "stury:lib/base/kernel"
import "stury:lib/base/spell"

// Byte encodings of texts: base64 (standard and URL alphabets), base32, hex and percent encoding, each way.

Base :: enum u8 {
	Base64,
	Base64_Url,
	Base32,
}

// `s` in `base`, `pad` filling the last group with `=`.
@(require_results)
encode_base :: proc(h: ^Heap, s: string, base: Base, pad: bool) -> (res: Value, status: Status) {
	data := transmute([]u8)s
	options64 := base64.Encode_Options{} if pad else {.No_Padding}
	options32 := base32.Encode_Options{} if pad else {.No_Padding}
	n := base32.encoded_len(data, options32) if base == .Base32 else base64.encoded_len(data, options64)
	v, bytes := make_text(h, n) or_return
	out := bytes[:n]
	failed: bool
	switch base {
	case .Base64:
		_, err := base64.encode_into_buf(out, data, options = options64)
		failed = err != nil
	case .Base64_Url:
		_, err := base64.encode_into_buf(out, data, base64.ENC_URL_TABLE, options64)
		failed = err != nil
	case .Base32:
		_, err := base32.encode_into_buf(out, data, options = options32)
		failed = err != nil
	}
	ensure(!failed, "the text holds the length the encoder gave")
	return v, .Ok
}

Decode_Fault :: enum u8 {
	None,
	Bad_Digit,  // a byte outside the alphabet
	Lone_Digit, // a last digit that holds no whole byte
}

// The text of the bytes base 64 or 32 text `s` in `base` holds, padding optional, each ill-formed UTF-8 sequence one
// U+FFFD, or the fault that is in `s`.
@(require_results)
decode_base :: proc(h: ^Heap, s: string, base: Base) -> (res: Value, fault: Decode_Fault, status: Status) {
	room := len(s) / 8 * 5 + 4 if base == .Base32 else len(s) / 4 * 3 + 2
	out := make([]u8, room, h.allocator)
	if out == nil {
		return NULL, .None, fail_memory(h)
	}
	defer delete(out, h.allocator)
	decoded: []u8
	malformed, failed: bool
	switch base {
	case .Base64, .Base64_Url:
		tbl := base64.DEC_TABLE if base == .Base64 else base64.DEC_URL_TABLE
		err: base64.Error
		decoded, err = base64.decode_into_buf(out, s, tbl)
		malformed, failed = err == base64.Decode_Error.Malformed_Quantum, err != nil
	case .Base32:
		err: base32.Error
		decoded, err = base32.decode_into_buf(out, s)
		malformed, failed = err == base32.Decode_Error.Malformed_Quantum, err != nil
	}
	if failed {
		if malformed && !has_bad_digit(s, base) {
			return NULL, .Lone_Digit, .Ok
		}
		return NULL, .Bad_Digit, .Ok
	}
	v, st := text_lossy(h, decoded)
	return v, .None, st
}

@(private)
has_bad_digit :: proc(s: string, base: Base) -> bool {
	end := len(s)
	for end > 0 && s[end - 1] == '=' {
		end -= 1
	}
	for c in transmute([]u8)s[:end] {
		d: i8
		switch base {
		case .Base64:
			d = base64.DEC_TABLE[c]
		case .Base64_Url:
			d = base64.DEC_URL_TABLE[c]
		case .Base32:
			d = base32.DEC_TABLE[c]
		}
		if d < 0 {
			return true
		}
	}
	return false
}

// A string of `bytes`, each ill-formed UTF-8 sequence in them one U+FFFD.
@(private, require_results)
text_lossy :: proc(h: ^Heap, bytes: []u8) -> (res: Value, status: Status) {
	if kernel.utf8_valid(bytes) {
		return text_value(h, string(bytes))
	}
	fixed := make([dynamic]u8, 0, len(bytes) + 8, h.allocator)
	defer delete(fixed)
	p := raw_data(bytes)
	end := p[len(bytes):]
	for p < end {
		if p[0] < 0x80 {
			append(&fixed, p[0])
			p = p[1:]
			continue
		}
		if q, fault := spell.utf8_char(p, end); fault == .None {
			append(&fixed, ..p[:uintptr(q) - uintptr(p)])
			p = q
			continue
		}
		announced := 1
		switch {
		case 0xC0 <= p[0] && p[0] < 0xE0:
			announced = 2
		case 0xE0 <= p[0] && p[0] < 0xF0:
			announced = 3
		case 0xF0 <= p[0] && p[0] < 0xF8:
			announced = 4
		}
		taken := min(announced, int(uintptr(end) - uintptr(p)))
		if taken == announced {
			for i in 1 ..< announced {
				if p[i] & 0xC0 != 0x80 {
					taken = i
					break
				}
			}
		}
		replacement := spell.REPLACEMENT
		append(&fixed, ..replacement[:])
		p = p[taken:]
	}
	return text_value(h, string(fixed[:]))
}

@(private)
HEX_DIGITS :: "0123456789abcdef"

// `s` as lowercase hex.
@(require_results)
encode_hex :: proc(h: ^Heap, s: string) -> (res: Value, status: Status) {
	v, out := make_text(h, 2 * len(s)) or_return
	digits := HEX_DIGITS
	for c, i in transmute([]u8)s {
		out[2 * i], out[2 * i + 1] = digits[c >> 4], digits[c & 15]
	}
	return v, .Ok
}

// The text of the bytes hex text `s` holds, each ill-formed UTF-8 sequence one U+FFFD.
@(require_results)
decode_hex :: proc(h: ^Heap, s: string) -> (res: Value, ok: bool, status: Status) {
	out := make([]u8, len(s) / 2, h.allocator)
	if out == nil && len(s) >= 2 {
		return NULL, false, fail_memory(h)
	}
	defer delete(out, h.allocator)
	decoded, valid := hex.decode_into_buffer(transmute([]u8)s, out)
	if !valid {
		return NULL, false, .Ok
	}
	v, st := text_lossy(h, decoded)
	return v, true, st
}

// `s` with every byte but ASCII letters, digits and those of `keep` as `%XX`.
@(require_results)
percent_encode :: proc(h: ^Heap, s: string, keep: string) -> (res: Value, status: Status) {
	kept :: proc(c: u8, keep: string) -> bool {
		if c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' {
			return true
		}
		for k in transmute([]u8)keep {
			if k == c {
				return true
			}
		}
		return false
	}
	n := 0
	for c in transmute([]u8)s {
		n += 1 if kept(c, keep) else 3
	}
	v, out := make_text(h, n) or_return
	upper := "0123456789ABCDEF"
	k := 0
	for c in transmute([]u8)s {
		if kept(c, keep) {
			out[k] = c
			k += 1
		} else {
			out[k], out[k + 1], out[k + 2] = '%', upper[c >> 4], upper[c & 15]
			k += 3
		}
	}
	return v, .Ok
}

// `s` with each `%XX` as its byte, `plus` reading `+` as a space, or false for a `%` not before two hex digits.
@(require_results)
percent_decode :: proc(h: ^Heap, s: string, plus: bool) -> (res: Value, ok: bool, status: Status) {
	out := make([dynamic]u8, 0, len(s), h.allocator)
	defer delete(out)
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		switch {
		case c == '%':
			if i + 2 >= len(s) {
				return NULL, false, .Ok
			}
			hi, lo := spell.HEX_NIBBLE[s[i + 1]], spell.HEX_NIBBLE[s[i + 2]]
			if hi | lo > 15 {
				return NULL, false, .Ok
			}
			append(&out, hi << 4 | lo)
			i += 2
		case c == '+' && plus:
			append(&out, ' ')
		case:
			append(&out, c)
		}
	}
	v := text_lossy(h, out[:]) or_return
	return v, true, .Ok
}
