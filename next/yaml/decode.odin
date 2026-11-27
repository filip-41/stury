package yaml

import "base:runtime"
import "core:math"
import "core:strconv"
import "core:unicode/utf8"
import "stury:lib/base/spell"
import "stury:lib/core/tape"

// YAML scalar decoding, `!!binary` base64 payload decoding/key normalization, canonical key spelling for non-string
// keys, streaming decode-free key comparison/hashing, and decode buffer sizing (`decode_room`).

@(private)
Decoded :: struct {
	buf:  []u8,
	n:    int,
	over: bool,
}

@(private = "file")
decoded_emit :: proc "contextless" (state: rawptr, b: u8) -> bool #no_bounds_check {
	o := (^Decoded)(state)
	if o.n < len(o.buf) {
		o.buf[o.n] = b
		o.n += 1
		return true
	}
	o.over = true
	return false
}

@(private)
decode_scalar_bytes :: proc "contextless" (span: []u8, spelling: u16, buf: []u8) -> (s: string, ok: bool) #no_bounds_check {
	o := Decoded{buf = buf}
	_ = stream_scalar_bytes(span, spelling, &o, decoded_emit)
	return string(buf[:o.n]), !o.over
}

@(private)
decode_number_scalar_bytes :: proc "contextless" (src: []u8, t: tape.Node, buf: []u8) -> (s: string, ok: bool) #no_bounds_check {
	o := Decoded{buf = buf}
	_ = stream_number_scalar_bytes(src[t.lo:][:t.n], t.spelling, &o, decoded_emit)
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

@(private = "file")
skip_empty_lines :: proc "contextless" (s: []u8, at_in: int) -> (at, empties: int) #no_bounds_check {
	at = at_in
	for {
		for at < len(s) && (s[at] == ' ' || s[at] == '\t') { at += 1 }
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
	return i + 2 if s[i] == '\r' && i + 1 < len(s) && s[i + 1] == '\n' else i + 1
}

@(private)
text_decoded :: proc "contextless" (src: []u8, t: tape.Node, buf: []u8, _: ^tape.Format_Ext) -> (s: string, ok: bool) #no_bounds_check {
	switch t.kind {
	case .Null:   return copy_literal("null", buf)
	case .False:  return copy_literal("false", buf)
	case .True:   return copy_literal("true", buf)
	case .Number: return canonical_number_to(src, t, buf)
	case .Bytes:  return decode_binary_to(src, t, buf, t.role == .Key)
	case .String, .Plain:
		if t.spelling & tape.SPELLING_DECODE == 0 { return copy_literal(string(src[t.lo:][:t.n]), buf) }
		return decode_scalar_bytes(src[t.lo:][:t.n], t.spelling, buf)
	case .Array, .Object, .End:
	}
	return "", false
}

@(private = "file")
copy_literal :: #force_inline proc "contextless" (lit: string, buf: []u8) -> (string, bool) {
	if len(buf) < len(lit) { return "", false }
	return string(buf[:copy(buf, lit)]), true
}

@(private)
decode_room :: proc "contextless" (src: []u8, t: tape.Node, _: ^tape.Format_Ext) -> int {
	switch t.kind {
	case .Null, .True: return 4
	case .False:       return 5
	case .Number:
		nk := Number_Spelling(t.spelling & tape.NUMBER_KIND)
		if nk == .Inf || nk == .Nan || nk == .Quoted_Inf || nk == .Quoted_Nan { return 5 }
		if nk == .Hex || nk == .Octal || nk == .Quoted_Hex || nk == .Quoted_Octal || nk == .Block_Num {
			return max(40, int(t.n) * 5 / 4 + 4)
		}
		return max(40, int(t.n) + 8)
	case .Bytes:
		return int(t.n)
	case .String, .Plain:
		if t.spelling & tape.SPELLING_DECODE == 0 { return 0 }
		return 3 * int(t.n) if t.spelling & tape.SPELLING_LAX != 0 else int(t.n)
	case .Array, .Object, .End:
	}
	return 0
}

@(private = "file")
num_text_in :: #force_inline proc "contextless" (src: []u8, t: tape.Node, stack: []u8) -> ([]u8, bool) #no_bounds_check {
	if !scalar_needs_decode(t) { return src[t.lo:][:t.n], true }
	ds, ok := decode_number_scalar_bytes(src, t, stack)
	return transmute([]u8)ds, ok
}

@(private)
canonical_number_to :: proc "contextless" (src: []u8, t: tape.Node, buf: []u8) -> (string, bool) #no_bounds_check {
	nk := Number_Spelling(t.spelling & tape.NUMBER_KIND)
	n := number_value(src, t)
	switch n.kind {
	case .Int:
		tmp: [24]u8 = ---
		return copy_literal(write_i64_dec(tmp[:], i64(n.bits)), buf)
	case .Uint:
		tmp: [24]u8 = ---
		return copy_literal(write_u64_dec(tmp[:], n.bits), buf)
	case .Float:
		if !number_is_forced_float(nk) && nk != .Inf && nk != .Quoted_Inf && nk != .Nan && nk != .Quoted_Nan {
			stack: [512]u8 = ---
			text, dok := num_text_in(src, t, stack[:])
			if !dok { return "", false }
			if len(text) > 2 && text[0] == '0' && (text[1] == 'x' || text[1] == 'o') {
				return radix_decimal_to(text[2:], u64(16) if text[1] == 'x' else u64(8), buf)
			}
			if dec, ok_i, is_i := exact_int_text_to(text, buf); is_i { return dec, ok_i }
		}
		f := transmute(f64)n.bits
		if math.is_nan(f) { return copy_literal(".nan", buf) }
		if math.is_inf(f, 1) { return copy_literal(".inf", buf) }
		if math.is_inf(f, -1) { return copy_literal("-.inf", buf) }
		context = runtime.default_context()
		tmp: [40]u8 = ---
		s := strconv.write_float(tmp[:len(tmp) - 2], f, 'g', -1, 64, {})
		has_frac := false
		for b in transmute([]u8)s {
			if b == '.' || b == 'e' || b == 'E' { has_frac = true; break }
		}
		if !has_frac {
			tmp[len(s)], tmp[len(s) + 1] = '.', '0'
			s = string(tmp[:len(s) + 2])
		}
		return copy_literal(s, buf)
	case .Wide:
		stack: [512]u8 = ---
		text, dok := num_text_in(src, t, stack[:])
		if !dok { return "", false }
		if len(text) == 0 { text = src[t.lo:][:t.n] }
		return copy_literal(string(text), buf)
	}
	return "", false
}

@(private = "file")
exact_int_text_to :: proc "contextless" (text, buf: []u8) -> (out: string, ok, is_int: bool) #no_bounds_check {
	if len(text) == 0 { return "", false, false }
	i := 0
	neg := false
	if text[0] == '-' || text[0] == '+' { neg, i = text[0] == '-', 1 }
	if i >= len(text) { return "", false, false }
	for b in text[i:] { if b < '0' || b > '9' { return "", false, false } }
	for i < len(text) && text[i] == '0' { i += 1 }
	if i == len(text) { s, dok := copy_literal("0", buf); return s, dok, true }
	sig := text[i:]
	if len(buf) < int(neg) + len(sig) { return "", false, true }
	at := 0
	if neg { buf[0] = '-'; at = 1 }
	copy(buf[at:], sig)
	return string(buf[:at + len(sig)]), true, true
}

@(private = "file")
LIMB_BASE :: u64(1_000_000_000)

@(private = "file")
radix_push_digit :: #force_inline proc "contextless" (limbs: []u32, n: ^int, base, d: u64) -> bool #no_bounds_check {
	carry := d
	for k in 0 ..< n^ {
		v := u64(limbs[k]) * base + carry
		limbs[k], carry = u32(v % LIMB_BASE), v / LIMB_BASE
	}
	for carry > 0 {
		if n^ == len(limbs) { return false }
		limbs[n^] = u32(carry % LIMB_BASE)
		n^ += 1
		carry /= LIMB_BASE
	}
	return true
}

@(private = "file")
emit_limbs_dec :: proc "contextless" (limbs: []u32, state: rawptr, $emit: proc "contextless" (state: rawptr, b: u8) -> bool) -> bool #no_bounds_check {
	if len(limbs) == 0 { return emit(state, '0') }
	dec: [9]u8 = ---
	w := 0
	for v := limbs[len(limbs) - 1]; v > 0; v /= 10 { dec[w] = '0' + u8(v % 10); w += 1 }
	for k := w - 1; k >= 0; k -= 1 { if !emit(state, dec[k]) { return false } }
	for l := len(limbs) - 2; l >= 0; l -= 1 {
		v := limbs[l]
		for k := 8; k >= 0; k -= 1 { dec[k] = '0' + u8(v % 10); v /= 10 }
		for k in 0 ..< 9 { if !emit(state, dec[k]) { return false } }
	}
	return true
}

@(private)
radix_decimal_to :: proc "contextless" (digits: []u8, base: u64, buf: []u8) -> (string, bool) #no_bounds_check {
	limbs: [2600]u32 = ---
	n := 0
	for b in digits {
		if !radix_push_digit(limbs[:], &n, base, u64(spell.HEX_NIBBLE[b])) { return "", false }
	}
	o := Decoded{buf = buf}
	_ = emit_limbs_dec(limbs[:n], &o, decoded_emit)
	return string(buf[:o.n]), !o.over
}

@(private)
decode_binary_to :: proc "contextless" (src: []u8, t: tape.Node, buf: []u8, normalize: bool) -> (string, bool) #no_bounds_check {
	span := src[t.lo:][:t.n]
	b64 := Binary_Writer{buf = buf, normalize = normalize}
	if style_of(t.spelling) == .Plain && t.spelling & tape.SPELLING_DECODE == 0 {
		for b in span { if !binary_put(&b64, b) { return "", false } }
		return string(buf[:b64.n]), true
	}
	if !stream_scalar_bytes(span, t.spelling, &b64, binary_stream_cb) { return "", false }
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
binary_stream_cb :: proc "contextless" (state: rawptr, b: u8) -> bool { return binary_put((^Binary_Writer)(state), b) }

@(private = "file")
binary_put :: proc "contextless" (w: ^Binary_Writer, b: u8) -> bool #no_bounds_check {
	if b == ' ' || b == '\t' || b == '\n' || b == '\r' { return true }
	if w.normalize {
		if w.n >= len(w.buf) { return false }
		w.buf[w.n] = b; w.n += 1
		return true
	}
	w.quad[w.qlen] = b
	w.qlen += 1
	if w.qlen < 4 { return true }
	v0, v1 := b64_val(w.quad[0]), b64_val(w.quad[1])
	if w.n >= len(w.buf) { return false }
	w.buf[w.n] = (v0 << 2) | (v1 >> 4); w.n += 1
	if w.quad[2] != '=' {
		v2 := b64_val(w.quad[2])
		if w.n >= len(w.buf) { return false }
		w.buf[w.n] = ((v1 & 0xF) << 4) | (v2 >> 2); w.n += 1
		if w.quad[3] != '=' {
			if w.n >= len(w.buf) { return false }
			w.buf[w.n] = ((v2 & 0x3) << 6) | b64_val(w.quad[3]); w.n += 1
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

@(private = "file")
stream_scalar_bytes :: proc "contextless" (span: []u8, spelling: u16, state: rawptr, $emit: proc "contextless" (state: rawptr, b: u8) -> bool) -> bool #no_bounds_check {
	st := style_of(spelling)
	return stream_block_bytes(span, spelling, state, emit) if st == .Block else stream_flow_bytes(span, st, state, emit)
}

@(private = "file")
write_u64_dec :: #force_inline proc "contextless" (buf: []u8, v_in: u64) -> string #no_bounds_check {
	if v_in == 0 { buf[0] = '0'; return string(buf[:1]) }
	rev: [24]u8 = ---
	n := 0
	for v := v_in; v > 0; v /= 10 { rev[n] = '0' + u8(v % 10); n += 1 }
	for i in 0 ..< n { buf[i] = rev[n - 1 - i] }
	return string(buf[:n])
}

@(private = "file")
write_i64_dec :: #force_inline proc "contextless" (buf: []u8, v_in: i64) -> string #no_bounds_check {
	if v_in >= 0 { return write_u64_dec(buf, u64(v_in)) }
	buf[0] = '-'
	return string(buf[:1 + len(write_u64_dec(buf[1:], u64(0) - u64(v_in)))])
}

@(private = "file")
flush_ws :: #force_inline proc "contextless" (s: []u8, ws_lo, ws_hi: ^int, state: rawptr, $emit: proc "contextless" (state: rawptr, b: u8) -> bool) -> bool #no_bounds_check {
	for k in ws_lo^ ..< ws_hi^ { if !emit(state, s[k]) { return false } }
	ws_lo^, ws_hi^ = 0, 0
	return true
}

@(private = "file")
emit_rune :: proc "contextless" (cp: u32, state: rawptr, $emit: proc "contextless" (state: rawptr, b: u8) -> bool) -> bool {
	r, n := utf8.encode_rune(rune(cp))
	for k in 0 ..< n { if !emit(state, r[k]) { return false } }
	return true
}

@(private = "file")
emit_repeat :: #force_inline proc "contextless" (n: int, b: u8, state: rawptr, $emit: proc "contextless" (state: rawptr, b: u8) -> bool) -> bool {
	for _ in 0 ..< n { if !emit(state, b) { return false } }
	return true
}

@(private = "file")
stream_flow_bytes :: proc "contextless" (s: []u8, style: Style, state: rawptr, $emit: proc "contextless" (state: rawptr, b: u8) -> bool) -> bool #no_bounds_check {
	ws_lo, ws_hi, i := 0, 0, 0
	for i < len(s) {
		c := s[i]
		switch {
		case c == '\n' || c == '\r':
			ws_lo, ws_hi = 0, 0
			empties: int
			i, empties = skip_empty_lines(s, skip_break(s, i))
			if empties == 0 {
				if !emit(state, ' ') { return false }
			} else if !emit_repeat(empties, '\n', state, emit) {
				return false
			}
		case style == .Double && c == '\\':
			if !flush_ws(s, &ws_lo, &ws_hi, state, emit) { return false }
			i += 1
			if i >= len(s) { return true }
			e := s[i]
			if e == '\n' || e == '\r' {
				empties: int
				i, empties = skip_empty_lines(s, skip_break(s, i))
				if !emit_repeat(empties, '\n', state, emit) { return false }
				continue
			}
			i += 1
			switch e {
			case '0':      if !emit(state, 0) { return false }
			case 'a':      if !emit(state, 7) { return false }
			case 'b':      if !emit(state, 8) { return false }
			case 't', '\t': if !emit(state, '\t') { return false }
			case 'n':      if !emit(state, '\n') { return false }
			case 'v':      if !emit(state, 11) { return false }
			case 'f':      if !emit(state, 12) { return false }
			case 'r':      if !emit(state, '\r') { return false }
			case 'e':      if !emit(state, 27) { return false }
			case ' ', '"', '/', '\\': if !emit(state, e) { return false }
			case 'N':      if !emit_rune(0x85, state, emit) { return false }
			case '_':      if !emit_rune(0xa0, state, emit) { return false }
			case 'L':      if !emit_rune(0x2028, state, emit) { return false }
			case 'P':      if !emit_rune(0x2029, state, emit) { return false }
			case 'x', 'u', 'U':
				digits := 2 if e == 'x' else 4 if e == 'u' else 8
				cp, _ := yaml_hex_run(s, i, digits)
				i += digits
				if !emit_rune(cp, state, emit) { return false }
			}
		case style == .Single && c == '\'':
			if !flush_ws(s, &ws_lo, &ws_hi, state, emit) || !emit(state, '\'') { return false }
			i += 2
		case c == ' ' || c == '\t':
			if ws_hi == ws_lo { ws_lo = i }
			ws_hi = i + 1
			i += 1
		case:
			if !flush_ws(s, &ws_lo, &ws_hi, state, emit) || !emit(state, c) { return false }
			i += 1
		}
	}
	return flush_ws(s, &ws_lo, &ws_hi, state, emit)
}

@(private = "file")
stream_block_bytes :: proc "contextless" (s: []u8, spelling: u16, state: rawptr, $emit: proc "contextless" (state: rawptr, b: u8) -> bool) -> bool #no_bounds_check {
	if len(s) == 0 { return true }
	folded := s[0] == '>'
	keep, strip := false, false
	i := 1
	for i < len(s) && s[i] != '\n' && s[i] != '\r' && s[i] != ' ' && s[i] != '\t' {
		keep ||= s[i] == '+'
		strip ||= s[i] == '-'
		i += 1
	}
	for i < len(s) && s[i] != '\n' && s[i] != '\r' { i += 1 }
	if i >= len(s) { return true }
	i = skip_break(s, i)
	ci := block_explicit_indent(spelling)
	if ci < 0 {
		ci = max(int)
		for j := i; j < len(s); {
			m := j
			for m < len(s) && s[m] == ' ' { m += 1 }
			if m < len(s) && s[m] != '\n' && s[m] != '\r' { ci = m - j; break }
			for m < len(s) && s[m] != '\n' && s[m] != '\r' { m += 1 }
			j = skip_break(s, m) if m < len(s) else m
		}
	}
	last := -1
	for pass in 0 ..< 2 {
		first, prev_spaced := true, false
		empties := 0
		for j := i; j < len(s); {
			m := j
			for m < len(s) && s[m] == ' ' { m += 1 }
			e := m
			for e < len(s) && s[e] != '\n' && s[e] != '\r' { e += 1 }
			empty := m == e && m - j <= ci
			if pass == 0 {
				if !empty { last = j }
			} else if empty {
				if last >= 0 && j < last { empties += 1 } else if keep { if !emit(state, '\n') { return false } }
			} else {
				lo := min(j + ci, e)
				spaced := lo < e && (s[lo] == ' ' || s[lo] == '\t')
				if first {
					if !emit_repeat(empties, '\n', state, emit) { return false }
				} else if !folded || prev_spaced || spaced {
					if !emit_repeat(empties + 1, '\n', state, emit) { return false }
				} else if empties == 0 {
					if !emit(state, ' ') { return false }
				} else {
					if !emit_repeat(empties, '\n', state, emit) { return false }
				}
				for b in s[lo:e] { if !emit(state, b) { return false } }
				first, prev_spaced, empties = false, spaced, 0
				if j == last && !strip { if !emit(state, '\n') { return false } }
			}
			j = skip_break(s, e) if e < len(s) else e
		}
	}
	return true
}

@(private)
key_hash :: proc "contextless" (src: []u8, t: tape.Token) -> u32 #no_bounds_check {
	if !tape.text_decodes(t) { return tape.text_hash(src[t.lo:][:t.n]) }
	if t.kind != .Bytes && (t.kind != .String || t.n <= 256) && (t.kind != .Plain || t.n <= 256) && (t.kind != .Number || t.n <= 400) {
		stack: [512]u8 = ---
		if s, ok := text_decoded(src, t, stack[:], nil); ok { return tape.text_hash(transmute([]u8)s) }
	}
	x := tape.text_hasher()
	emit_slice(src, t, &x, proc "contextless" (state: rawptr, b: u8) -> bool {
		tape.text_hash_byte((^tape.Text_Hasher)(state), b)
		return true
	})
	return tape.text_hasher_end(&x)
}

@(private)
same_text :: proc "contextless" (src: []u8, t: tape.Token, other: []u8, o: tape.Token) -> bool #no_bounds_check {
	dt, do_b := tape.text_decodes(t), tape.text_decodes(o)
	if !dt && !do_b { return t.n == o.n && string(src[t.lo:][:t.n]) == string(other[o.lo:][:o.n]) }
	stack_a, stack_b: [512]u8 = ---, ---
	sa, ok_a := string(src[t.lo:][:t.n]), true
	if dt { sa, ok_a = text_decoded(src, t, stack_a[:], nil) }
	sb, ok_b := string(other[o.lo:][:o.n]), true
	if do_b { sb, ok_b = text_decoded(other, o, stack_b[:], nil) }
	if ok_a && ok_b { return sa == sb }
	wide_a, wide_b: [4096]u8 = ---, ---
	if !ok_a { sa, ok_a = text_decoded(src, t, wide_a[:], nil) }
	if !ok_b && ok_a && do_b { sb, ok_b = text_decoded(other, o, wide_b[:], nil) }
	if ok_a && ok_b { return sa == sb }
	return same_streamed_long(src, t, other, o)
}

@(private = "file")
same_streamed_long :: proc "contextless" (src: []u8, t: tape.Token, other: []u8, o: tape.Token) -> bool #no_bounds_check {
	W :: 4096
	win: [W]u8 = ---
	Fill :: struct { win: ^[W]u8, skip, seen: u64, filled: int }
	Cmp :: struct { target: []u8, skip, seen: u64, match: bool }
	for offset := u64(0); ; offset += W {
		fs := Fill{win = &win, skip = offset}
		emit_slice(src, t, &fs, proc "contextless" (st: rawptr, b: u8) -> bool {
			f := (^Fill)(st)
			if f.seen >= f.skip {
				if f.filled == W { f.seen += 1; return false }
				f.win[f.filled] = b; f.filled += 1
			}
			f.seen += 1
			return true
		})
		cs := Cmp{target = win[:fs.filled], skip = offset, match = true}
		emit_slice(other, o, &cs, proc "contextless" (st: rawptr, b: u8) -> bool {
			c := (^Cmp)(st)
			if c.seen >= c.skip {
				pos := int(c.seen - c.skip)
				if pos == W { c.seen += 1; return false }
				if pos >= len(c.target) || c.target[pos] != b { c.match = false; return false }
			}
			c.seen += 1
			return true
		})
		if !cs.match { return false }
		more_a, more_b := fs.seen > offset + W, cs.seen > offset + W
		if more_a != more_b { return false }
		if !more_a { return cs.seen == offset + u64(fs.filled) }
	}
}

@(private = "file")
emit_slice :: proc "contextless" (src: []u8, t: tape.Token, state: rawptr, $emit: proc "contextless" (state: rawptr, b: u8) -> bool) #no_bounds_check {
	if !tape.text_decodes(t) {
		for b in src[t.lo:][:t.n] { if !emit(state, b) { return } }
		return
	}
	switch t.kind {
	case .Bytes:
		Wrap :: struct { inner: rawptr, emit: proc "contextless" (state: rawptr, b: u8) -> bool }
		w := Wrap{inner = state, emit = emit}
		_ = stream_scalar_bytes(src[t.lo:][:t.n], t.spelling, &w, proc "contextless" (st: rawptr, b: u8) -> bool {
			if b == ' ' || b == '\t' || b == '\n' || b == '\r' { return true }
			wr := (^Wrap)(st)
			return wr.emit(wr.inner, b)
		})
	case .String, .Plain:
		_ = stream_scalar_bytes(src[t.lo:][:t.n], t.spelling, state, emit)
	case .Number:
		stream_canonical_number(src, t, state, emit)
	case .Null, .False, .True, .Array, .Object, .End:
		tmp: [16]u8 = ---
		if s, ok := text_decoded(src, t, tmp[:], nil); ok {
			for b in transmute([]u8)s { if !emit(state, b) { return } }
		}
	}
}

@(private = "file")
stream_canonical_number :: proc "contextless" (src: []u8, t: tape.Node, state: rawptr, $emit: proc "contextless" (state: rawptr, b: u8) -> bool) #no_bounds_check {
	tmp: [4096]u8 = ---
	if s, ok := canonical_number_to(src, t, tmp[:]); ok {
		for b in transmute([]u8)s { if !emit(state, b) { return } }
		return
	}
	stream_num :: #force_inline proc "contextless" (src: []u8, t: tape.Node, st: rawptr, $cb: proc "contextless" (st: rawptr, b: u8) -> bool) -> bool {
		if scalar_needs_decode(t) { return stream_number_scalar_bytes(src[t.lo:][:t.n], t.spelling, st, cb) }
		for b in src[t.lo:][:t.n] { if !cb(st, b) { return false } }
		return true
	}

	nk := Number_Spelling(t.spelling & tape.NUMBER_KIND)
	Probe :: struct { n: int, head: [2]u8, pure, neg, non_z: bool }
	pr := Probe{pure = true}
	_ = stream_num(src, t, &pr, proc "contextless" (st: rawptr, b: u8) -> bool {
		p := (^Probe)(st)
		idx := p.n; p.n += 1
		if idx < 2 { p.head[idx] = b }
		if idx == 0 && (b == '+' || b == '-') { p.neg = b == '-'; return true }
		if b < '0' || b > '9' { p.pure = false; return true }
		if b != '0' { p.non_z = true }
		return true
	})

	if !number_is_forced_float(nk) && pr.n > 2 && pr.head[0] == '0' && (pr.head[1] == 'x' || pr.head[1] == 'o') {
		Base_State :: struct { limbs: [2048]u32, n, skip: int, base: u64, overflow: bool }
		bs := Base_State{base = 16 if pr.head[1] == 'x' else 8}
		_ = stream_num(src, t, &bs, proc "contextless" (st: rawptr, b: u8) -> bool {
			s := (^Base_State)(st)
			if s.skip < 2 { s.skip += 1; return true }
			if !radix_push_digit(s.limbs[:], &s.n, s.base, u64(spell.HEX_NIBBLE[b])) { s.overflow = true; return false }
			return true
		})
		if !bs.overflow { _ = emit_limbs_dec(bs.limbs[:bs.n], state, emit); return }
		Raw_Radix :: struct { inner: rawptr, skip: int, started: bool, emit_cb: proc "contextless" (state: rawptr, b: u8) -> bool }
		rr := Raw_Radix{inner = state, emit_cb = emit}
		if !emit(state, '0') || !emit(state, pr.head[1]) { return }
		_ = stream_num(src, t, &rr, proc "contextless" (st: rawptr, b: u8) -> bool {
			r := (^Raw_Radix)(st)
			if r.skip < 2 { r.skip += 1; return true }
			c := b | 0x20 if b >= 'A' && b <= 'F' else b
			if !r.started { if c == '0' { return true }; r.started = true }
			return r.emit_cb(r.inner, c)
		})
		if !rr.started { _ = emit(state, '0') }
		return
	}

	if pr.pure && !number_is_forced_float(nk) {
		if !pr.non_z { _ = emit(state, '0'); return }
		if pr.neg && !emit(state, '-') { return }
		Int_Emit :: struct { inner: rawptr, started, skip_s: bool, emit_cb: proc "contextless" (state: rawptr, b: u8) -> bool }
		ie := Int_Emit{inner = state, skip_s = pr.n > 0 && (pr.head[0] == '+' || pr.head[0] == '-'), emit_cb = emit}
		_ = stream_num(src, t, &ie, proc "contextless" (st: rawptr, b: u8) -> bool {
			s := (^Int_Emit)(st)
			if s.skip_s { s.skip_s = false; return true }
			if !s.started { if b == '0' { return true }; s.started = true }
			return s.emit_cb(s.inner, b)
		})
		return
	}
	_ = stream_num(src, t, state, emit)
}

@(private = "file")
stream_number_scalar_bytes :: proc "contextless" (span: []u8, spelling: u16, state: rawptr, $emit: proc "contextless" (state: rawptr, b: u8) -> bool) -> bool {
	if number_is_block(Number_Spelling(spelling & tape.NUMBER_KIND)) { return stream_block_bytes(span, spelling, state, emit) }
	return stream_flow_bytes(span, .Single if style_of(spelling) == .Single else .Double, state, emit)
}
