package dsv

// The byte-at-a-time scans of the walk. The cell count of the header sizes the key buffer, the first malformed UTF-8
// sequence in a block or a span, the first backslash that opens no escape, and whether a cell is too long for
// `Token.n`. The walk calls each only on a block whose masks say it is needed.

import "base:intrinsics"
import spell "../core/spell"
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
	return scan_record(src, record_start(src, start, opts.comment), 0, S, spec_delimiter(S, opts.delimiter)).cells
}

// The header record of the text `src` read as `as` reads it: its first byte, and the byte past its line end. Both are
// `len(src)` when the text holds no record. The comment lines before it lie before `lo`, those after it from `hi`.
header_span :: proc(src: []u8, as: core.As) -> (lo, hi: int) {
	opts := options_of(as)
	lo = record_start(src, int(core.text_start(src, 0)), opts.comment)
	if lo >= len(src) {
		return len(src), len(src)
	}
	end: int
	switch Spec(as.spec) {
	case .Csv:   end = scan_record(src, lo, 0, .Csv, spec_delimiter(.Csv, opts.delimiter)).line_end
	case .Tsv:   end = scan_record(src, lo, 0, .Tsv, spec_delimiter(.Tsv, opts.delimiter)).line_end
	case .Plain: end = scan_record(src, lo, 0, .Plain, spec_delimiter(.Plain, opts.delimiter)).line_end
	}
	return lo, min(end + 1, len(src))
}

// A record read from its first byte by `scan_record`. `cells` is its cell count, at least 1. `fault_at` is the index
// of the first delimiter that opens a cell past `width`, -1 when there is none, and width 0 counts cells only.
// `line_end` is the index of its LF, or `len(src)` when the text ends first. `line_end_lo` is the index of the CR in a
// CR LF, else the same as `line_end`. `quote` is the index of the last quote that opened a quoted field.
@(private)
Record_Scan :: struct {
	cells:       int,
	fault_at:    int,
	line_end:    int,
	line_end_lo: int,
	quote:       int,
}

// Reads one record from `start`, with `delim` between cells. Quotes (CSV) and escapes (TSV) are read as the pass reads
// them, so a delimiter inside a quoted field does not count.
@(private, cold, require_results)
scan_record :: #force_no_inline proc "contextless" (src: []u8, start, width: int, $S: Spec, delim: byte) -> Record_Scan {
	s := Record_Scan{cells = 1, fault_at = -1}
	i := start
	end := len(src)
	quoted, first := false, true
	when S != .Csv {
		// The quoted-field state is CSV's, and this build has no use for it.
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
// `pos` but never before `floor`. Returns `Bad_Char` (`Invalid_Utf8`) at the sequence's lead byte, `Truncated` (`Cut_Utf8`)
// at `len(src)` when the text ends inside a sequence that is valid so far, or -1 when there is none. A block whose error mask is set comes
// here, and so does the text's end when a sequence is left open there, where the lead byte alone decides `Truncated`
// from its sequence's length.
@(private, cold)
utf8_fault :: #force_no_inline proc "contextless" (src: []u8, floor, pos: int) -> (fault: int, kind: core.Fault_Kind, detail: Detail) {
	i := sequence_lead(raw_data(src), floor, pos)
	return span_fault(src, i, min(pos + 64, len(src)))
}

// The first malformed UTF-8 sequence led in `[lo, hi)` of `src`, read to the text's end, as `utf8_fault` returns it.
@(private, cold)
span_fault :: proc "contextless" (src: []u8, lo, hi: int) -> (fault: int, kind: core.Fault_Kind, detail: Detail) {
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
comment_utf8_fault :: #force_no_inline proc "contextless" (src: []u8, pos: int, ill: u64, back: int, comments: u64) -> (fault: int, kind: core.Fault_Kind, detail: Detail) {
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
// before `floor`, or -1. A lead is a byte that starts no well-formed character, so a sequence's every maximal subpart and its
// stray continuations each have one, and a span that holds an ill-formed sequence holds a lead.
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
first_ill_formed :: #force_inline proc "contextless" (base: [^]u8, lo, hi, end: int) -> (at: int, kind: core.Fault_Kind) {
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
