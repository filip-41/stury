package scan

import "base:intrinsics"
import core_pkg "../../core"
import "base:runtime"
import "core:unicode/utf8"
import lex "lex"
import number "./number"

// The decode door: a span plus the kind the scan read off it in, a `Decoded` value out (`decode_span`).

// The `null` value. The token's kind is all there is to know.
Null :: struct {}

// The authored text of a finished number that fits no `i64`, `u64`, or binary64. A slice of `src`.
Digits :: distinct string

// The authored text of one JSON value. `marshal` copies it verbatim after checking it is exactly one strict
// value; an empty one marshals as `null`. `unmarshal` fills it with a value's source span.
Raw :: distinct string

// One decoded scalar. `i64` holds an integer token that fits and is not `-0`. `u64` holds an integer
// token past `max(i64)` that fits. `Number` is every other number with a binary64 value (`-0` among
// them: its sign is in `Number.value`). `Digits` is a finished number with none (`1e400`). `string` is
// a decoded string. `1` and `1.0` land in different arms: the authored text is the value's identity.
// Containers have no arm, and decoding one is a refusal.
Decoded :: union {
	Null,
	bool,
	i64,
	u64,
	Number,
	Digits,
	string,
}

// Decode one scalar from its span [lo, hi) of `src`. `kind` is the kind the scan
// read off the token's first byte.
//
// `escaped` is the string arm's ownership rule: an escape-free text decodes to
// a slice of `src` (zero-copy). A text with escapes decodes into `allocator`
// and the caller owns the bytes. It is false for every other arm.
//
// ok is false when the span is not a scalar decode: a container kind, a span past
// the source, a `.Null`, `.True` or `.False` that is not exactly `null`, `true` or `false`, a `.String`
// that is not one quoted token (an unescaped quote before its last byte, or none there) or has a
// malformed or truncated escape, a raw control byte or bytes that are not UTF-8, or a `.Number` that is not
// a finished number. A finished number with no binary64 value is the `Digits` arm. A lone surrogate escape
// is a malformed one. A BOM is the input's, taken only at its offset 0 by `validate`, so a span holding one
// is refused.
//
// The `Number` arm carries `number_span`'s result, the one `get_number` gives the same token.
decode_span :: proc(
	src:      []byte,
	lo, hi:   u64,
	kind:     Kind,
	allocator := context.allocator,
) -> (d: Decoded, escaped: bool, ok: bool) {
	if lo > hi || hi > u64(len(src)) {
		return nil, false, false
	}
	switch kind {
	case .Null, .True, .False:
		// The span must have the kind it was read as.
		literal := "null"
		if kind != .Null {
			literal = "true" if kind == .True else "false"
		}
		if string(src[lo:hi]) != literal {
			return nil, false, false
		}
		if kind == .Null {
			return Null{}, false, true
		}
		return kind == .True, false, true
	case .String:
		if hi < lo + 2 || src[lo] != '"' || src[hi - 1] != '"' {
			return nil, false, false
		}
		// The bytes are checked as the scan checks a string's: no raw control byte, and UTF-8.
		high := false
		p := lo + 1
		for p + 8 <= hi - 1 && plain8(src, p) {
			p += 8
		}
		for ; p < hi - 1; p += 1 {
			b := src[p]
			if lex.SPAN_STOP[b] & lex.SPAN_STOP_VALUES == 0 {
				continue
			}
			switch {
			case b == '\\':
				escaped = true
				p += 1
			case b >= 0x80:
				high = true
			case:
				// A quote or a raw control byte.
				return nil, false, false
			}
		}
		if high && !utf8.valid_string(string(src[lo + 1:hi - 1])) {
			return nil, false, false
		}
		if escaped {
			decoded, dec_ok := decode_string_inner(src, lo, hi, allocator)
			if !dec_ok {
				return nil, false, false
			}
			return string(decoded), true, true
		}
		return string(src[lo + 1:hi - 1]), false, true
	case .Number:
		if v, short := decode_short_int(src, lo, hi); short {
			return v, false, true
		}
		lexed := number.lex_number_value(src, lo, hi)
		// The decoders' lexer drops leading zeros, which a checked token cannot have. A span from any source
		// that has one (`01`) is two tokens.
		if lexed.ok && lexed.int_at != lo + (1 if src[lo] == '-' else 0) {
			return nil, false, false
		}
		d, ok = decode_number_lexed(src, lo, hi, lexed)
		return
	case .Array, .Object:
		// A container is a span, not a value.
		return nil, false, false
	}
	// Terminal statement for flow analysis. Every kind is an arm above.
	return nil, false, false
}

// True when none of the 8 bytes at `src[p:]` is a quote, a backslash, a control byte, or a high byte:
// the run a string arm skips without a per-byte look.
@(private)
plain8 :: #force_inline proc(src: []byte, p: u64) -> bool {
	LO :: 0x0101010101010101
	HI :: 0x8080808080808080
	w: u64
	#no_bounds_check {
		w = intrinsics.unaligned_load((^u64)(&src[p]))
	}
	has_zero :: #force_inline proc(x: u64) -> u64 {return (x - LO) & ~x & HI}
	return (w | (w - 0x20 * LO) | has_zero(w ~ ('"' * LO)) | has_zero(w ~ ('\\' * LO))) & HI == 0
}

// The `i64` an integer token of at most 18 digits holds, with no leading zero and not `-0`: the
// common case of `decode_span`'s `.Number` arm, read without the lexer. ok is false for every other token,
// which takes the full arm.
@(private)
decode_short_int :: #force_inline proc(src: []byte, lo, hi: u64) -> (v: i64, ok: bool) {
	if lo >= hi {
		return
	}
	p := lo
	neg := src[p] == '-'
	if neg {
		p += 1
	}
	n := hi - p
	if n == 0 || n > 18 || (src[p] == '0' && (n > 1 || neg)) {
		return
	}
	for i in p ..< hi {
		d := src[i] - '0'
		if d > 9 {
			return
		}
		v = v * 10 + i64(d)
	}
	return -v if neg else v, true
}

// `decode_span`'s `.Number` arm for the token `src[lo:hi]`, lexed as `lexed`.
@(private)
decode_number_lexed :: proc(src: []byte, lo, hi: u64, lexed: number.Number_Lex) -> (d: Decoded, ok: bool) {
	if !lexed.ok {
		return nil, false
	}
	if integer := decode_integer(src, lexed); integer != nil {
		return integer, true
	}
	n := number.number_lexed(src, lo, hi, lexed)
	if n.exactness == .None {
		return Digits(string(src[lo:hi])), true
	}
	return n, true
}

// Decode the string token `src[lo:hi]` (quotes included) to UTF-8, including
// surrogate pairs. The caller owns the result (`allocator`'s) when ok is true. Any
// malformed or truncated escape refuses and returns nothing. The span form's
// zero-copy answer is the escape-free case, which never reaches this proc.
@(private)
decode_string_inner :: proc(src: []byte, lo, hi: u64, allocator := context.allocator) -> (decoded: []byte, ok: bool) {
	// Not zeroed: the unescape writes every byte it returns.
	buf, err := runtime.mem_alloc_non_zeroed(int(hi - lo - 2), 1, allocator)
	if err != nil {
		return nil, false
	}
	out := buf[:hi - lo - 2]
	n := dom_unescape_into(out, src, lo, hi)
	if n < 0 {
		delete(out, allocator)
		return nil, false
	}
	return out[:n], true
}

// The `i64` or `u64` arm of a lexed number token (`decode_span`), or nil: a fraction or exponent text,
// `-0` (an integer has no negative zero), or a magnitude past both, so the caller falls through to a
// `Number`, never to a wrapped or sign-lost value. `i64` owns every integer it fits.
@(private)
decode_integer :: proc(src: []byte, n: number.Number_Lex) -> Decoded {
	if !n.ok || n.spelling & {.Has_Fraction, .Has_Exponent} != {} {
		return nil
	}
	mag, over, _ := core_pkg.fold_digits(src, n.int_at, n.int_at + n.int_digits, u64)
	if over {
		return nil
	}
	if .Negative in n.spelling {
		if mag == 0 || mag > u64(max(i64)) + 1 {
			return nil
		}
		// Two's complement: `mag == 2^63` wraps to `min(i64)`.
		return i64(0 - mag)
	}
	if mag <= u64(max(i64)) {
		return i64(mag)
	}
	return mag
}

// Exact integer decode of the token `src[lo:hi]`: `decode_span`'s `i64` arm, and `-0` as 0, as every integer
// target reads it. ok=false for any other token.
decode_int :: proc(src: []byte, lo, hi: u64) -> (v: i64, ok: bool) {
	v, ok = decode_whole(src, lo, hi).(i64)
	return
}

// `decode_integer` of the token `src[lo:hi]`, but `-0` is `i64(0)`: an integer has no negative zero.
@(private = "file")
decode_whole :: proc(src: []byte, lo, hi: u64) -> Decoded {
	n := number.lex_number_value(src, lo, hi)
	if n.ok && n.spelling & {.Has_Fraction, .Has_Exponent} == {} && n.int_digits == 1 && src[n.int_at] == '0' {
		return i64(0)
	}
	return decode_integer(src, n)
}
