package write

import "base:intrinsics"
import "core:encoding/base64"
import "core:math"
import "core:simd"
import "core:strconv"
import "stury:lib/base/kernel"
import "stury:lib/core/tape"

// The texts a writer spells from a document's nodes, whatever format the document was read in: a scalar's or key's
// text, a number's decimal, a comment's body.

// The bytes `number_text` writes into at most.
NUMBER_ROOM :: 40

// The text of scalar node `at`, a value or a key: a string's or plain scalar's text, decoded into the walk's scratch
// when it holds an escape, and any other scalar's bytes as written. False when the scratch cannot grow, with `w.err`
// set.
text_of :: #force_inline proc(w: ^Tree, at: tape.Node_Index) -> (s: string, ok: bool) #no_bounds_check {
	doc := w.doc
	t := doc.nodes[at]
	// A string or plain text with no escape in a document that holds its text is its bytes there.
	if u8(t.kind) - u8(tape.Kind.String) <= 1 && t.spelling & tape.SPELLING_DECODE == 0 && .Held not_in doc.flags {
		return string(doc.src[t.lo:][:t.n]), true
	}
	room := tape.text_room(doc, at)
	if room == 0 {
		return string(tape.span_bytes(doc, t.lo, t.n)), true
	}
	if len(w.scratch) < room && !scratch_grow(w, room) {
		return "", false
	}
	return tape.node_text(doc, at, w.scratch)
}

@(private)
Lanes16 :: #simd[16]u8

// The bytes of a text that a writer spells as more than themselves.
Escape_Set :: enum u8 {
	Xml_Text, // `&`, `<`, `>` and a control byte but tab and line feed
	Toml_Basic, // `"`, `\\`, a control byte, DEL and a byte past ASCII
}

@(private, rodata)
ESCAPED := [Escape_Set][256]bool {
	.Xml_Text   = {0 ..< 9 = true, 11 ..< 32 = true, '&' = true, '<' = true, '>' = true},
	.Toml_Basic = {0 ..< 32 = true, '"' = true, '\\' = true, 0x7F ..= 0xFF = true},
}

// The length of the longest prefix of `b` that holds no byte of `set`, which a writer copies as it is.
clean_prefix :: proc "contextless" (b: []u8, $SET: Escape_Set) -> int #no_bounds_check {
	p := raw_data(b)
	i := 0
	for ; i + 16 <= len(b); i += 16 {
		if hits(load_lanes(p[i:]), SET) {
			break
		}
	}
	// The last block of a text of 16 bytes or more ends with it, overlapping the one before, and a text of 8 to 15
	// bytes is two overlapping words.
	if i < len(b) {
		// Past a block that held a byte the whole text is not clean, so only a loop that ended on the text's end tests it.
		if len(b) >= 16 {
			if i + 16 > len(b) && !hits(load_lanes(p[len(b) - 16:]), SET) {
				return len(b)
			}
		} else if len(b) >= 8 && i == 0 {
			if !word_hits(kernel.load8(p), SET) && !word_hits(kernel.load8(p[len(b) - 8:]), SET) {
				return len(b)
			}
		}
	}
	for ; i < len(b); i += 1 {
		if ESCAPED[SET][p[i]] {
			break
		}
	}
	return i
}

// Whether the eight bytes of `x` may hold a byte of `set`: it holds none when this says no, and it also says yes for a tab
// or a line feed of an XML text.
@(private)
word_hits :: #force_inline proc "contextless" (x: u64, $SET: Escape_Set) -> bool {
	ONES :: u64(0x0101010101010101)
	HIGH :: u64(0x8080808080808080)
	has_zero :: #force_inline proc "contextless" (x: u64) -> u64 {
		return (x - ONES) & ~x & HIGH
	}
	small := (x - 0x20 * ONES) & ~x & HIGH
	when SET == .Xml_Text {
		return small | has_zero(x ~ '&' * ONES) | has_zero(x ~ '<' * ONES) | has_zero(x ~ '>' * ONES) != 0
	} else {
		return small | has_zero(x ~ '"' * ONES) | has_zero(x ~ '\\' * ONES) | has_zero(x ~ 0x7F * ONES) | x & HIGH != 0
	}
}

// The lanes of `v` below a space, and a load of 16 bytes, outside the procs of a set so an import of them is used
// where no set is.
@(private)
control_lanes :: #force_inline proc "contextless" (v: Lanes16) -> Lanes16 {
	return simd.lanes_lt(v, Lanes16(0x20))
}

@(private)
load_lanes :: #force_inline proc "contextless" (p: [^]u8) -> Lanes16 {
	return kernel.load16(p)
}

@(private)
hits :: #force_inline proc "contextless" (v: Lanes16, $SET: Escape_Set) -> bool {
	control := control_lanes(v)
	when SET == .Xml_Text {
		plain := simd.lanes_eq(v, Lanes16('\t')) | simd.lanes_eq(v, Lanes16('\n'))
		return kernel.any_lane16(simd.bit_and_not(control, plain) | simd.lanes_eq(v, Lanes16('&')) | simd.lanes_eq(v, Lanes16('<')) | simd.lanes_eq(v, Lanes16('>')))
	} else {
		return kernel.any_lane16(control | simd.lanes_eq(v, Lanes16('"')) | simd.lanes_eq(v, Lanes16('\\')) | simd.lanes_ge(v, Lanes16(0x7F)))
	}
}

// The text of scalar token `t`, a key of a table's header, which is no node: as `text_of` gives a node's.
text_of_token :: proc(w: ^Tree, t: tape.Token) -> (s: string, ok: bool) #no_bounds_check {
	doc := w.doc
	room := tape.text_room(doc, t)
	if room == 0 {
		return string(tape.span_bytes(doc, t.lo, t.n)), true
	}
	if len(w.scratch) < room && !scratch_grow(w, room) {
		return "", false
	}
	return tape.node_text(doc, t, w.scratch)
}

// The base64 of the payload of byte string node `at`, as the readers spell a byte string key, in a buffer from the walk's
// allocator that the caller frees. False with `w.err` set when the scratch or the buffer cannot grow.
bytes_base64 :: proc(w: ^Tree, at: tape.Node_Index) -> (s: string, ok: bool) {
	payload := text_of(w, at) or_return
	encoded, err := base64.encode(transmute([]u8)payload, allocator = w.allocator)
	if err != nil {
		w.err = err
		return "", false
	}
	return encoded, true
}

@(private, cold)
scratch_grow :: #force_no_inline proc(w: ^Tree, room: int) -> bool {
	size := max(room, 2 * len(w.scratch), 256)
	raw, err := alloc_bytes(size, 1, w.allocator)
	if err != nil {
		w.err = err
		return false
	}
	if w.scratch != nil {
		delete(w.scratch, w.allocator)
	}
	w.scratch = raw
	return true
}

// The RFC 8259 text of number node `at`: in a binary format its value in decimal, exact, else its bytes when they are
// one, a JSON5 decimal (`+1`, `.5`, `5.`) or hex integer spelled as one exactly, in `buf` or the walk's scratch, else its value's decimal, the shortest that reads back as the
// same binary64 for a fraction, with `.0` added to a whole one so it stays a float. False for a value with none:
// infinite, not a number, past 64 bits with no exact spelling, or with `w.err` set when the scratch cannot grow.
number_text :: proc(w: ^Tree, at: tape.Node_Index, buf: ^[NUMBER_ROOM]u8) -> (string, bool) #no_bounds_check {
	doc := w.doc
	if .Binary in doc.format.caps {
		// The bytes are an encoding, and no float spells an integer past `i64`. A value with no text gives an empty one.
		s, ok := text_of(w, at)
		return s, ok && len(s) > 0
	}
	t := doc.nodes[at]
	b := tape.span_bytes(doc, t.lo, t.n)
	// A `+` is the one sign JSON5 adds to a number that is otherwise RFC 8259's, and its text is the bytes after it.
	plus := 1 if len(b) > 1 && b[0] == '+' else 0
	if is_json_number(b[plus:]) {
		return string(b[plus:]), true
	}
	if hex, decimal := number5_shape(b); hex || decimal {
		if hex && len(b) - hex_digits_at(b) <= MAX_HEX_DIGITS_U64 {
			return hex_text(b, buf), true
		}
		// A hex digit is under 1.21 decimal digits, and a decimal gains at most a `0` on each side of its point.
		room := len(b) * 5 / 4 + 4
		dst := buf[:]
		if room > len(dst) {
			if len(w.scratch) < room && !scratch_grow(w, room) {
				return "", false
			}
			dst = w.scratch
		}
		if hex && len(b) - hex_digits_at(b) <= MAX_HEX_DIGITS {
			return string(dst[:decimal_of_hex(dst, b)]), true
		}
		if decimal {
			s := dst[:respell_decimal5(dst, b)]
			if is_json_number(s) {
				return string(s), true
			}
		}
	}
	n, _ := tape.node_number(doc, at)
	switch n.kind {
	case .Int:
		return strconv.write_int(buf[:], i64(n.bits), 10), true
	case .Uint:
		return strconv.write_uint(buf[:], n.bits, 10), true
	case .Float:
		f := transmute(f64)n.bits
		if math.is_inf(f) || math.is_nan(f) {
			return "", false
		}
		s := strconv.write_float(buf[:len(buf) - 2], f, 'g', -1, 64, {})
		for c in transmute([]u8)s {
			if c == '.' || c == 'e' {
				return s, true
			}
		}
		buf[len(s)], buf[len(s) + 1] = '.', '0'
		return string(buf[:len(s) + 2]), true
	case .Wide:
	}
	return "", false
}

// The most hex digits that `i64` holds.
@(private)
MAX_HEX_DIGITS_U64 :: 15

// The most hex digits of a number `number_text` writes in decimal, a bound on its quadratic work.
@(private)
MAX_HEX_DIGITS :: 4096

// Whether `b`, a number that is not RFC 8259's, is spelled as a JSON5 hex integer, a sign, `0x` and hex digits, or as
// a decimal of digits, points, signs and exponents whose respelling `is_json_number` may take.
@(private)
number5_shape :: proc "contextless" (b: []u8) -> (hex, decimal: bool) #no_bounds_check {
	if len(b) == 0 {
		return
	}
	at := hex_digits_at(b)
	if len(b) > at && b[at - 2] == '0' && b[at - 1] | 0x20 == 'x' {
		hex = true
		for c in b[at:] {
			hex &&= c - '0' < 10 || (c | 0x20) - 'a' < 6
		}
		return
	}
	decimal = true
	for c in b {
		decimal &&= c - '0' < 10 || c == '.' || c == '+' || c == '-' || c | 0x20 == 'e'
	}
	return
}

// Where the digits of a hex integer start, past its sign and `0x`.
@(private)
hex_digits_at :: proc "contextless" (b: []u8) -> int {
	return 3 if b[0] == '+' || b[0] == '-' else 2
}

// Writes JSON5 decimal `b` (`+1`, `.5`, `5.`, `+.5e3`) at `dst` as JSON spells it: no `+`, and a `0` before a point
// with no digit before it and after one with no digit after it. Returns its length, at most `len(b) + 2`.
@(private)
respell_decimal5 :: proc "contextless" (dst, b: []u8) -> int #no_bounds_check {
	n, i := 0, 0
	if b[0] == '+' || b[0] == '-' {
		if b[0] == '-' {
			dst[0] = '-'
			n = 1
		}
		i = 1
	}
	if i < len(b) && b[i] == '.' {
		dst[n] = '0'
		n += 1
	}
	for ; i < len(b); i += 1 {
		dst[n] = b[i]
		n += 1
		if b[i] == '.' && (i + 1 == len(b) || b[i + 1] - '0' >= 10) {
			dst[n] = '0'
			n += 1
		}
	}
	return n
}

// Hex integer `b` (`0x1F`, `-0xff`), of at most `MAX_HEX_DIGITS_U64` digits, in decimal, in `buf`.
@(private)
hex_text :: proc(b: []u8, buf: ^[NUMBER_ROOM]u8) -> string #no_bounds_check {
	v: i64
	for c in b[hex_digits_at(b):] {
		d := c | 0x20
		v = v << 4 | i64(d - '0' if d <= '9' else d - 'a' + 10)
	}
	return strconv.write_int(buf[:], -v if b[0] == '-' else v, 10)
}

// Writes hex integer `b` (`0x1F`, `-0xff`), of at most `MAX_HEX_DIGITS` digits, at `dst` in decimal, through limbs of
// nine decimal digits. Returns its length.
@(private)
decimal_of_hex :: proc "contextless" (dst, b: []u8) -> int #no_bounds_check {
	n := 0
	if b[0] == '-' {
		dst[0] = '-'
		n = 1
	}
	LIMB :: 1_000_000_000
	// Each hex digit adds under 1.21 decimal digits, so a limb holds at least 7 of them.
	limbs: [MAX_HEX_DIGITS / 7 + 2]u32 = ---
	held := 1
	limbs[0] = 0
	for i := hex_digits_at(b); i < len(b); i += 1 {
		c := b[i] | 0x20
		carry := u64(c - '0' if c <= '9' else c - 'a' + 10)
		for k in 0 ..< held {
			v := u64(limbs[k]) * 16 + carry
			limbs[k], carry = u32(v % LIMB), v / LIMB
		}
		if carry != 0 {
			limbs[held] = u32(carry)
			held += 1
		}
	}
	for k := held - 1; k >= 0; k -= 1 {
		digits: [9]u8
		v := limbs[k]
		d := len(digits)
		for {
			d -= 1
			digits[d] = '0' + u8(v % 10)
			v /= 10
			if v == 0 && (k == held - 1 || d == 0) {
				break
			}
		}
		n += copy(dst[n:], digits[d:])
	}
	return n
}

// Whether `b` is one RFC 8259 number, with nothing before or after it.
is_json_number :: #force_inline proc "contextless" (b: []u8) -> bool #no_bounds_check {
	if len(b) == 0 || (b[0] != '-' && b[0] - '0' >= 10) {
		return false
	}
	p, end := raw_data(b), intrinsics.ptr_offset(raw_data(b), len(b))
	q, _, kind := tape.number_scan(p, end, false, false)
	return kind == .None && q == end
}

// The body of comment `f` of `doc`, its bytes between its markers, and whether its marker closes at the line's end.
comment_body :: proc "contextless" (doc: ^tape.Document, f: tape.Fact) -> (body: []u8, line: bool) {
	span := tape.span_bytes(doc, f.lo, f.n)
	open, close := min(int(f.spelling & 0xFF), len(span)), int(f.spelling >> 8)
	return span[open:max(open, len(span) - close)], close == 0
}

// Copies `b` to `dst` and says whether it holds no byte of `set`, which a writer that finds one takes back by not
// moving its cursor. It stores up to 15 bytes past `len(b)`, so `dst` has that room.
copy_clean :: proc "contextless" (dst: [^]u8, b: []u8, $SET: Escape_Set) -> bool #no_bounds_check {
	p := raw_data(b)
	n := len(b)
	if n >= 16 {
		seen := false
		i := 0
		for ; i + 16 <= n; i += 16 {
			v := load_lanes(p[i:])
			intrinsics.unaligned_store((^Lanes16)(dst[i:]), v)
			seen ||= hits(v, SET)
		}
		if i < n {
			v := load_lanes(p[n - 16:])
			intrinsics.unaligned_store((^Lanes16)(dst[n - 16:]), v)
			seen ||= hits(v, SET)
		}
		return !seen
	}
	if n >= 8 {
		a, z := kernel.load8(p), kernel.load8(p[n - 8:])
		intrinsics.unaligned_store((^u64le)(dst), u64le(a))
		intrinsics.unaligned_store((^u64le)(dst[n - 8:]), u64le(z))
		if !word_hits(a, SET) && !word_hits(z, SET) {
			return true
		}
	}
	for i in 0 ..< n {
		if ESCAPED[SET][p[i]] {
			return false
		}
		dst[i] = p[i]
	}
	return true
}
