package dsv

import "base:intrinsics"
import "stury:lib/base/kernel"
import "stury:lib/base/spell"
import "stury:lib/core/tape"

// The detail of a delimited text's fault, stored in `tape.Fault.detail`.
@(private)
Detail :: enum u8 {
	None,
	Too_Many, // `Bad_Width`: a record wider than the first, at the delimiter that starts its extra cell
	Too_Few, // `Bad_Width`: a record narrower than the first, at its line end
	Bare_Quote, // `Bad_Char`: a quote inside an unquoted CSV cell
	Invalid_Utf8, // `Bad_Char`: at the lead byte of an ill-formed sequence
	Lone_Cr, // `Bad_Char`: a CR with no LF after it
	After_Quote, // `Bad_Char`: a byte after a closing quote that is not a quote, the delimiter or a line end
	Open_Quote, // `Truncated`: at the opening quote of a quoted cell the text never closes
	Cut_Utf8, // `Truncated`: at the text's end, inside a UTF-8 sequence
}

// The `tape.Rules` of delimited text, one rule per `Detail` in its order, named "dsv" whichever spec read the text.
@(private, rodata)
RULES := tape.Rules{"dsv", {
	{},
	{"too_many_fields", "Record has more fields than the first record"},
	{"too_few_fields", "Record has fewer fields than the first record"},
	{"bare_quote", "Quote inside an unquoted field"},
	{"invalid_utf8", "Invalid UTF-8"},
	{"lone_cr", "Carriage return not before a line feed"},
	{"after_quote", "Character after a closing quote"},
	{"open_quote", "Unfinished quoted field"},
	{"cut_utf8", "Unfinished UTF-8 sequence"},
}}

// Where a block's bytes break a rule the masks cannot judge: a backslash that opens no escape, an ill-formed UTF-8 sequence,
// and a cell too wide for `Token.n`. The walk calls each only on a block whose masks show it is needed.

// Returns the index of the first backslash in the block at `pos` that opens no escape, or -1. `bs` has a bit at each
// backslash of the block, a comment line's bytes already cleared. `esc` is 1 when the block before ended in an odd run
// of backslashes, and it is set to that state for the next block. The bytes a backslash may escape are `t`, `n`, `r`,
// `0` and `\\`, read as one class mask.
@(private, cold)
escape_fault :: #force_inline proc "contextless" ($T: kernel.Tier, b: kernel.Block, bs: u64, pos: int, esc: ^u64) -> int {
	bad := kernel.escaped(bs, esc) & ~kernel.pack(kernel.has(kernel.classes(T, b, ESCAPE_LETTERS), 0x0f))
	if bad == 0 {
		return -1
	}
	return pos + int(intrinsics.count_trailing_zeros(bad)) - 1
}

// The bytes a TSV backslash may escape. A byte's class is the AND of row `lo` at its low nibble and row `hi` at its
// high nibble, so a bit is set only for a byte both rows name: bit 0 for `t` and `r`, bit 1 for `n`, bit 2 for `0` and
// bit 3 for `\\`. `has(.., 0x0f)` tests the four bits at once.
@(private, rodata)
ESCAPE_LETTERS := kernel.Nibble_Table {
	lo = {4, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 8, 0, 2, 0},
	hi = {0, 0, 0, 4, 0, 8, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0},
}

// Finds the first malformed UTF-8 sequence in the block at `pos`, starting from the lead byte of the sequence that
// holds `pos` but never before `floor`. Returns `Bad_Char` (`Invalid_Utf8`) at the sequence's lead byte, `Truncated`
// (`Cut_Utf8`) at `len(src)` when the text ends inside a sequence that is valid so far, or -1 when there is none.
@(private, cold)
utf8_fault :: #force_no_inline proc "contextless" (src: []u8, floor, pos: int) -> (fault: int, kind: tape.Fault_Kind, detail: Detail) {
	i := sequence_lead(raw_data(src), floor, pos)
	return span_fault(src, i, min(pos + 64, len(src)))
}

// Finds the first malformed UTF-8 sequence led in `[lo, hi)` of `src`, read to the text's end, and returns it as
// `utf8_fault` does.
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

// Finds the first ill-formed UTF-8 sequence of the block at `pos` whose lead is in a comment line, and returns it as
// `utf8_fault` does.
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

// Returns the leads of the ill-formed UTF-8 sequences that start in the block at `pos`, a bit each, each read up to
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

// Returns the lead byte of the first ill-formed UTF-8 sequence that starts in `[lo, hi)`, each read up to `end`, and
// its fault kind, `Truncated` when `end` cuts a sequence that is valid so far. Returns -1 when there is none.
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
	return u64(hi - lo) > u64(max(u32))
}
