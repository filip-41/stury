package csv

import "base:intrinsics"
import "core:simd"
import "core:unicode/utf8"
import "../core/bits"

// What a scan mode removes from, or adds to, the RFC 4180 scan. Each mode compiles to its own `scan_block`,
// chosen once per call, so the default mode (`{}`) does none of the others' work.
@(private)
Scan_Flag :: enum u8 {
	Unquoted,  // a quote is text (`Quoting.None`)
	Escapes,   // a backslash opens an escape (`Escapes.Backslash`), only with `.Unquoted`
	Comments,  // a line opening with the comment byte is no record
	Skip_Utf8, // UTF-8 is not judged
}

@(private)
Scan_Mode :: bit_set[Scan_Flag; u8]

// A dialect and limits as the scanner reads them.
@(private)
Scan :: struct {
	mode:       Scan_Mode,
	delim:      byte,
	comment:    byte, // `.Comments` only
	ragged:     bool,
	max_fields: int,  // max(int) for no cap
	max_bytes:  int,  // a line's cap (`Limits.max_record_bytes`), 0 for none
}

// The scan of `d` under `limits`, or false when either is refused (`.Bad_Option`). UTF-8 is judged under
// `.Strict` only.
@(private)
scan_setup :: proc(d: Dialect, limits: Limits, strictness := Strictness.Strict) -> (s: Scan, ok: bool) {
	s = {delim = d.delimiter if d.delimiter != 0 else ',', comment = d.comment, ragged = d.ragged, max_fields = limits.max_fields, max_bytes = limits.max_record_bytes}
	if strictness != .Strict {
		s.mode += {.Skip_Utf8}
	}
	if limits.max_fields < 0 || limits.max_record_bytes < 0 || !delimiter_ok(s.delim) {
		return
	}
	if limits.max_fields == 0 {
		s.max_fields = max(int)
	}
	if d.quoting == .None {
		s.mode += {.Unquoted}
	}
	if d.escapes == .Backslash {
		if d.quoting == .Quotes || s.delim == '\\' || s.delim == 't' || s.delim == 'n' || s.delim == 'r' || s.delim == '0' || d.comment == '\\' {
			return
		}
		s.mode += {.Escapes}
	}
	if c := d.comment; c != 0 {
		if c == '\r' || c == '\n' || c == s.delim || c >= 0x80 || c == '"' && d.quoting == .Quotes {
			return
		}
		s.mode += {.Comments}
	}
	return s, true
}

// What one 64-byte block leaves the next.
@(private)
Carry :: struct {
	prev:     bits.V, // the block's last 16 bytes, which a UTF-8 window crossing the edge reads
	in_quote: u64,    // all ones when the block ended inside quotes
	start:    u64,    // 1 when it ended in a separator outside quotes: the next byte starts a field
	close:    u64,    // 1 when it ended in a closing quote, which only a quote, separator or CR may follow
	cr:       u64,    // 1 when it ended in a CR outside quotes, which only an LF may follow
	line:     u64,    // `.Comments`: 1 when it ended in an LF outside quotes, so the next byte starts a line
	comment:  u64,    // `.Comments`: 1 when it ended inside a comment line
	esc:      u64,    // `.Escapes`: 1 when it ended in a backslash that opens an escape
	// The first UTF-8 fault the scan passed without reporting, or max(int) for none. -1 reports each UTF-8
	// fault as the block's fault, as under `.Strict`. `unmarshal` under `.Lazy` starts it at max(int) and
	// judges UTF-8 per cell.
	utf8:     int,
}

// The carry of an input's first block: its first byte starts a field and a line, and UTF-8 faults are faults.
@(private)
CARRY_START :: Carry{start = 1, line = 1, utf8 = -1}

// Scans the block at `pos`. `seps` are its separators outside quotes, `lfs` the subset that end records, and
// `fault` its first fault, or -1. Bytes past `src` read as zeros. The fault may be before `pos`, at a CR,
// backslash or UTF-8 lead the previous block left open. Separators at or past the fault are not valid.
//
// A quote opens a quoted field only at a field's first byte. A quote right after a closing quote makes the
// pair one quote of the field's text. A closing quote must be followed by a quote, the delimiter, LF, CR or
// the input's end. A CR outside quotes must be followed by LF. Every byte must be RFC 3629 UTF-8.
@(private)
scan_block :: #force_inline proc(src: []byte, pos: int, delim, comment: byte, cy: ^Carry, $M: Scan_Mode) -> (seps, lfs: u64, fault: int, kind: Error_Kind) {
	// Inlines `bits.block_at`: calling the helper compiles this loop to different code.
	tail: [64]u8 = ---
	p := raw_data(src[pos:])
	valid := ~u64(0)
	if rem := len(src) - pos; rem < 64 {
		tail = {}
		copy(tail[:], src[pos:])
		p = raw_data(tail[:])
		valid = u64(1) << u64(rem) - 1
	}
	v := [4]bits.V{bits.load(p), bits.load(p[16:]), bits.load(p[32:]), bits.load(p[48:])}
	when .Comments in M {
		if cy.comment != 0 || bits.any_eq4(v, comment) {
			seps, lfs, fault, kind = scan_bytes(src, pos, delim, comment, cy, M)
		} else {
			seps, lfs, fault, kind = scan_masks(src, pos, v, valid, delim, cy, M)
			cy.line = lfs >> 63
		}
	} else {
		seps, lfs, fault, kind = scan_masks(src, pos, v, valid, delim, cy, M)
	}
	// The check includes the previous block's last 16 bytes, so a sequence cut by the block edge is refused
	// even when this block is all ASCII.
	when .Skip_Utf8 not_in M {
		if bits.any_high(cy.prev | v[0] | v[1] | v[2] | v[3]) && bits.any_lane(bits.utf8_block(cy.prev, v)) {
			if at, k := utf8_block_fault(src, pos, cy); at >= 0 && (fault < 0 || at < fault) {
				fault, kind = at, k
			}
		}
		cy.prev = v[3]
	}
	return
}

// `scan_block`'s structure by lane masks, in a block with no comment line.
@(private)
scan_masks :: #force_inline proc(src: []byte, pos: int, v: [4]bits.V, valid: u64, delim: byte, cy: ^Carry, $M: Scan_Mode) -> (seps, lfs: u64, fault: int, kind: Error_Kind) {
	when .Unquoted in M {
		d, n := bits.pack4x2(bits.eq4(v, delim), bits.eq4(v, '\n'))
		when .Escapes in M {
			r, bs := bits.pack4x2(bits.eq4(v, '\r'), bits.eq4(v, '\\'))
		} else {
			r := bits.pack4(simd.lanes_eq(v[0], '\r'), simd.lanes_eq(v[1], '\r'), simd.lanes_eq(v[2], '\r'), simd.lanes_eq(v[3], '\r'))
		}
		seps = d | n
		lfs = n
		cr := r
		// A CR in bit 63 is checked against the next block's first byte.
		bad := cr & ~(n >> 1) & (1 << 63 - 1)
	} else {
		q, d := bits.pack4x2(bits.eq4(v, '"'), bits.eq4(v, delim))
		n, r := bits.pack4x2(bits.eq4(v, '\n'), bits.eq4(v, '\r'))

		instr := bits.prefix_xor(q) ~ cy.in_quote
		open := q & instr
		close := q & ~instr
		seps = (d | n) & ~instr
		lfs = n & ~instr
		cr := r & ~instr
		after_close := close << 1 | cy.close
		bad := open & ~(seps << 1 | cy.start | after_close)
		bad |= after_close & ~(q | d | n | r | ~valid)
		// A CR in bit 63 is checked against the next block's first byte.
		bad |= cr & ~(n >> 1) & (1 << 63 - 1)
	}

	fault = -1
	kind = .Bad_Char
	if cy.cr & ~n != 0 {
		fault = pos - 1
	} else if bad != 0 {
		fault = pos + int(intrinsics.count_trailing_zeros(bad))
	}
	when .Escapes in M {
		if bs | cy.esc != 0 {
			if at := escape_fault(src, pos, cy); at >= 0 && (fault < 0 || at < fault) {
				fault, kind = at, .Bad_Escape
			}
		}
	}

	when .Unquoted not_in M {
		cy.in_quote = u64(i64(instr) >> 63)
		cy.start = seps >> 63
		cy.close = close >> 63
	}
	cy.cr = cr >> 63
	return
}

// The first backslash in the block at `pos` that opens no escape, or -1. A backslash in bit 63 is checked by
// the next block (`cy.esc`).
@(cold, private)
escape_fault :: proc(src: []byte, pos: int, cy: ^Carry) -> int {
	end := min(pos + 64, len(src))
	i := pos
	if cy.esc != 0 {
		if !escaped(src[pos]) {
			return pos - 1
		}
		i += 1
	}
	cy.esc = 0
	for ; i < end; i += 1 {
		if src[i] != '\\' {
			continue
		}
		if i + 1 == pos + 64 {
			cy.esc = 1
			break
		}
		if i + 1 == len(src) || !escaped(src[i + 1]) {
			return i
		}
		i += 1
	}
	return -1
}

// The bytes a backslash escapes: `\t`, `\n`, `\r`, `\0`, `\\`.
@(private)
escaped :: #force_inline proc(c: byte) -> bool {
	return c == 't' || c == 'n' || c == 'r' || c == '0' || c == '\\'
}

// `scan_block`'s structure one byte at a time, for a block that holds the comment byte or starts inside a
// comment line. It returns what `scan_masks` would, except that a comment line holds no separator but its LF.
@(cold, private)
scan_bytes :: proc(src: []byte, pos: int, delim, comment: byte, cy: ^Carry, $M: Scan_Mode) -> (seps, lfs: u64, fault: int, kind: Error_Kind) {
	fault, kind = -1, .Bad_Char
	quoted, start, close, cr := cy.in_quote != 0, cy.start != 0, cy.close != 0, cy.cr != 0
	line, in_comment, esc := cy.line != 0, cy.comment != 0, cy.esc != 0
	for i in pos ..< min(pos + 64, len(src)) {
		c := src[i]
		bit := u64(1) << u64(i - pos)
		if cr {
			cr = false
			if c != '\n' {
				return seps, lfs, i - 1, .Bad_Char
			}
		}
		when .Escapes in M {
			if esc {
				esc = false
				if !escaped(c) {
					return seps, lfs, i - 1, .Bad_Escape
				}
				start, line = false, false
				continue
			}
		}
		if in_comment {
			if c == '\n' {
				seps |= bit
				lfs |= bit
				in_comment, start, line = false, true, true
			}
			continue
		}
		when .Unquoted not_in M {
			if quoted {
				if c == '"' {
					quoted, close = false, true
				}
				continue
			}
			if close {
				close = false
				if c == '"' {
					quoted = true
					continue
				}
				if c != delim && c != '\n' && c != '\r' {
					return seps, lfs, i, .Bad_Char
				}
			}
		}
		at_start, at_line := start, line
		start, line = false, false
		switch {
		case c == delim:
			seps |= bit
			start = true
		case c == '\n':
			seps |= bit
			lfs |= bit
			start, line = true, true
		case c == '\r':
			cr = true
		case at_line && c == comment:
			in_comment = true
		case c == '"' && .Unquoted not_in M:
			if !at_start {
				return seps, lfs, i, .Bad_Char
			}
			quoted = true
		case c == '\\' && .Escapes in M:
			esc = true
		}
	}
	cy.in_quote = ~u64(0) if quoted else 0
	cy.start, cy.close, cy.cr = u64(start), u64(close), u64(cr)
	cy.line, cy.comment, cy.esc = u64(line), u64(in_comment), u64(esc)
	return
}

// The faults only the input's end shows: a CR, escape or UTF-8 sequence the last block left open, or a quoted
// field that never closed. -1 for none.
@(private)
scan_end :: proc(src: []byte, cy: ^Carry) -> (fault: int, kind: Error_Kind) {
	n := len(src)
	if cy.cr != 0 {
		return n - 1, .Bad_Char
	}
	if cy.esc != 0 {
		return n - 1, .Bad_Escape
	}
	if bits.any_high(cy.prev) && bits.any_lane(bits.utf8_block(cy.prev, {})) {
		if at, k := utf8_block_fault(src, n, cy); at >= 0 {
			return at, k
		}
	}
	if cy.in_quote != 0 {
		return n, .Truncated
	}
	return -1, .None
}

// The UTF-8 fault the block at `pos` reports: `utf8_fault`'s, or -1 when the scan defers it to the reader
// (`cy.utf8`).
@(cold, private)
utf8_block_fault :: proc(src: []byte, pos: int, cy: ^Carry) -> (fault: int, kind: Error_Kind) {
	fault, kind = utf8_fault(src, pos, pos + 64)
	if fault >= 0 && cy.utf8 >= 0 {
		cy.utf8 = min(cy.utf8, fault)
		return -1, .None
	}
	return
}

// The first malformed UTF-8 sequence that starts before `end`, searching from the start of the sequence that
// holds `pos`. `Bad_Char` at its lead, or `Truncated` at `len(src)` when the input ends inside a sequence that
// is valid so far. -1 for none.
@(cold, private)
utf8_fault :: proc(src: []byte, pos, end: int) -> (fault: int, kind: Error_Kind) {
	i := pos
	for i > max(pos - 3, 0) && src[i - 1] & 0xC0 == 0x80 {
		i -= 1
	}
	if i > 0 && src[i - 1] >= 0xC0 {
		i -= 1
	}
	for i < min(end, len(src)) {
		if src[i] < 0x80 {
			i += 1
			continue
		}
		r, size := utf8.decode_rune(src[i:])
		if r == utf8.RUNE_ERROR && size == 1 {
			if !utf8.full_rune(src[i:]) {
				return len(src), .Truncated
			}
			return i, .Bad_Char
		}
		i += size
	}
	return -1, .None
}

// The bytes a delimiter may be: not a quote, CR or LF, and ASCII.
@(private)
delimiter_ok :: proc(delim: byte) -> bool {
	return delim != 0 && delim != '"' && delim != '\r' && delim != '\n' && delim < 0x80
}

// The next block that must check the line cap, for a scan at block `pos` inside the line starting at
// `rec_lo`: the block on `pos`'s 64-byte grid that holds the line's first byte past `cap`. `n`, the input's
// end, when there is no cap or the input ends first. If the line ends sooner, that block checks the next
// line instead.
@(private)
line_cap_stop :: proc(pos, rec_lo, cap, n: int) -> int {
	if cap == 0 || cap >= n - rec_lo {
		return n
	}
	return pos + (rec_lo + cap - pos) / 64 * 64
}

// In the block at `pos` with record ends `lfs`: the first byte past `cap` of a line longer than `cap`, and
// that line's first byte, or (-1, -1) for none. The line open at the block's start began at `rec_lo`, and
// its first byte past the cap is not before the block.
@(private)
line_cap_fault :: proc(lfs: u64, pos, rec_lo, cap, n: int) -> (at, line_lo: int) {
	if cap == 0 {
		return -1, -1
	}
	lo, ends := rec_lo, lfs
	for cap < n - lo {
		past := lo + cap
		if past >= pos + 64 {
			break
		}
		if ends == 0 || pos + int(intrinsics.count_trailing_zeros(ends)) > past {
			return past, lo
		}
		lo = pos + int(intrinsics.count_trailing_zeros(ends)) + 1
		ends &= ends - 1
	}
	return -1, -1
}

// A line with no byte but a CR before its LF holds no record.
@(private)
blank :: #force_inline proc(src: []byte, lo, hi: int) -> bool {
	return hi == lo || hi == lo + 1 && src[lo] == '\r'
}
