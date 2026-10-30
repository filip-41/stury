package dsv

// The byte-at-a-time scans of the walk. The cell count of the header sizes the key buffer, the first malformed UTF-8
// sequence in a block, the first backslash that opens no escape, and whether a cell is too long for `Token.n`. The walk
// calls each only on a block whose masks say it is needed.

import "base:intrinsics"
import core "../core"
import kernel "../core/kernel"

// The first byte of the first record at or after `start`. Skips empty lines, lines holding only a CR LF, and lines
// whose first byte is `comment` when `comment` is not 0. A lone CR is not skipped. Returns `len(src)` when no record
// starts at or after `start`.
@(private)
record_start :: #force_inline proc "contextless" (src: []u8, start: int, comment: byte) -> int {
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

// The cell count of the text's first record at or after `start`, read by `scan_record` with width 0. The key buffer
// sized from it holds every cell the header makes, since the pass reads the same record the same way when it does not
// fault.
@(private, cold, require_results)
header_cells :: #force_no_inline proc "contextless" (src: []u8, start: int, $S: Spec, opts: Options) -> int {
	return scan_record(src, record_start(src, start, opts.comment), 0, S, delimiter_of(S, opts)).cells
}

// A record read from its first byte by `scan_record`. `cells` is its cell count, at least 1. `fault_at` is the index
// of the first delimiter that opens a cell past `width`, -1 when there is none, and width 0 counts cells only.
// `line_end` is the index of its LF, or `len(src)` when the text ends first. `line_end_lo` is the index of the CR in a
// CR LF, else the same as `line_end`.
@(private)
Record_Scan :: struct {
	cells:       int,
	fault_at:    int,
	line_end:    int,
	line_end_lo: int,
}

// Reads one record from `start`, with `delim` between cells. Quotes (CSV) and escapes (TSV) are read as the pass reads
// them, so a delimiter inside a quoted field does not count. A non-nil `ends` receives each cell's end byte in order,
// before the CR of a CR LF, for as many cells as it has room for.

@(private, cold, require_results)
scan_record :: #force_no_inline proc "contextless" (src: []u8, start, width: int, $S: Spec, delim: byte, ends: []int = nil) -> Record_Scan {
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
				hi := i
				if i > start && src[i - 1] == '\r' {
					hi = i - 1
				}
				if ends != nil && s.cells - 1 < len(ends) {
					ends[s.cells - 1] = hi
				}
				s.line_end, s.line_end_lo = i, hi
				return s
			case '\r':
				if i + 1 < end && src[i + 1] == '\n' {
					if ends != nil && s.cells - 1 < len(ends) {
						ends[s.cells - 1] = i
					}
					s.line_end, s.line_end_lo = i + 1, i
					return s
				}
			case delim:
				if ends != nil && s.cells - 1 < len(ends) {
					ends[s.cells - 1] = i
				}
				if s.cells == width && s.fault_at < 0 {
					s.fault_at = i
				}
				s.cells += 1
			case '"':
				quoted = first
			}
			first = c == delim
			i += 1
		}
	} else {
		for i < end {
			c := src[i]
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
				if ends != nil && s.cells - 1 < len(ends) {
					ends[s.cells - 1] = hi
				}
				s.line_end, s.line_end_lo = i, hi
				return s
			case '\r':
				if i + 1 < end && src[i + 1] == '\n' {
					if ends != nil && s.cells - 1 < len(ends) {
						ends[s.cells - 1] = i
					}
					s.line_end, s.line_end_lo = i + 1, i
					return s
				}
			case delim:
				if ends != nil && s.cells - 1 < len(ends) {
					ends[s.cells - 1] = i
				}
				if s.cells == width && s.fault_at < 0 {
					s.fault_at = i
				}
				s.cells += 1
			}
			i += 1
		}
	}
	if ends != nil && s.cells - 1 < len(ends) {
		ends[s.cells - 1] = end
	}
	s.line_end, s.line_end_lo = end, end
	return s
}

// The index of the first backslash in the block at `pos` that opens no escape, or -1. A backslash at the block's last
// byte is left to the next block through `esc`, and a carry in `esc` judges `src[pos]` and faults at `pos - 1` when it
// is not one of the five escapes. The bytes a backslash may escape are `t`, `n`, `r`, `0` and `\\`. Bytes in `comment`
// are skipped.
@(private, cold)
escape_fault :: #force_inline proc "contextless" (src: []u8, pos: int, comment: u64, esc: ^u64) -> int {
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
		// A backslash inside a comment line is text and opens no escape.
		if comment & (u64(1) << u64(i - pos)) != 0 {
			continue
		}
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

// The first malformed UTF-8 sequence in the block at `pos`, starting from the lead byte of the sequence that holds
// `pos` but never before `floor`. Returns `Bad_Char` at the sequence's lead byte, `Truncated` at `len(src)` when the
// text ends inside a sequence that is valid so far, or -1 when there is none. A block whose error mask is set comes
// here, and so does the text's end when a sequence is left open there, where the lead byte alone decides `Truncated`
// from its sequence's length.
@(private, cold)
utf8_fault :: #force_no_inline proc "contextless" (src: []u8, floor, pos: int) -> (fault: int, kind: core.Fault_Kind) {
	i := pos
	for i > max(pos - 3, floor) && src[i - 1] & 0xc0 == 0x80 {
		i -= 1
	}
	if i > floor && src[i - 1] >= 0xc0 {
		i -= 1
	}
	base := raw_data(src)
	end := base[len(src):]
	for i < min(pos + 64, len(src)) {
		if src[i] < 0x80 {
			i += 1
			continue
		}
		q, k := kernel.utf8_char(base[i:], end)
		if k != .None {
			if k == .Truncated {
				return len(src), .Truncated
			}
			return i, .Bad_Char
		}
		i = int(intrinsics.ptr_sub(q, base))
	}
	return -1, .Bad_Char
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
