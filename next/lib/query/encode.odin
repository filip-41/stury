package query

import "core:encoding/base32"
import "core:encoding/base64"
import "core:encoding/hex"
import "stury:lib/base/kernel"
import "stury:lib/base/spell"

// Byte encodings of texts: base64 (standard and URL alphabets), base32, hex and percent encoding, each way.

// The alphabets of base 64 and 32 that texts are written in.
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

// Why a text does not decode as base 64 or 32.
Decode_Fault :: enum u8 {
	None,
	Bad_Digit, // a byte outside the alphabet
	Lone_Digit, // a last digit that holds no whole byte
}

// The text of the bytes base 64 or 32 text `s` in `base` holds, padding optional, each ill-formed UTF-8 sequence one
// U+FFFD, or the fault that is in `s`.
@(require_results)
decode_base :: proc(h: ^Heap, s: string, base: Base) -> (res: Value, fault: Decode_Fault, status: Status) {
	// What the groups of `s` hold at most, its padding not yet taken off.
	room := len(s) / 8 * 5 + 4 if base == .Base32 else len(s) / 4 * 3 + 2
	out := make([]u8, room, h.allocator)
	if out == nil {
		return NULL, .None, fail_memory(h)
	}
	defer delete(out, h.allocator)
	decoded: []u8
	malformed, failed: bool
	switch base {
	case .Base64:
		err: base64.Error
		decoded, err = base64.decode_into_buf(out, s)
		malformed, failed = err == base64.Decode_Error.Malformed_Quantum, err != nil
	case .Base64_Url:
		err: base64.Error
		decoded, err = base64.decode_into_buf(out, s, base64.DEC_URL_TABLE)
		malformed, failed = err == base64.Decode_Error.Malformed_Quantum, err != nil
	case .Base32:
		err: base32.Error
		decoded, err = base32.decode_into_buf(out, s)
		malformed, failed = err == base32.Decode_Error.Malformed_Quantum, err != nil
	}
	if failed {
		// A text that ends in a lone digit is judged by the digits before it first, as jq reads from the front.
		if malformed && !has_bad_digit(s, base) {
			return NULL, .Lone_Digit, .Ok
		}
		return NULL, .Bad_Digit, .Ok
	}
	v, st := text_lossy(h, decoded)
	return v, .None, st
}

// Whether `s` holds a byte that is no digit of `base`, its trailing padding aside.
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

// A string of `bytes`, each ill-formed UTF-8 sequence in them one U+FFFD. A sequence takes the bytes its lead byte
// announces, and all that is left when the text ends inside it, or fewer when a byte that is no continuation comes
// first.
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
		taken := announced
		if left := int(uintptr(end) - uintptr(p)); announced > left {
			taken = left
		} else {
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

HEX_DIGITS :: "0123456789abcdef"

// `s` as lowercase hex. `core:encoding/hex` writes into a fresh slice or a writer only, which would copy the text.
@(require_results)
encode_hex :: proc(h: ^Heap, s: string) -> (res: Value, status: Status) {
	v, out := make_text(h, 2 * len(s)) or_return
	for i in 0 ..< len(s) {
		digits := HEX_DIGITS
		out[2 * i] = digits[s[i] >> 4]
		out[2 * i + 1] = digits[s[i] & 15]
	}
	return v, .Ok
}

@(private)
hex_value :: proc "contextless" (c: u8) -> int {
	switch c {
	case '0' ..= '9':
		return int(c - '0')
	case 'a' ..= 'f':
		return int(c - 'a' + 10)
	case 'A' ..= 'F':
		return int(c - 'A' + 10)
	}
	return -1
}

// The text of the bytes hex text `s` holds, each ill-formed UTF-8 sequence one U+FFFD, or false for an odd length or a
// byte that is no hex digit.
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
	for i in 0 ..< len(s) {
		n += 1 if kept(s[i], keep) else 3
	}
	v, out := make_text(h, n) or_return
	k := 0
	for i in 0 ..< len(s) {
		c := s[i]
		if kept(c, keep) {
			out[k] = c
			k += 1
			continue
		}
		upper := "0123456789ABCDEF"
		out[k], out[k + 1], out[k + 2] = '%', upper[c >> 4], upper[c & 15]
		k += 3
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
			if i + 2 >= len(s) || hex_value(s[i + 1]) < 0 || hex_value(s[i + 2]) < 0 {
				return NULL, false, .Ok
			}
			append(&out, u8(hex_value(s[i + 1]) << 4 | hex_value(s[i + 2])))
			i += 2
		case c == '+' && plus:
			append(&out, ' ')
		case:
			append(&out, c)
		}
	}
	v := text_value(h, string(out[:])) or_return
	return v, true, .Ok
}
