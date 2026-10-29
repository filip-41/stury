package dsv

// The cold scalars of the walk: what its masks cannot answer by bit. The number of a header's cells, which sizes the
// key buffer before the pass starts, the first bad UTF-8 sequence of a block, the first backslash that opens no
// escape, and the exact span of a cell too long to measure by block. Each reads bytes one at a time and runs only
// where the block masks have already said a block needs it.

import "base:intrinsics"
import "core:unicode/utf8"
import core "../core"

// The cells of the text's first record, read from `start`: a delimiter count over one record, its quotes (CSV) or
// escapes (TSV) followed as the pass follows them, so that no delimiter a quoted field holds is counted. The lines
// before it that are empty or hold only a CR are passed over, since they are no record and so no header.
@(private, cold, require_results)
header_cells :: #force_no_inline proc "contextless" (src: []u8, start: int, $S: Spec) -> int {
	n := 1
	i := start
	end := len(src)
	for i < end {
		if src[i] == '\n' {
			i += 1
			continue
		}
		if src[i] == '\r' && i + 1 < end && src[i + 1] == '\n' {
			i += 2
			continue
		}
		break
	}
	when S == .Csv {
		// A quote at a cell's first byte opens a quoted field, and a `""` inside one holds it open. A quote anywhere
		// else is a bare quote, a fault the pass reports or a byte of the cell.
		quoted := false
		first := true
		for i < end {
			c := src[i]
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
			switch c {
			case '\n':
				return n
			case '\r':
				if i + 1 < end && src[i + 1] == '\n' {
					return n
				}
			case ',':
				n += 1
			case '"':
				quoted = first
			}
			first = c == ','
			i += 1
		}
	} else {
		for i < end {
			c := src[i]
			if c == '\\' {
				i += 2
				continue
			}
			switch c {
			case '\n':
				return n
			case '\r':
				if i + 1 < end && src[i + 1] == '\n' {
					return n
				}
			case '\t':
				n += 1
			}
			i += 1
		}
	}
	return n
}

// One record read from its first byte, for the width fault's position: its cells, the first delimiter that opens a
// cell past `width` (-1 when there is none), and its line end and that line end's first byte. Quotes (CSV) and
// escapes (TSV) are followed as the pass follows them, so no delimiter inside a quoted field is counted.
@(private)
Record_Scan :: struct {
	cells:       int,
	fault_at:    int,
	line_end:    int,
	line_end_lo: int,
}

@(private, cold, require_results)
scan_record :: #force_no_inline proc "contextless" (src: []u8, start, width: int, $S: Spec) -> Record_Scan {
	s := Record_Scan{cells = 1, fault_at = -1}
	i := start
	end := len(src)
	when S == .Csv {
		quoted := false
		first := true
		for i < end {
			c := src[i]
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
			switch c {
			case '\n':
				s.line_end, s.line_end_lo = i, i
				if i > start && src[i - 1] == '\r' {
					s.line_end_lo = i - 1
				}
				return s
			case '\r':
				if i + 1 < end && src[i + 1] == '\n' {
					s.line_end, s.line_end_lo = i + 1, i
					return s
				}
			case ',':
				if s.cells == width && s.fault_at < 0 {
					s.fault_at = i
				}
				s.cells += 1
			case '"':
				quoted = first
			}
			first = c == ','
			i += 1
		}
	} else {
		for i < end {
			c := src[i]
			if c == '\\' {
				i += 2
				continue
			}
			switch c {
			case '\n':
				s.line_end, s.line_end_lo = i, i
				if i > start && src[i - 1] == '\r' {
					s.line_end_lo = i - 1
				}
				return s
			case '\r':
				if i + 1 < end && src[i + 1] == '\n' {
					s.line_end, s.line_end_lo = i + 1, i
					return s
				}
			case '\t':
				if s.cells == width && s.fault_at < 0 {
					s.fault_at = i
				}
				s.cells += 1
			}
			i += 1
		}
	}
	s.line_end, s.line_end_lo = end, end
	return s
}

// The first backslash in the block at `pos` that opens no escape, or -1. A backslash in bit 63 is left to the next
// block, through `esc`. The bytes a backslash may escape are `\t`, `\n`, `\r`, `\0` and `\\`.
// Out of line: inlined into the pass it drags its byte loop's branches into the block loop and spills the block's
// vectors, which costs the hot path of every block, not only the blocks that hold a backslash.
@(private, cold)
escape_fault :: #force_no_inline proc "contextless" (src: []u8, pos: int, esc: ^u64) -> int {
	end := min(pos + 64, len(src))
	i := pos
	if esc^ != 0 {
		if !escaped(src[pos]) {
			return pos - 1
		}
		i += 1
	}
	esc^ = 0
	for ; i < end; i += 1 {
		if src[i] != '\\' {
			continue
		}
		if i + 1 == pos + 64 {
			esc^ = 1
			break
		}
		if i + 1 == len(src) || !escaped(src[i + 1]) {
			return i
		}
		i += 1
	}
	return -1
}

@(private)
escaped :: #force_inline proc "contextless" (c: u8) -> bool {
	return c == 't' || c == 'n' || c == 'r' || c == '0' || c == '\\'
}

// The first malformed UTF-8 sequence of the block at `pos`, searching from the start of the sequence that holds `pos`
// but from no byte before `floor`, the walk's first: `Bad_Char` at its lead byte, or `Truncated` at `len(src)` when the text ends inside
// a sequence that is valid so far. -1 for none. A block whose mask of errors is set comes here, and so does the text's
// end when a sequence is left open there: a lead byte that no byte follows is judged only by its sequence's length.
@(private, cold)
utf8_fault :: #force_no_inline proc "contextless" (src: []u8, floor, pos: int) -> (fault: int, kind: core.Fault_Kind) {
	i := pos
	for i > max(pos - 3, floor) && src[i - 1] & 0xc0 == 0x80 {
		i -= 1
	}
	if i > floor && src[i - 1] >= 0xc0 {
		i -= 1
	}
	for i < min(pos + 64, len(src)) {
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
	return -1, .Bad_Char
}

// Whether the cell from `lo` ends at a separator of the block at `pos`, whose separators are `seps`, and is longer
// than `Token.n` holds. The CR of a CRLF is the line end's, not the cell's.
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
