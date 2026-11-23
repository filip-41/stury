package dsv

import "base:intrinsics"
import "stury:lib/base/spell"
import "stury:lib/core/tape"

// The readers of a cell's text. A cell that needs no decode is its span. One with `SPELLING_DECODE` reads, a byte at a
// time, as its spec spells it: a quoted CSV cell's `""` as `"`, a TSV escape as the byte it names, a byte past 0x7F as
// one UTF-8 character or, under `SPELLING_LAX`, U+FFFD for each maximal subpart of an ill-formed sequence, and a key of
// a column past the header as its 1-based position.

// The value of the number cell `t` of `src`, which the walk read as an RFC 8259 number.
@(private)
number_value :: proc "contextless" (src: []u8, t: tape.Node) -> spell.Number {
	num, _ := spell.number_strict(src, t.lo, t.lo + u64(t.n))
	return num
}

// The quote bytes around cell `t`: 1 on each side of a quoted CSV cell, 0 around any other.
@(private)
quotes :: proc "contextless" (src: []u8, t: tape.Token) -> (head, tail: u8) {
	q := u8(t.spelling & tape.SPELLING_QUOTED != 0)
	return q, q
}

// The size in bytes of a buffer that holds the decoded text of cell `t`: its span, since an escape decodes to no more
// bytes than it spells, three times the span for a `SPELLING_LAX` cell, since a tolerated byte reads as U+FFFD, and a
// column's position for a key named by its place.
@(private)
decode_room :: proc "contextless" (src: []u8, t: tape.Node) -> int {
	if t.spelling & tape.SPELLING_PLACED != 0 {
		return COLUMN_ROOM
	}
	return int(t.n) * (3 if t.spelling & tape.SPELLING_LAX != 0 else 1)
}

// Decodes the text of cell `t` of `src`, a text of spec `S`, into `buf`. False when `buf` is shorter than
// `decode_room` gives.
@(private)
decode_cell :: proc "contextless" (src: []u8, t: tape.Node, buf: []u8, $S: Spec) -> (s: string, ok: bool) #no_bounds_check {
	if decode_room(src, t) > len(buf) {
		return "", false
	}
	r := cell_reader(src, t, S)
	n := 0
	for {
		b, more := cell_byte(&r)
		if !more {
			return string(buf[:n]), true
		}
		buf[n] = b
		n += 1
	}
}

// Whether cell `t` of `src` and cell `o` of `other`, both of a text of spec `S`, read as the same text.
@(private)
same_cells :: proc "contextless" (src: []u8, t: tape.Token, other: []u8, o: tape.Token, $S: Spec) -> bool {
	a, b := cell_reader(src, t, S), cell_reader(other, o, S)
	for {
		x, more := cell_byte(&a)
		y, other_more := cell_byte(&b)
		if more != other_more || x != y {
			return false
		}
		if !more {
			return true
		}
	}
}

// `tape.text_hash` of the text cell `t` of `src` reads as.
@(private)
cell_hash :: proc "contextless" (src: []u8, t: tape.Token, $S: Spec) -> u32 {
	if t.spelling & tape.SPELLING_DECODE == 0 {
		return tape.text_hash(src[t.lo:][:t.n])
	}
	x := tape.text_hasher()
	r := cell_reader(src, t, S)
	for {
		b, more := cell_byte(&r)
		if !more {
			return tape.text_hasher_end(&x)
		}
		tape.text_hash_byte(&x, b)
	}
}

// The spelling of the number `src[lo:hi]` a find read with no spelling.
@(private)
respell :: proc "contextless" (src: []u8, lo, hi: u64) -> u16 {
	spelling, _ := number_shape(raw_data(src), lo, hi)
	return spelling
}

// The most digits of a column's position, a `u32`.
@(private)
COLUMN_ROOM :: 10

// The read position in the bytes a cell reads as, for `cell_byte`.
@(private)
Cell_Reader :: struct {
	base:   [^]u8,
	p, end: u64,
	decode: bool,
	lax:    bool,
	tsv:    bool,
	// A quoted CSV cell, in which a quote is the first of a `""`. In an unquoted cell a quote is a bare quote, a byte.
	csv:    bool,
	one:    [COLUMN_ROOM]u8, // the bytes of the character or column position last decoded
	at, n:  int,
}

@(private)
cell_reader :: #force_inline proc "contextless" (src: []u8, t: tape.Token, $S: Spec) -> (r: Cell_Reader) {
	r = {base = raw_data(src), p = t.lo, end = t.lo + u64(t.n), decode = t.spelling & tape.SPELLING_DECODE != 0, lax = t.spelling & tape.SPELLING_LAX != 0, tsv = S == .Tsv, csv = S == .Csv && t.spelling & tape.SPELLING_QUOTED != 0}
	if t.spelling & tape.SPELLING_PLACED != 0 {
		// The position's digits, read from the last.
		v := t.lo
		k := len(r.one)
		for {
			k -= 1
			r.one[k] = u8('0' + v % 10)
			v /= 10
			if v == 0 {
				break
			}
		}
		copy(r.one[:], r.one[k:])
		r.n, r.p, r.end = len(r.one) - k, 0, 0
	}
	return
}

// The next byte cell `r` reads as, false past its end.
@(private)
cell_byte :: proc "contextless" (r: ^Cell_Reader) -> (u8, bool) #no_bounds_check {
	for r.at == r.n {
		if r.p >= r.end {
			return 0, false
		}
		c := r.base[r.p]
		if !r.decode {
			r.p += 1
			return c, true
		}
		if r.tsv && c == '\\' {
			r.p += 2
			return TSV_ESCAPED[r.base[r.p - 1]], true
		}
		if r.csv && c == '"' {
			// The walk accepted the quoted cell, so a quote inside its span is the first of a `""`.
			r.p += 2
			return '"', true
		}
		if c < 0x80 || !r.lax {
			r.p += 1
			return c, true
		}
		r.at = 0
		q, kind := spell.utf8_char(r.base[r.p:], r.base[r.end:])
		if kind != .None {
			r.one[0], r.one[1], r.one[2] = 0xEF, 0xBF, 0xBD
			r.n, r.p = 3, u64(intrinsics.ptr_sub(spell.utf8_subpart(r.base[r.p:], r.base[r.end:]), r.base))
		} else {
			r.n = intrinsics.ptr_sub(q, r.base[r.p:])
			for i in 0 ..< r.n {
				r.one[i] = r.base[r.p + u64(i)]
			}
			r.p += u64(r.n)
		}
	}
	r.at += 1
	return r.one[r.at - 1], true
}

// The byte each TSV escape letter reads as, 0 for a byte no escape names: `\t`, `\n`, `\r`, `\0` and `\\`.
@(private, rodata)
TSV_ESCAPED := [256]u8 {
	't'  = '\t',
	'n'  = '\n',
	'r'  = '\r',
	'0'  = 0,
	'\\' = '\\',
}
