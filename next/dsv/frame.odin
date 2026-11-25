package dsv

import "base:intrinsics"
import "stury:lib/base/kernel"
import "stury:lib/base/spell"

// The framing of a delimited text, a byte at a time: where its first byte is past a byte order mark, where each record
// starts past the empty and comment lines, and where each ends outside a quoted cell. A walk reads the header's cell
// count and a fault's record from it, and the records and the text in pieces frame their records with it.

// Returns the first byte of `src` at or after `lo`, past a byte order mark at the text's first byte. A mark at a later
// byte is a cell byte.
@(private)
text_start :: #force_inline proc "contextless" (src: []u8, lo: u64) -> u64 {
	if lo == 0 {
		return u64(spell.bom_length(src))
	}
	return min(lo, u64(len(src)))
}

// Returns the first byte of the first record at or after `start`. Skips empty lines, lines holding only a CR LF, and
// lines whose first byte is `comment` when `comment` is not 0. A lone CR is not skipped. Returns `len(src)` when no
// record starts at or after `start`.
@(private)
record_start :: #force_inline proc "contextless" (src: []u8, start: int, comment: u8) -> int {
	at := Frame_At{i = start}
	record_start_on(src, &at, comment, false)
	return at.i
}

// Where a framing of a text in pieces stopped at a window's end: the next byte, and what the bytes before it left open.
// The next window goes on from it and reads no byte twice.
@(private)
Frame_At :: struct {
	i:       int,
	comment: bool, // inside a comment line
	quoted:  bool, // inside a quoted cell
	first:   bool, // at a cell's first byte
	pending: int, // the bytes before `i` of a skipped line, whose last sequence the window cut, not yet judged
}

// `record_start` from `at`. Leaves `at` at the record's first byte and returns true, or leaves it at the text's end and
// returns false. With `MORE` the text goes on past `src`, and a byte whose reading needs the next is left for the next
// window: a CR at the end, which may open a CR LF, and the rest of a comment line the end cut, which `at.comment`
// keeps.
@(private)
record_start_on :: #force_inline proc "contextless" (src: []u8, at: ^Frame_At, comment: u8, $MORE: bool) -> bool {
	i := at.i
	n := len(src)
	if at.comment {
		for i < n && src[i] != '\n' {
			i += 1
		}
		if i == n {
			at.i = i
			return false
		}
		i += 1
		at.comment = false
	}
	for i < n {
		if src[i] == '\n' {
			i += 1
			continue
		}
		if src[i] == '\r' {
			if i + 1 < n {
				if src[i + 1] == '\n' {
					i += 2
					continue
				}
			} else if MORE {
				at.i = i
				return false
			}
		}
		if comment != 0 && src[i] == comment {
			for i < n && src[i] != '\n' {
				i += 1
			}
			if i < n {
				i += 1
			} else if MORE {
				at.i, at.comment = i, true
				return false
			}
			continue
		}
		break
	}
	at.i = i
	return i < n
}

// Returns the cell count of the text's first record, 0 for a text with none. A key buffer of this size holds every cell
// the header makes, since the pass reads the same record the same way when it does not fault.
@(private, cold, require_results)
header_cells :: #force_no_inline proc "contextless" (src: []u8, $S: Spec, delim, comment: u8) -> int {
	at := record_start(src, int(text_start(src, 0)), comment)
	if at >= len(src) {
		return 0
	}
	return scan_record(src, at, 0, S, delim).cells
}

// A record read from its first byte by `scan_record`. `cells` is its cell count, at least 1. `wide_at` is the index
// of the first delimiter that opens a cell past `width`, -1 when there is none, and width 0 counts cells only.
// `line_end` is the index of its LF, or `len(src)` when the text ends first. `line_end_lo` is the index of the CR in a
// CR LF, else the same as `line_end`. `quote` is the index of the last quote that opened a quoted cell. With
// `CLIP`, a text that ends inside that cell ends the record at the line end past `quote`, as `end_at_quote_line` does, so
// the records go on at the next line. Without it the record runs to the text's end, as the pass reads it.
@(private)
Record_Scan :: struct {
	cells:       int,
	wide_at:     int,
	line_end:    int,
	line_end_lo: int,
	quote:       int,
}

@(private, cold, require_results)
scan_record_with :: #force_no_inline proc "contextless" (src: []u8, start, width: int, $S: Spec, delim: u8, $CLIP: bool) -> Record_Scan {
	s := Record_Scan{cells = 1, wide_at = -1}
	at := Frame_At{i = start, first = true}
	scan_record_on(src, start, width, S, delim, &s, &at, false, CLIP)
	return s
}

// Reads a record from `start`, with `delim` between cells. Quotes (CSV) and escapes (TSV) are read as the pass reads
// them, so a delimiter inside a quoted cell does not count.
@(private, cold, require_results)
scan_record :: #force_inline proc "contextless" (src: []u8, start, width: int, $S: Spec, delim: u8) -> Record_Scan {
	return scan_record_with(src, start, width, S, delim, false)
}

// `scan_record` for the records, whose record ends at the line of its unclosed quote.
@(private, cold, require_results)
scan_record_clipped :: #force_inline proc "contextless" (src: []u8, start, width: int, $S: Spec, delim: u8) -> Record_Scan {
	return scan_record_with(src, start, width, S, delim, true)
}

// `scan_record` of the record at `start` from `at`. Goes on filling `s` and returns true once the record has ended.
// With `MORE` the text goes on past `src`, and at its end `at` keeps where the scan stopped, before a byte whose
// reading needs the next: a quote inside a quoted cell, which may be doubled, a CR, which may open a CR LF, and a TSV
// backslash.
@(private)
scan_record_on :: #force_inline proc "contextless" (src: []u8, start, width: int, $S: Spec, delim: u8, s: ^Record_Scan, at: ^Frame_At, $MORE: bool, $CLIP: bool) -> bool {
	i := at.i
	end := len(src)
	quoted, first := at.quoted, at.first
	when S != .Csv {
		_, _ = quoted, first
	}
	scan: for i < end {
		c := src[i]
		when S == .Csv {
			if quoted {
				if c == '"' {
					if i + 1 < end {
						if src[i + 1] == '"' {
							i += 2
							continue
						}
					} else if MORE {
						break scan
					}
					quoted = false
				}
				i += 1
				continue
			}
		}
		when S == .Tsv {
			if c == '\\' {
				when MORE {
					if i + 1 == end {
						break scan
					}
				}
				// A backslash before a line end escapes nothing, and its text faults there.
				i += 1 if i + 1 < end && src[i + 1] == '\n' else 2
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
			at.i = i
			return true
		case '\r':
			if i + 1 < end {
				if src[i + 1] == '\n' {
					s.line_end, s.line_end_lo = i + 1, i
					at.i = i + 1
					return true
				}
			} else if MORE {
				break scan
			}
		case delim:
			if s.cells == width && s.wide_at < 0 {
				s.wide_at = i
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
	when MORE {
		at.i, at.quoted, at.first = i, quoted, first
		return false
	} else {
		s.line_end, s.line_end_lo = end, end
		when S == .Csv && CLIP {
			if quoted {
				end_at_quote_line(src, s)
			}
		}
		at.i = end
		return true
	}
}

// Ends the record `s` of `src` whose last quote the text never closes at the line end past that quote, so the records
// go on at the next line. A text with no line end past it leaves the record to run to the text's end.
@(private)
end_at_quote_line :: #force_inline proc "contextless" (src: []u8, s: ^Record_Scan) {
	// A byte loop, so that `scan_record_on`, which calls this, stays a leaf and a record pays no frame for it.
	i := s.quote
	for i < len(src) && src[i] != '\n' {
		i += 1
	}
	if i == len(src) {
		return
	}
	s.line_end = i
	s.line_end_lo = i - int(i > 0 && src[i - 1] == '\r')
}

// The index of the LF that ends the record at `start`, read 64 bytes at a time as the pass reads them, or -1 when the
// text holds a byte this reader leaves to `scan_record`: a quote that opens no cell, or no LF before the text's end.
@(private)
line_end_in_blocks :: #force_inline proc "contextless" (src: []u8, start: int, $S: Spec, delim: u8, $T: kernel.Tier) -> int #no_bounds_check {
	n := len(src)
	in_quote, closed: u64
	begun := u64(1)
	when S != .Csv {
		_, _, _ = in_quote, closed, begun
	}
	for pos := start; pos < n; pos += 64 {
		b := kernel.load_block(src, pos)
		when S == .Csv {
			m := kernel.pack_n([3]kernel.Block{kernel.eq(b, '"'), kernel.eq(b, delim), kernel.eq(b, '\n')})
			q, d, nl := m[0], m[1], m[2]
			instr := kernel.prefix_xor(T, q) ~ in_quote
			closing := q & ~instr
			seps := (d | nl) & ~instr
			bare := q & instr & ~(seps << 1 | begun | closing << 1 | closed)
			lfs := nl & ~instr
			cut := lfs & -lfs
			if cut == 0 {
				cut = ~u64(0)
			} else {
				cut = cut | (cut - 1)
			}
			if bare & cut != 0 {
				return -1
			}
			if lfs != 0 {
				return pos + int(intrinsics.count_trailing_zeros(lfs))
			}
			in_quote = u64(0) - (instr >> 63)
			begun = seps >> 63
			closed = closing >> 63
		} else {
			if lfs := kernel.pack(kernel.eq(b, '\n')); lfs != 0 {
				return pos + int(intrinsics.count_trailing_zeros(lfs))
			}
		}
	}
	return -1
}

@(private, enable_target_feature = PASS_FLOOR_FEATURES)
line_end_floor :: #force_no_inline proc "contextless" (src: []u8, start: int, $S: Spec, delim: u8) -> int {
	return line_end_in_blocks(src, start, S, delim, PASS_FLOOR)
}

// The `scan_record` result for a record's line end alone: its LF and the CR before it. Reads in blocks where it can.
@(private)
frame_line :: #force_inline proc "contextless" (src: []u8, start: int, $S: Spec, delim: u8) -> (line_end, line_end_lo: int) {
	at := -1
	when ODIN_ARCH == .amd64 {
		if kernel.tier() == .V3 {
			at = line_end_v3(src, start, S, delim)
		} else {
			at = line_end_floor(src, start, S, delim)
		}
	} else {
		at = line_end_floor(src, start, S, delim)
	}
	if at < 0 || at >= len(src) {
		s := scan_record_clipped(src, start, 0, S, delim)
		return s.line_end, s.line_end_lo
	}
	if at > start && src[at - 1] == '\r' {
		return at, at - 1
	}
	return at, at
}
