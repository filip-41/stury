package yaml

import "base:runtime"
import "core:math"
import "core:strconv"
import "core:unicode/utf8"
import "stury:lib/base/spell"
import "stury:lib/core/tape"

// YAML scalar decoding, `!!binary` base64 payload decoding/key normalization, canonical key spelling for non-string
// keys, streaming decode-free key comparison/hashing, and decode buffer sizing (`decode_room`).

// Decodes a scalar's bytes into caller buffer `buf`, borrowing `buf`. Note: for quoted scalars, `span` MUST already be
// the inner bytes between quotes (without the surrounding `'` or `"` delimiters).
@(private)
decode_scalar_bytes :: proc "contextless" (span: []u8, spelling: u16, buf: []u8) -> (s: string, ok: bool) #no_bounds_check {
	o := Decoded{buf = buf}
	switch style_of(spelling) {
	case .Plain:
		fold_flow(&o, span, .Plain)
	case .Single:
		fold_flow(&o, span, .Single)
	case .Double:
		fold_flow(&o, span, .Double)
	case .Block:
		decode_block(&o, span, spelling)
	}
	return string(buf[:o.n]), !o.over
}

// Decodes the text of a `.Number` node written as a quoted or block scalar into `buf`.
@(private)
decode_number_scalar_bytes :: proc "contextless" (src: []u8, t: tape.Node, buf: []u8) -> (s: string, ok: bool) #no_bounds_check {
	span := src[t.lo:][:t.n]
	nk := Number_Spelling(t.spelling & tape.NUMBER_KIND)
	o := Decoded{buf = buf}
	if number_is_block(nk) {
		decode_block(&o, span, t.spelling)
	} else {
		st := Style.Single if style_of(t.spelling) == .Single else .Double
		fold_flow(&o, span, st)
	}
	return string(buf[:o.n]), !o.over
}

@(private)
scalar_needs_decode :: #force_inline proc "contextless" (t: tape.Token) -> bool {
	if t.kind == .Number {
		nk := Number_Spelling(t.spelling & tape.NUMBER_KIND)
		return number_is_quoted(nk) || number_is_block(nk)
	}
	return t.spelling & tape.SPELLING_DECODE != 0
}

// Writer into caller buffer `buf`; writes past the end set `over`.
@(private)
Decoded :: struct {
	buf:  []u8,
	n:    int,
	over: bool,
}

@(private = "file")
dec_put :: #force_inline proc "contextless" (o: ^Decoded, b: u8) #no_bounds_check {
	if o.n < len(o.buf) {
		o.buf[o.n] = b
		o.n += 1
	} else {
		o.over = true
	}
}

@(private = "file")
dec_put_rune :: proc "contextless" (o: ^Decoded, cp: u32) {
	r, n := utf8.encode_rune(rune(cp))
	for i in 0 ..< n {
		dec_put(o, r[i])
	}
}

// Decodes a plain, single-quoted or double-quoted scalar body (`s` without quotes).
@(private)
fold_flow :: proc "contextless" (o: ^Decoded, s: []u8, style: Style) #no_bounds_check {
	keep := 0
	i := 0
	for i < len(s) {
		c := s[i]
		switch {
		case c == '\n' || c == '\r':
			o.n = keep
			empties: int
			i, empties = skip_empty_lines(s, skip_break(s, i))
			if empties == 0 {
				dec_put(o, ' ')
			}
			for _ in 0 ..< empties {
				dec_put(o, '\n')
			}
			keep = o.n
		case style == .Double && c == '\\':
			i += 1
			if i >= len(s) {
				return
			}
			e := s[i]
			if e == '\n' || e == '\r' {
				empties: int
				i, empties = skip_empty_lines(s, skip_break(s, i))
				for _ in 0 ..< empties {
					dec_put(o, '\n')
				}
				keep = o.n
				continue
			}
			i += 1
			switch e {
			case '0': dec_put(o, 0)
			case 'a': dec_put(o, 7)
			case 'b': dec_put(o, 8)
			case 't', '\t': dec_put(o, '\t')
			case 'n': dec_put(o, '\n')
			case 'v': dec_put(o, 11)
			case 'f': dec_put(o, 12)
			case 'r': dec_put(o, '\r')
			case 'e': dec_put(o, 27)
			case ' ': dec_put(o, ' ')
			case '"': dec_put(o, '"')
			case '/': dec_put(o, '/')
			case '\\': dec_put(o, '\\')
			case 'N': dec_put_rune(o, 0x85)
			case '_': dec_put_rune(o, 0xa0)
			case 'L': dec_put_rune(o, 0x2028)
			case 'P': dec_put_rune(o, 0x2029)
			case 'x', 'u', 'U':
				digits := 2 if e == 'x' else 4 if e == 'u' else 8
				cp, _ := yaml_hex_run(s, i, digits)
				i += digits
				dec_put_rune(o, cp)
			}
			keep = o.n
		case style == .Single && c == '\'':
			dec_put(o, '\'')
			i += 2
			keep = o.n
		case:
			dec_put(o, c)
			i += 1
			if c != ' ' && c != '\t' {
				keep = o.n
			}
		}
	}
}

@(private = "file")
skip_empty_lines :: proc "contextless" (s: []u8, at_in: int) -> (at, empties: int) #no_bounds_check {
	at = at_in
	for {
		for at < len(s) && (s[at] == ' ' || s[at] == '\t') {
			at += 1
		}
		if at < len(s) && (s[at] == '\n' || s[at] == '\r') {
			at = skip_break(s, at)
			empties += 1
			continue
		}
		return
	}
}

@(private = "file")
skip_break :: #force_inline proc "contextless" (s: []u8, i: int) -> int #no_bounds_check {
	if s[i] == '\r' && i + 1 < len(s) && s[i + 1] == '\n' {
		return i + 2
	}
	return i + 1
}

// Decodes a block scalar (`|` or `>`) from its header through its last line into `o`.
@(private)
decode_block :: proc "contextless" (o: ^Decoded, s: []u8, spelling: u16) #no_bounds_check {
	if len(s) == 0 {
		return
	}
	folded := s[0] == '>'
	keep, strip := false, false
	i := 1
	for i < len(s) && s[i] != '\n' && s[i] != '\r' && s[i] != ' ' && s[i] != '\t' {
		switch s[i] {
		case '+': keep = true
		case '-': strip = true
		}
		i += 1
	}
	for i < len(s) && s[i] != '\n' && s[i] != '\r' {
		i += 1
	}
	if i >= len(s) {
		return
	}
	i = skip_break(s, i)
	ci := block_explicit_indent(spelling)
	if ci < 0 {
		ci = max(int)
		j := i
		for j < len(s) {
			m := j
			for m < len(s) && s[m] == ' ' {
				m += 1
			}
			if m < len(s) && s[m] != '\n' && s[m] != '\r' {
				ci = m - j
				break
			}
			for m < len(s) && s[m] != '\n' && s[m] != '\r' {
				m += 1
			}
			j = skip_break(s, m) if m < len(s) else m
		}
	}
	last := -1
	for pass in 0 ..< 2 {
		first, prev_spaced := true, false
		empties := 0
		j := i
		for j < len(s) {
			m := j
			for m < len(s) && s[m] == ' ' {
				m += 1
			}
			e := m
			for e < len(s) && s[e] != '\n' && s[e] != '\r' {
				e += 1
			}
			empty := m == e && m - j <= ci
			if pass == 0 {
				if !empty {
					last = j
				}
			} else if empty {
				if last >= 0 && j < last {
					empties += 1
				} else if keep {
					dec_put(o, '\n')
				}
			} else {
				lo := min(j + ci, e)
				spaced := lo < e && (s[lo] == ' ' || s[lo] == '\t')
				if first {
					for _ in 0 ..< empties {
						dec_put(o, '\n')
					}
				} else if !folded || prev_spaced || spaced {
					for _ in 0 ..< empties + 1 {
						dec_put(o, '\n')
					}
				} else if empties == 0 {
					dec_put(o, ' ')
				} else {
					for _ in 0 ..< empties {
						dec_put(o, '\n')
					}
				}
				for b in s[lo:e] {
					dec_put(o, b)
				}
				first, prev_spaced, empties = false, spaced, 0
				if j == last && !strip {
					dec_put(o, '\n')
				}
			}
			j = skip_break(s, e) if e < len(s) else e
		}
	}
}

// Decodes YAML node `t` into `buf` (without allocator). Always returns a subslice of `buf` when non-empty.
// Handles `.String`/`.Plain` (decoding), `.Bytes` (raw payload for values, whitespace-normalized base64 for keys),
// and `.Null`/`.False`/`.True`/`.Number` canonical text for keys.
@(private)
text_decoded :: proc "contextless" (src: []u8, t: tape.Node, buf: []u8, _: ^tape.Format_Ext) -> (s: string, ok: bool) #no_bounds_check {
	switch t.kind {
	case .Null:
		return copy_literal("null", buf)
	case .False:
		return copy_literal("false", buf)
	case .True:
		return copy_literal("true", buf)
	case .Number:
		return canonical_number_to(src, t, buf)
	case .Bytes:
		return decode_binary_to(src, t, buf, t.role == .Key)
	case .String, .Plain:
		if t.spelling & tape.SPELLING_DECODE == 0 {
			if len(buf) < int(t.n) {
				return "", false
			}
			copied := copy(buf, src[t.lo:][:t.n])
			return string(buf[:copied]), true
		}
		return decode_scalar_bytes(src[t.lo:][:t.n], t.spelling, buf)
	case .Array, .Object, .End:
	}
	return "", false
}

@(private = "file")
copy_literal :: #force_inline proc "contextless" (lit: string, buf: []u8) -> (string, bool) {
	if len(buf) < len(lit) {
		return "", false
	}
	copied := copy(buf, lit)
	return string(buf[:copied]), true
}

// Upper-bound buffer size needed to decode scalar `t` via `Format.decode`.
@(private)
decode_room :: proc "contextless" (src: []u8, t: tape.Node, _: ^tape.Format_Ext) -> int {
	switch t.kind {
	case .Null:
		return 4
	case .False:
		return 5
	case .True:
		return 4
	case .Number:
		nk := Number_Spelling(t.spelling & tape.NUMBER_KIND)
		if nk == .Inf || nk == .Nan || nk == .Quoted_Inf || nk == .Quoted_Nan {
			return 5
		}
		if nk == .Hex || nk == .Octal || nk == .Quoted_Hex || nk == .Quoted_Octal || nk == .Block_Num {
			return max(40, int(t.n) * 5 / 4 + 4)
		}
		return max(40, int(t.n) + 8)
	case .Bytes:
		return int(t.n)
	case .String, .Plain:
		if t.spelling & tape.SPELLING_DECODE == 0 {
			return 0
		}
		if t.spelling & tape.SPELLING_LAX != 0 {
			return 3 * int(t.n)
		}
		return int(t.n)
	case .Array, .Object, .End:
	}
	return 0
}

// Writes the canonical YAML key text of `.Number` token `t` into `buf`:
// - Integers (`.Int` / `.Uint`, or oversized hex/octal): exact base-10 digits (integer `-0` normalizes to `"0"`).
// - Floats (`.Float` / `.Wide`): `".inf"`, `"-.inf"`, `".nan"`, shortest exact finite decimal with `".0"` if whole
//   (preserving `-0.0` vs `0.0`), so keys of equal YAML numeric type & value hash and compare identically while integers
//   (`"1"`) and floats (`"1.0"`) remain distinct.
@(private)
canonical_number_to :: proc "contextless" (src: []u8, t: tape.Node, buf: []u8) -> (string, bool) #no_bounds_check {
	nk := Number_Spelling(t.spelling & tape.NUMBER_KIND)
	n := number_value(src, t)
	switch n.kind {
	case .Int:
		v := i64(n.bits)
		tmp: [24]u8 = ---
		digits := write_i64_dec(tmp[:], v)
		return copy_literal(digits, buf)
	case .Uint:
		tmp: [24]u8 = ---
		digits := write_u64_dec(tmp[:], n.bits)
		return copy_literal(digits, buf)
	case .Float:
		// Oversized hex/octal/decimal integers spill past u64 and overflow f64 to +Inf/-Inf in `number_value`: check
		// exact integer keys BEFORE checking `is_inf` so >308-digit integers keep their exact canonical digits!
		if !number_is_forced_float(nk) && nk != .Inf && nk != .Quoted_Inf && nk != .Nan && nk != .Quoted_Nan {
			if nk == .Hex || nk == .Octal || nk == .Quoted_Hex || nk == .Quoted_Octal || nk == .Block_Num {
				if dec, dok, wide := exact_radix_key_to(src, t, buf); wide {
					return dec, dok
				}
			}
			if dec, dok, wide := exact_int_key_to(src, t, buf); wide {
				return dec, dok
			}
		}
		f := transmute(f64)n.bits
		if math.is_nan(f) {
			return copy_literal(".nan", buf)
		}
		if math.is_inf(f, 1) {
			return copy_literal(".inf", buf)
		}
		if math.is_inf(f, -1) {
			return copy_literal("-.inf", buf)
		}
		context = runtime.default_context()
		tmp: [40]u8 = ---
		s := strconv.write_float(tmp[:len(tmp) - 2], f, 'g', -1, 64, {})
		has_frac := false
		for b in transmute([]u8)s {
			if b == '.' || b == 'e' || b == 'E' {
				has_frac = true
				break
			}
		}
		if !has_frac {
			tmp[len(s)] = '.'
			tmp[len(s) + 1] = '0'
			s = string(tmp[:len(s) + 2])
		}
		return copy_literal(s, buf)
	case .Wide:
		// Huge decimal text: extract decoded text and copy normalized decimal into `buf`.
		stack: [512]u8 = ---
		raw := src[t.lo:][:t.n]
		text: []u8
		if scalar_needs_decode(t) {
			ds, dok := decode_number_scalar_bytes(src, t, stack[:])
			if !dok {
				return "", false
			}
			if len(ds) == 0 {
				return copy_literal(string(raw), buf)
			}
			text = transmute([]u8)ds
		} else {
			text = raw
		}
		return copy_literal(string(text), buf)
	}
	return "", false
}

// Converts an exact base-16 or base-8 integer scalar into base-10 digits in `buf`. `wide` is true iff the token really
// was hex/octal (not a float).
@(private = "file")
exact_radix_key_to :: proc "contextless" (src: []u8, t: tape.Node, buf: []u8) -> (out: string, ok, is_radix: bool) #no_bounds_check {
	raw := src[t.lo:][:t.n]
	text := raw
	stack: [512]u8 = ---
	if scalar_needs_decode(t) {
		ds, dok := decode_number_scalar_bytes(src, t, stack[:])
		if !dok {
			nk := Number_Spelling(t.spelling & tape.NUMBER_KIND)
			return "", false, nk == .Quoted_Hex || nk == .Quoted_Octal || nk == .Block_Num
		}
		text = transmute([]u8)ds
	}
	if len(text) <= 2 || text[0] != '0' || (text[1] != 'x' && text[1] != 'o') {
		return "", false, false
	}
	base := u64(16) if text[1] == 'x' else u64(8)
	s, dok := radix_decimal_to(text[2:], base, buf)
	return s, dok, true
}

// Normalizes a pure decimal integer scalar (`[-+]?[0-9]+`) that overflowed `u64` into canonical base-10 digits in `buf`.
@(private = "file")
exact_int_key_to :: proc "contextless" (src: []u8, t: tape.Node, buf: []u8) -> (out: string, ok, is_int: bool) #no_bounds_check {
	raw := src[t.lo:][:t.n]
	text := raw
	stack: [512]u8 = ---
	if scalar_needs_decode(t) {
		ds, dok := decode_number_scalar_bytes(src, t, stack[:])
		if !dok {
			return "", false, true
		}
		text = transmute([]u8)ds
	}
	if len(text) == 0 {
		return "", false, false
	}
	i := 0
	neg := false
	if text[0] == '-' || text[0] == '+' {
		neg = text[0] == '-'
		i = 1
	}
	if i >= len(text) {
		return "", false, false
	}
	for b in text[i:] {
		if b < '0' || b > '9' {
			return "", false, false
		}
	}
	for i < len(text) && text[i] == '0' {
		i += 1
	}
	if i == len(text) {
		s, dok := copy_literal("0", buf)
		return s, dok, true
	}
	sig := text[i:]
	need := int(neg) + len(sig)
	if len(buf) < need {
		return "", false, true
	}
	at := 0
	if neg {
		buf[0] = '-'
		at = 1
	}
	copy(buf[at:], sig)
	return string(buf[:at + len(sig)]), true, true
}

// Converts `digits` in `base` (8 or 16) to canonical base-10 ASCII in `buf`.
@(private)
radix_decimal_to :: proc "contextless" (digits: []u8, base: u64, buf: []u8) -> (string, bool) #no_bounds_check {
	LIMB :: u64(1_000_000_000)
	limbs: [2600]u32 = ---
	n := 0
	for b in digits {
		d := u64(spell.HEX_NIBBLE[b])
		carry := d
		for k in 0 ..< n {
			v := u64(limbs[k]) * base + carry
			limbs[k], carry = u32(v % LIMB), v / LIMB
		}
		for carry > 0 {
			if n == len(limbs) {
				return "", false
			}
			limbs[n] = u32(carry % LIMB)
			n += 1
			carry /= LIMB
		}
	}
	if n == 0 {
		return copy_literal("0", buf)
	}
	top := limbs[n - 1]
	width := 1
	for v := top; v >= 10; v /= 10 {
		width += 1
	}
	need := width + 9 * (n - 1)
	if len(buf) < need {
		return "", false
	}
	at := 0
	for k := width - 1; k >= 0; k -= 1 {
		buf[at + k] = '0' + u8(top % 10)
		top /= 10
	}
	at += width
	for l := n - 2; l >= 0; l -= 1 {
		v := limbs[l]
		for k := 8; k >= 0; k -= 1 {
			buf[at + k] = '0' + u8(v % 10)
			v /= 10
		}
		at += 9
	}
	return string(buf[:at]), true
}

// Streams base64 text of a `!!binary` node `t` directly into `buf`, emitting raw bytes (`normalize == false`) or
// whitespace-stripped base64 chars (`normalize == true`). Uses zero intermediate heap allocations.
@(private)
decode_binary_to :: proc "contextless" (src: []u8, t: tape.Node, buf: []u8, normalize: bool) -> (string, bool) #no_bounds_check {
	st := style_of(t.spelling)
	span := src[t.lo:][:t.n]
	b64 := Binary_Writer {
		buf       = buf,
		normalize = normalize,
	}
	if st == .Plain && t.spelling & tape.SPELLING_DECODE == 0 {
		for b in span {
			if !binary_put(&b64, b) {
				return "", false
			}
		}
		return string(buf[:b64.n]), true
	}
	if !stream_scalar_bytes(span, t.spelling, &b64, binary_stream_cb) {
		return "", false
	}
	return string(buf[:b64.n]), true
}

@(private = "file")
Binary_Writer :: struct {
	buf:       []u8,
	n:         int,
	quad:      [4]u8,
	qlen:      int,
	normalize: bool,
}

@(private = "file")
binary_stream_cb :: proc "contextless" (state: rawptr, b: u8) -> bool {
	return binary_put((^Binary_Writer)(state), b)
}

@(private = "file")
binary_put :: proc "contextless" (w: ^Binary_Writer, b: u8) -> bool #no_bounds_check {
	if b == ' ' || b == '\t' || b == '\n' || b == '\r' {
		return true
	}
	if w.normalize {
		if w.n >= len(w.buf) {
			return false
		}
		w.buf[w.n] = b
		w.n += 1
		return true
	}
	w.quad[w.qlen] = b
	w.qlen += 1
	if w.qlen < 4 {
		return true
	}
	v0, v1 := b64_val(w.quad[0]), b64_val(w.quad[1])
	if w.n >= len(w.buf) {
		return false
	}
	w.buf[w.n] = (v0 << 2) | (v1 >> 4)
	w.n += 1
	if w.quad[2] != '=' {
		v2 := b64_val(w.quad[2])
		if w.n >= len(w.buf) {
			return false
		}
		w.buf[w.n] = ((v1 & 0xF) << 4) | (v2 >> 2)
		w.n += 1
		if w.quad[3] != '=' {
			v3 := b64_val(w.quad[3])
			if w.n >= len(w.buf) {
				return false
			}
			w.buf[w.n] = ((v2 & 0x3) << 6) | v3
			w.n += 1
		}
	}
	w.qlen = 0
	return true
}

@(private = "file")
b64_val :: #force_inline proc "contextless" (c: u8) -> u8 {
	switch c {
	case 'A' ..= 'Z': return c - 'A'
	case 'a' ..= 'z': return c - 'a' + 26
	case '0' ..= '9': return c - '0' + 52
	case '+':         return 62
	case '/':         return 63
	}
	return 0
}

// Streaming scalar byte emitter: feeds each decoded byte of `span` into `emit(state, b)` with O(1) memory and zero heap
// allocations (tracks trailing unescaped whitespace by slice bounds in `span`).
@(private = "file")
stream_scalar_bytes :: proc "contextless" (span: []u8, spelling: u16, state: rawptr, $emit: proc "contextless" (state: rawptr, b: u8) -> bool) -> bool #no_bounds_check {
	st := style_of(spelling)
	if st == .Block {
		return stream_block_bytes(span, spelling, state, emit)
	}
	return stream_flow_bytes(span, st, state, emit)
}

@(private = "file")
write_u64_dec :: #force_inline proc "contextless" (buf: []u8, v_in: u64) -> string #no_bounds_check {
	if v_in == 0 {
		buf[0] = '0'
		return string(buf[:1])
	}
	rev: [24]u8 = ---
	n := 0
	for v := v_in; v > 0; v /= 10 {
		rev[n] = '0' + u8(v % 10)
		n += 1
	}
	for i in 0 ..< n {
		buf[i] = rev[n - 1 - i]
	}
	return string(buf[:n])
}

@(private = "file")
write_i64_dec :: #force_inline proc "contextless" (buf: []u8, v_in: i64) -> string #no_bounds_check {
	if v_in >= 0 {
		return write_u64_dec(buf, u64(v_in))
	}
	buf[0] = '-'
	mag := u64(0) - u64(v_in)
	return string(buf[:1 + len(write_u64_dec(buf[1:], mag))])
}

@(private = "file")
flush_ws :: #force_inline proc "contextless" (s: []u8, ws_lo, ws_hi: ^int, state: rawptr, $emit: proc "contextless" (state: rawptr, b: u8) -> bool) -> bool #no_bounds_check {
	for k in ws_lo^ ..< ws_hi^ {
		if !emit(state, s[k]) {
			return false
		}
	}
	ws_lo^, ws_hi^ = 0, 0
	return true
}

@(private = "file")
emit_rune :: proc "contextless" (cp: u32, state: rawptr, $emit: proc "contextless" (state: rawptr, b: u8) -> bool) -> bool {
	r, n := utf8.encode_rune(rune(cp))
	for k in 0 ..< n {
		if !emit(state, r[k]) {
			return false
		}
	}
	return true
}

@(private = "file")
stream_flow_bytes :: proc "contextless" (s: []u8, style: Style, state: rawptr, $emit: proc "contextless" (state: rawptr, b: u8) -> bool) -> bool #no_bounds_check {
	ws_lo, ws_hi := 0, 0
	i := 0
	for i < len(s) {
		c := s[i]
		switch {
		case c == '\n' || c == '\r':
			ws_lo, ws_hi = 0, 0
			empties: int
			i, empties = skip_empty_lines(s, skip_break(s, i))
			if empties == 0 {
				if !emit(state, ' ') {
					return false
				}
			}
			for _ in 0 ..< empties {
				if !emit(state, '\n') {
					return false
				}
			}
		case style == .Double && c == '\\':
			if !flush_ws(s, &ws_lo, &ws_hi, state, emit) {
				return false
			}
			i += 1
			if i >= len(s) {
				return true
			}
			e := s[i]
			if e == '\n' || e == '\r' {
				empties: int
				i, empties = skip_empty_lines(s, skip_break(s, i))
				for _ in 0 ..< empties {
					if !emit(state, '\n') {
						return false
					}
				}
				continue
			}
			i += 1
			switch e {
			case '0': if !emit(state, 0) { return false }
			case 'a': if !emit(state, 7) { return false }
			case 'b': if !emit(state, 8) { return false }
			case 't', '\t': if !emit(state, '\t') { return false }
			case 'n': if !emit(state, '\n') { return false }
			case 'v': if !emit(state, 11) { return false }
			case 'f': if !emit(state, 12) { return false }
			case 'r': if !emit(state, '\r') { return false }
			case 'e': if !emit(state, 27) { return false }
			case ' ': if !emit(state, ' ') { return false }
			case '"': if !emit(state, '"') { return false }
			case '/': if !emit(state, '/') { return false }
			case '\\': if !emit(state, '\\') { return false }
			case 'N': if !emit_rune(0x85, state, emit) { return false }
			case '_': if !emit_rune(0xa0, state, emit) { return false }
			case 'L': if !emit_rune(0x2028, state, emit) { return false }
			case 'P': if !emit_rune(0x2029, state, emit) { return false }
			case 'x', 'u', 'U':
				digits := 2 if e == 'x' else 4 if e == 'u' else 8
				cp, _ := yaml_hex_run(s, i, digits)
				i += digits
				if !emit_rune(cp, state, emit) {
					return false
				}
			}
		case style == .Single && c == '\'':
			if !flush_ws(s, &ws_lo, &ws_hi, state, emit) || !emit(state, '\'') {
				return false
			}
			i += 2
		case c == ' ' || c == '\t':
			if ws_hi == ws_lo {
				ws_lo = i
			}
			ws_hi = i + 1
			i += 1
		case:
			if !flush_ws(s, &ws_lo, &ws_hi, state, emit) || !emit(state, c) {
				return false
			}
			i += 1
		}
	}
	return flush_ws(s, &ws_lo, &ws_hi, state, emit)
}

@(private = "file")
stream_block_bytes :: proc "contextless" (s: []u8, spelling: u16, state: rawptr, $emit: proc "contextless" (state: rawptr, b: u8) -> bool) -> bool #no_bounds_check {
	if len(s) == 0 {
		return true
	}
	folded := s[0] == '>'
	keep, strip := false, false
	i := 1
	for i < len(s) && s[i] != '\n' && s[i] != '\r' && s[i] != ' ' && s[i] != '\t' {
		switch s[i] {
		case '+': keep = true
		case '-': strip = true
		}
		i += 1
	}
	for i < len(s) && s[i] != '\n' && s[i] != '\r' {
		i += 1
	}
	if i >= len(s) {
		return true
	}
	i = skip_break(s, i)
	ci := block_explicit_indent(spelling)
	if ci < 0 {
		ci = max(int)
		j := i
		for j < len(s) {
			m := j
			for m < len(s) && s[m] == ' ' {
				m += 1
			}
			if m < len(s) && s[m] != '\n' && s[m] != '\r' {
				ci = m - j
				break
			}
			for m < len(s) && s[m] != '\n' && s[m] != '\r' {
				m += 1
			}
			j = skip_break(s, m) if m < len(s) else m
		}
	}
	last := -1
	for pass in 0 ..< 2 {
		first, prev_spaced := true, false
		empties := 0
		j := i
		for j < len(s) {
			m := j
			for m < len(s) && s[m] == ' ' {
				m += 1
			}
			e := m
			for e < len(s) && s[e] != '\n' && s[e] != '\r' {
				e += 1
			}
			empty := m == e && m - j <= ci
			if pass == 0 {
				if !empty {
					last = j
				}
			} else if empty {
				if last >= 0 && j < last {
					empties += 1
				} else if keep {
					if !emit(state, '\n') {
						return false
					}
				}
			} else {
				lo := min(j + ci, e)
				spaced := lo < e && (s[lo] == ' ' || s[lo] == '\t')
				if first {
					for _ in 0 ..< empties {
						if !emit(state, '\n') {
							return false
						}
					}
				} else if !folded || prev_spaced || spaced {
					for _ in 0 ..< empties + 1 {
						if !emit(state, '\n') {
							return false
						}
					}
				} else if empties == 0 {
					if !emit(state, ' ') {
						return false
					}
				} else {
					for _ in 0 ..< empties {
						if !emit(state, '\n') {
							return false
						}
					}
				}
				for b in s[lo:e] {
					if !emit(state, b) {
						return false
					}
				}
				first, prev_spaced, empties = false, spaced, 0
				if j == last && !strip {
					if !emit(state, '\n') {
						return false
					}
				}
			}
			j = skip_break(s, e) if e < len(s) else e
		}
	}
	return true
}

// `tape.text_hash` of key `t` of `src`, using its canonical/decoded text. Zero allocation.
@(private)
key_hash :: proc "contextless" (src: []u8, t: tape.Token) -> u32 #no_bounds_check {
	if !tape.text_decodes(t) {
		return tape.text_hash(src[t.lo:][:t.n])
	}
	// Stack buffer fast path handles nearly every YAML key (implicit keys <= 1024 bytes, canonical numbers <= 40 bytes,
	// null/bool <= 5 bytes).
	if t.kind != .Bytes && (t.kind != .String || t.n <= 256) && (t.kind != .Plain || t.n <= 256) && (t.kind != .Number || t.n <= 400) {
		stack: [512]u8 = ---
		if s, ok := text_decoded(src, t, stack[:], nil); ok {
			return tape.text_hash(transmute([]u8)s)
		}
	}
	x := tape.text_hasher()
	cb :: proc "contextless" (state: rawptr, b: u8) -> bool {
		tape.text_hash_byte((^tape.Text_Hasher)(state), b)
		return true
	}
	if t.kind == .Bytes {
		b64 := Stream_Hash_B64{hash = &x}
		_ = stream_scalar_bytes(src[t.lo:][:t.n], t.spelling, &b64, proc "contextless" (state: rawptr, b: u8) -> bool {
			if b != ' ' && b != '\t' && b != '\n' && b != '\r' {
				tape.text_hash_byte((^Stream_Hash_B64)(state).hash, b)
			}
			return true
		})
	} else if t.kind == .Number {
		stream_canonical_number(src, t, &x, cb)
	} else {
		_ = stream_scalar_bytes(src[t.lo:][:t.n], t.spelling, &x, cb)
	}
	return tape.text_hasher_end(&x)
}

@(private = "file")
Stream_Hash_B64 :: struct {
	hash: ^tape.Text_Hasher,
}

// Whether key `t` of `src` and key `o` of `other` read as the same text, whatever their token kinds. Zero allocation.
@(private)
same_text :: proc "contextless" (src: []u8, t: tape.Token, other: []u8, o: tape.Token) -> bool #no_bounds_check {
	dt := tape.text_decodes(t)
	do_b := tape.text_decodes(o)
	if !dt && !do_b {
		return t.n == o.n && string(src[t.lo:][:t.n]) == string(other[o.lo:][:o.n])
	}
	stack_a: [512]u8 = ---
	stack_b: [512]u8 = ---
	sa, sb: string
	ok_a, ok_b: bool
	if dt {
		sa, ok_a = text_decoded(src, t, stack_a[:], nil)
	} else {
		sa, ok_a = string(src[t.lo:][:t.n]), true
	}
	if do_b {
		sb, ok_b = text_decoded(other, o, stack_b[:], nil)
	} else {
		sb, ok_b = string(other[o.lo:][:o.n]), true
	}
	if ok_a && ok_b {
		return sa == sb
	}
	wide_a: [4096]u8 = ---
	wide_b: [4096]u8 = ---
	if !ok_a {
		sa, ok_a = text_decoded(src, t, wide_a[:], nil)
	}
	if !ok_b && ok_a {
		if do_b {
			sb, ok_b = text_decoded(other, o, wide_b[:], nil)
		} else {
			sb, ok_b = string(other[o.lo:][:o.n]), true
		}
	}
	if ok_a && ok_b {
		return sa == sb
	}
	return same_streamed_long(src, t, other, o)
}

@(private = "file")
same_streamed_long :: proc "contextless" (src: []u8, t: tape.Token, other: []u8, o: tape.Token) -> bool #no_bounds_check {
	// Windowed byte-by-byte equality over arbitrarily large scalars with O(1) memory: stream token `t` from byte offset
	// `skip` filling `win[0..<W]` per pass, comparing against streamed token `o` (O(N/W) passes with 4 KiB window).
	W :: 4096
	win: [W]u8 = ---
	Fill_State :: struct {
		win:   ^ [W]u8,
		skip:  u64,
		seen:  u64,
		filled: int,
	}
	Cmp_State :: struct {
		target: []u8,
		skip:   u64,
		seen:   u64,
		match:  bool,
	}
	offset := u64(0)
	for {
		fs := Fill_State{win = &win, skip = offset}
		emit_slice(src, t, &fs, proc "contextless" (st: rawptr, b: u8) -> bool {
			f := (^Fill_State)(st)
			if f.seen >= f.skip {
				if f.filled == W {
					f.seen += 1
					return false
				}
				f.win[f.filled] = b
				f.filled += 1
			}
			f.seen += 1
			return true
		})
		cs := Cmp_State{target = win[:fs.filled], skip = offset, match = true}
		emit_slice(other, o, &cs, proc "contextless" (st: rawptr, b: u8) -> bool {
			c := (^Cmp_State)(st)
			if c.seen >= c.skip {
				pos := int(c.seen - c.skip)
				if pos == W {
					c.seen += 1
					return false
				}
				if pos >= len(c.target) || c.target[pos] != b {
					c.match = false
					return false
				}
			}
			c.seen += 1
			return true
		})
		if !cs.match {
			return false
		}
		more_a := fs.seen > offset + W
		more_b := cs.seen > offset + W
		if more_a != more_b {
			return false
		}
		if !more_a {
			return cs.seen == offset + u64(fs.filled)
		}
		offset += W
	}
}

@(private = "file")
emit_slice :: proc "contextless" (src: []u8, t: tape.Token, state: rawptr, $emit: proc "contextless" (state: rawptr, b: u8) -> bool) #no_bounds_check {
	if !tape.text_decodes(t) {
		for b in src[t.lo:][:t.n] {
			if !emit(state, b) {
				return
			}
		}
		return
	}
	if t.kind == .Bytes {
		Wrap :: struct {
			inner: rawptr,
			emit:  proc "contextless" (state: rawptr, b: u8) -> bool,
		}
		w := Wrap{inner = state, emit = emit}
		_ = stream_scalar_bytes(src[t.lo:][:t.n], t.spelling, &w, proc "contextless" (st: rawptr, b: u8) -> bool {
			if b == ' ' || b == '\t' || b == '\n' || b == '\r' {
				return true
			}
			wr := (^Wrap)(st)
			return wr.emit(wr.inner, b)
		})
		return
	}
	if t.kind == .String || t.kind == .Plain {
		_ = stream_scalar_bytes(src[t.lo:][:t.n], t.spelling, state, emit)
		return
	}
	if t.kind == .Number {
		stream_canonical_number(src, t, state, emit)
		return
	}
	// Null/False/True fit in small stack `tmp`.
	tmp: [16]u8 = ---
	if s, ok := text_decoded(src, t, tmp[:], nil); ok {
		for b in transmute([]u8)s {
			if !emit(state, b) {
				return
			}
		}
	}
}

// Streams the canonical key text of `.Number` node `t` byte-by-byte into `emit` in bounded stack space, handling
// arbitrary-length integers (`0x`/`0o`/leading-zero decimals) beyond `[4096]u8` without truncation.
@(private = "file")
stream_canonical_number :: proc "contextless" (src: []u8, t: tape.Node, state: rawptr, $emit: proc "contextless" (state: rawptr, b: u8) -> bool) #no_bounds_check {
	tmp: [4096]u8 = ---
	if s, ok := canonical_number_to(src, t, tmp[:]); ok {
		for b in transmute([]u8)s {
			if !emit(state, b) {
				return
			}
		}
		return
	}
	stream_num :: #force_inline proc "contextless" (src: []u8, t: tape.Node, st: rawptr, $cb: proc "contextless" (st: rawptr, b: u8) -> bool) -> bool {
		if scalar_needs_decode(t) {
			return stream_number_scalar_bytes(src[t.lo:][:t.n], t.spelling, st, cb)
		}
		for b in src[t.lo:][:t.n] {
			if !cb(st, b) {
				return false
			}
		}
		return true
	}

	nk := Number_Spelling(t.spelling & tape.NUMBER_KIND)
	// First check whether the decoded text is a huge `0x`/`0o` radix integer vs pure decimal integer/float.
	Probe :: struct {
		n:       int,
		head:    [2]u8,
		pure:    bool,
		neg:     bool,
		non_z:   bool,
		skip_z:  int,
	}
	pr := Probe{pure = true}
	_ = stream_num(src, t, &pr, proc "contextless" (st: rawptr, b: u8) -> bool {
		p := (^Probe)(st)
		idx := p.n
		p.n += 1
		if idx < 2 {
			p.head[idx] = b
		}
		if idx == 0 && (b == '+' || b == '-') {
			p.neg = b == '-'
			return true
		}
		if b < '0' || b > '9' {
			p.pure = false
			return true
		}
		if !p.non_z {
			if b == '0' {
				p.skip_z += 1
			} else {
				p.non_z = true
			}
		}
		return true
	})

	if !number_is_forced_float(nk) && pr.n > 2 && pr.head[0] == '0' && (pr.head[1] == 'x' || pr.head[1] == 'o') {
		LIMB :: u64(1_000_000_000)
		Base_State :: struct {
			limbs:    [2048]u32,
			n:        int,
			skip:     int,
			base:     u64,
			overflow: bool,
		}
		bs := Base_State{base = 16 if pr.head[1] == 'x' else 8}
		_ = stream_num(src, t, &bs, proc "contextless" (st: rawptr, b: u8) -> bool {
			s := (^Base_State)(st)
			if s.skip < 2 {
				s.skip += 1
				return true
			}
			d := u64(spell.HEX_NIBBLE[b])
			carry := d
			for k in 0 ..< s.n {
				v := u64(s.limbs[k]) * s.base + carry
				s.limbs[k], carry = u32(v % LIMB), v / LIMB
			}
			for carry > 0 {
				if s.n == len(s.limbs) {
					s.overflow = true
					return false
				}
				s.limbs[s.n] = u32(carry % LIMB)
				s.n += 1
				carry /= LIMB
			}
			return true
		})
		if !bs.overflow {
			if bs.n == 0 {
				_ = emit(state, '0')
				return
			}
			top := bs.limbs[bs.n - 1]
			dec: [9]u8 = ---
			width := 0
			for v := top; v > 0; v /= 10 {
				dec[width] = '0' + u8(v % 10)
				width += 1
			}
			for k := width - 1; k >= 0; k -= 1 {
				if !emit(state, dec[k]) {
					return
				}
			}
			for l := bs.n - 2; l >= 0; l -= 1 {
				v := bs.limbs[l]
				for k := 8; k >= 0; k -= 1 {
					dec[k] = '0' + u8(v % 10)
					v /= 10
				}
				for k in 0 ..< 9 {
					if !emit(state, dec[k]) {
						return
					}
				}
			}
			return
		}
		// Ultra-huge radix (> ~18k decimal digits): stream canonical lowercase base prefix + stripped digits in O(1) memory.
		Raw_Radix :: struct {
			inner:    rawptr,
			skip:     int,
			started:  bool,
			prefix:   u8,
			emit_cb:  proc "contextless" (state: rawptr, b: u8) -> bool,
		}
		rr := Raw_Radix{inner = state, prefix = pr.head[1], emit_cb = emit}
		if !rr.emit_cb(rr.inner, '0') || !rr.emit_cb(rr.inner, rr.prefix) {
			return
		}
		_ = stream_num(src, t, &rr, proc "contextless" (st: rawptr, b: u8) -> bool {
			r := (^Raw_Radix)(st)
			if r.skip < 2 {
				r.skip += 1
				return true
			}
			c := b | 0x20 if b >= 'A' && b <= 'F' else b
			if !r.started {
				if c == '0' {
					return true
				}
				r.started = true
			}
			return r.emit_cb(r.inner, c)
		})
		if !rr.started {
			_ = rr.emit_cb(rr.inner, '0')
		}
		return
	}

	if pr.pure && !number_is_forced_float(nk) {
		if !pr.non_z {
			_ = emit(state, '0')
			return
		}
		if pr.neg && !emit(state, '-') {
			return
		}
		Int_Emit :: struct {
			inner:   rawptr,
			started: bool,
			skip_s:  bool,
			emit_cb: proc "contextless" (state: rawptr, b: u8) -> bool,
		}
		ie := Int_Emit{inner = state, skip_s = pr.n > 0 && (pr.head[0] == '+' || pr.head[0] == '-'), emit_cb = emit}
		_ = stream_num(src, t, &ie, proc "contextless" (st: rawptr, b: u8) -> bool {
			s := (^Int_Emit)(st)
			if s.skip_s {
				s.skip_s = false
				return true
			}
			if !s.started {
				if b == '0' {
					return true
				}
				s.started = true
			}
			return s.emit_cb(s.inner, b)
		})
		return
	}

	// Huge non-integer `.Wide` float: stream raw/decoded text directly in O(1) memory.
	_ = stream_num(src, t, state, emit)
}

@(private = "file")
stream_number_scalar_bytes :: proc "contextless" (span: []u8, spelling: u16, state: rawptr, $emit: proc "contextless" (state: rawptr, b: u8) -> bool) -> bool {
	nk := Number_Spelling(spelling & tape.NUMBER_KIND)
	if number_is_block(nk) {
		return stream_block_bytes(span, spelling, state, emit)
	}
	st := Style.Single if style_of(spelling) == .Single else .Double
	return stream_flow_bytes(span, st, state, emit)
}
