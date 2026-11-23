package dsv

import "base:intrinsics"
import "stury:lib/base/kernel"
import "stury:lib/base/spell"
import "stury:lib/core/tape"

// The byte-at-a-time scans of the walk: the header's cell count, the first malformed UTF-8 sequence in a block or a
// span, the first backslash that opens no escape, and whether a cell is too long for `Token.n`. The walk calls each
// only on a block whose masks say it is needed.

// The first byte of `src` at or after `lo` past one byte order mark at the text's first byte. A mark at a later byte is
// a cell byte.
@(private)
text_start :: #force_inline proc "contextless" (src: []u8, lo: u64) -> u64 {
	if lo == 0 && len(src) >= 3 && src[0] == 0xEF && src[1] == 0xBB && src[2] == 0xBF {
		return 3
	}
	return min(lo, u64(len(src)))
}

// The first byte of the first record at or after `start`. Skips empty lines, lines holding only a CR LF, and lines
// whose first byte is `comment` when `comment` is not 0. A lone CR is not skipped. Returns `len(src)` when no record
// starts at or after `start`.
@(private)
record_start :: #force_inline proc "contextless" (src: []u8, start: int, comment: u8) -> int {
	i := start
	for i < len(src) {
		if src[i] == '\n' {
			i += 1
			continue
		}
		if src[i] == '\r' && i + 1 < len(src) && src[i + 1] == '\n' {
			i += 2
			continue
		}
		if comment != 0 && src[i] == comment {
			for i < len(src) && src[i] != '\n' {
				i += 1
			}
			if i < len(src) {
				i += 1
			}
			continue
		}
		break
	}
	return i
}

// The cell count of the text's first record at or after `start`, 0 for a text with none. A key buffer sized from it
// holds every cell the header makes, since the pass reads the same record the same way when it does not fault.
@(private, cold, require_results)
header_cells :: #force_no_inline proc "contextless" (src: []u8, start: int, $S: Spec, delim, comment: u8) -> int {
	at := record_start(src, start, comment)
	if at >= len(src) {
		return 0
	}
	return scan_record(src, at, 0, S, delim).cells
}

// A record read from its first byte by `scan_record`. `cells` is its cell count, at least 1. `fault_at` is the index
// of the first delimiter that opens a cell past `width`, -1 when there is none, and width 0 counts cells only.
// `line_end` is the index of its LF, or `len(src)` when the text ends first. `line_end_lo` is the index of the CR in a
// CR LF, else the same as `line_end`. `quote` is the index of the last quote that opened a quoted cell.
@(private)
Record_Scan :: struct {
	cells:       int,
	fault_at:    int,
	line_end:    int,
	line_end_lo: int,
	quote:       int,
}

// Reads one record from `start`, with `delim` between cells. Quotes (CSV) and escapes (TSV) are read as the pass reads
// them, so a delimiter inside a quoted cell does not count.
@(private, cold, require_results)
scan_record :: #force_no_inline proc "contextless" (src: []u8, start, width: int, $S: Spec, delim: u8) -> Record_Scan {
	s := Record_Scan{cells = 1, fault_at = -1}
	i := start
	end := len(src)
	quoted, first := false, true
	when S != .Csv {
		_, _ = quoted, first
	}
	for i < end {
		c := src[i]
		when S == .Csv {
			if quoted {
				if c == '"' {
					if i + 1 < end && src[i + 1] == '"' {
						i += 2
						continue
					}
					quoted = false
				}
				i += 1
				continue
			}
		}
		when S == .Tsv {
			if c == '\\' {
				i += 2
				continue
			}
		}
		switch c {
		case '\n':
			hi := i
			if i > start && src[i - 1] == '\r' {
				hi = i - 1
			}
			s.line_end, s.line_end_lo = i, hi
			return s
		case '\r':
			if i + 1 < end && src[i + 1] == '\n' {
				s.line_end, s.line_end_lo = i + 1, i
				return s
			}
		case delim:
			if s.cells == width && s.fault_at < 0 {
				s.fault_at = i
			}
			s.cells += 1
		}
		when S == .Csv {
			if c == '"' && first {
				quoted, s.quote = true, i
			}
			first = c == delim
		}
		i += 1
	}
	s.line_end, s.line_end_lo = end, end
	return s
}

// The index of the first backslash in the block at `pos` that opens no escape, or -1. `bs` has a bit at each backslash
// of the block, a comment line's bytes already cleared. `esc` is 1 when the block before ended in an odd run of
// backslashes, and it returns that state for the next block. The bytes a backslash may escape are `t`, `n`, `r`, `0`
// and `\\`, read as one class mask, so the byte loop runs only when a block holds a bad escape.
@(private, cold)
escape_fault :: #force_inline proc "contextless" ($T: kernel.Tier, b: kernel.Block, bs: u64, pos: int, esc: ^u64) -> int {
	bad := kernel.escaped(bs, esc) & ~kernel.pack(kernel.has(kernel.classes(T, b, ESCAPE_LETTERS), 0x0f))
	if bad == 0 {
		return -1
	}
	return pos + int(intrinsics.count_trailing_zeros(bad)) - 1
}

// The class bit of the bytes a TSV backslash may escape: `t`, `n`, `r`, `0` and `\\`.
@(private, rodata)
ESCAPE_LETTERS := kernel.Nibble_Table {
	lo = {4, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 8, 0, 2, 0},
	hi = {0, 0, 0, 4, 0, 8, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0},
}

// The first malformed UTF-8 sequence in the block at `pos`, starting from the lead byte of the sequence that holds
// `pos` but never before `floor`. Returns `Bad_Char` (`Invalid_Utf8`) at the sequence's lead byte, `Truncated`
// (`Cut_Utf8`) at `len(src)` when the text ends inside a sequence that is valid so far, or -1 when there is none.
@(private, cold)
utf8_fault :: #force_no_inline proc "contextless" (src: []u8, floor, pos: int) -> (fault: int, kind: tape.Fault_Kind, detail: Detail) {
	i := sequence_lead(raw_data(src), floor, pos)
	return span_fault(src, i, min(pos + 64, len(src)))
}

// The first malformed UTF-8 sequence led in `[lo, hi)` of `src`, read to the text's end, as `utf8_fault` returns it.
@(private, cold)
span_fault :: proc "contextless" (src: []u8, lo, hi: int) -> (fault: int, kind: tape.Fault_Kind, detail: Detail) {
	at, k := first_ill_formed(raw_data(src), lo, hi, len(src))
	if at < 0 {
		return -1, .Bad_Char, .None
	}
	if k == .Truncated {
		return len(src), .Truncated, .Cut_Utf8
	}
	return at, .Bad_Char, .Invalid_Utf8
}

// The first ill-formed UTF-8 sequence of the block at `pos` whose lead is in a comment line, as `utf8_fault` returns it.
// `ill` and `back` are the block's leads and the lead before it as `ill_leads` returns them, and `comments` marks the
// block's comment bytes and the LFs that end comment lines. Its bit 0 says whether `back` is in one, since only
// continuation bytes lie between `back` and `pos`, so the two share a line.
@(private, cold)
comment_utf8_fault :: #force_no_inline proc "contextless" (src: []u8, pos: int, ill: u64, back: int, comments: u64) -> (fault: int, kind: tape.Fault_Kind, detail: Detail) {
	at := -1
	if back >= 0 && comments & 1 != 0 {
		at = back
	} else if lead := ill & comments; lead != 0 {
		at = pos + int(intrinsics.count_trailing_zeros(lead))
	}
	if at < 0 {
		return -1, .Bad_Char, .None
	}
	return span_fault(src, at, at + 1)
}

// The leads of the ill-formed UTF-8 sequences that start in the block at `pos`, a bit each, each sequence read up to
// `end`. `back` is the first lead of one that starts in the three bytes before `pos` and runs into the block, not
// before `floor`, or -1. A lead is a byte that starts no well-formed character, so a sequence's every maximal subpart
// and its stray continuations each have one, and a span that holds an ill-formed sequence holds a lead.
@(private, cold)
ill_leads :: #force_no_inline proc "contextless" (base: [^]u8, floor, pos, end: int) -> (leads: u64, back: int) #no_bounds_check {
	back = -1
	i := sequence_lead(base, floor, pos)
	for i < min(pos + 64, end) {
		if base[i] < 0x80 {
			i += 1
			continue
		}
		q, k := spell.utf8_char(base[i:], base[end:])
		if k == .None {
			i = int(intrinsics.ptr_sub(q, base))
			continue
		}
		if i < pos {
			back = i if back < 0 else back
		} else {
			leads |= u64(1) << u64(i - pos)
		}
		i += 1
	}
	return
}

// Steps back from `pos` over at most three continuation bytes and the lead byte before them, never past `floor`.
@(private)
sequence_lead :: #force_inline proc "contextless" (base: [^]u8, floor, pos: int) -> int #no_bounds_check {
	i := pos
	for i > max(pos - 3, floor) && base[i - 1] & 0xc0 == 0x80 {
		i -= 1
	}
	if i > floor && base[i - 1] >= 0xc0 {
		i -= 1
	}
	return i
}

// The lead byte of the first ill-formed UTF-8 sequence that starts in `[lo, hi)`, each read up to `end`, and its fault
// kind, `Truncated` when `end` cuts a sequence that is valid so far. Returns -1 when there is none.
@(private)
first_ill_formed :: #force_inline proc "contextless" (base: [^]u8, lo, hi, end: int) -> (at: int, kind: tape.Fault_Kind) {
	i := lo
	for i < hi {
		if base[i] < 0x80 {
			i += 1
			continue
		}
		q, k := spell.utf8_char(base[i:], base[end:])
		if k != .None {
			return i, k
		}
		i = int(intrinsics.ptr_sub(q, base))
	}
	return -1, .None
}

// Whether the first separator in `seps` at or after `pos` ends the cell that starts at `lo` more than `max(u32)` bytes
// later. A CR LF's CR belongs to the line end, so `hi` leaves it out. Returns false when `seps` is 0.
@(private, cold)
cell_too_wide :: #force_no_inline proc "contextless" (base: [^]u8, lo, pos: int, seps: u64) -> bool {
	if seps == 0 {
		return false
	}
	sep := pos + int(intrinsics.count_trailing_zeros(seps))
	hi := sep
	if base[sep] == '\n' && sep > lo && base[sep - 1] == '\r' {
		hi -= 1
	}
	return hi - lo > int(max(u32))
}

// The spelling of the RFC 8259 number `base[lo:hi]`, as JSON's walk spells one, false for a span that is no number.
@(private)
number_shape :: proc "contextless" (base: [^]u8, lo, hi: u64) -> (spelling: u16, ok: bool) #no_bounds_check {
	p := lo
	if base[p] == '-' {
		p += 1
	}
	int_at := p
	if p >= hi {
		return
	}
	if base[p] == '0' {
		p += 1
	} else {
		for p < hi && base[p] - '0' < 10 {
			p += 1
		}
	}
	int_digits := p - int_at
	if int_digits == 0 {
		return
	}
	frac_digits: u64
	if p < hi && base[p] == '.' {
		p += 1
		frac_at := p
		for p < hi && base[p] - '0' < 10 {
			p += 1
		}
		if frac_digits = p - frac_at; frac_digits == 0 {
			return
		}
	}
	exp := false
	if p < hi && base[p] | 0x20 == 'e' {
		exp = true
		p += 1
		if p < hi && (base[p] == '+' || base[p] == '-') {
			p += 1
		}
		exp_at := p
		for p < hi && base[p] - '0' < 10 {
			p += 1
		}
		if p == exp_at {
			return
		}
	}
	if p != hi {
		return
	}
	return tape.number_spelling(0, int_digits, frac_digits) | (tape.NUMBER_EXP if exp else 0), true
}
