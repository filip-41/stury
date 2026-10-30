// The walk of a delimited text, in passes of 64-byte blocks (pass.odin). A block is reduced to masks of its delimiter,
// LF, CR and quote bytes, `prefix_xor` of the quote mask marks the bytes inside quoted fields, and every later test is
// a bit test on a mask, for quote placement, a CR that no LF follows, the delimiters and LFs that are the text's rather
// than a cell's, and the delimiters between two LFs that count a record's cells for the width check. UTF-8 is judged a
// block at a time, and only for a block that is not all ASCII.
//
// A hooked read turns the same masks into positions (records.odin). The block's separators in order, each ending a cell
// or a record, give every token's span. `validate` compiles the pass with `$EMIT` false, which leaves out the position
// code and the key buffer. The bytes the masks cannot judge are read one at a time in text.odin, on the blocks whose
// masks say they are needed.
package dsv

import "base:runtime"
import core "../core"
import kernel "../core/kernel"

// The grammar a text follows, chosen at compile time. Each spec instantiates its own pass, so a CSV build holds no TSV
// code.
Spec :: enum u8 {
	Csv, // RFC 4180, a field whose first byte is a quote is quoted, and `""` inside it reads as `"`
	Tsv, // a quote is text, and a backslash escapes `t`, `n`, `r`, `0` or `\\`
	Plain, // no quotes and no escapes, a quote is text, and a cell cannot hold the delimiter, CR or LF
}

// Run-time options for a walk. The zero value reads a header, uses the spec's delimiter and sets no comment byte.
Options :: struct {
	no_header: bool, // the first record is data, not column names
	// The byte between cells, 0 for the spec's own, which is `,` for CSV and Plain and a tab for TSV. A walk whose
	// spec cannot read the byte returns `.Bad_Option` before reading the text.
	delimiter: byte,
	// A line whose first byte is this is no record, 0 for none. At any other byte, or inside a quoted field, it is
	// cell text. A byte the spec cannot read is refused as `.Bad_Option`, like the delimiter.
	comment:   byte,
	// The rules a text may break. Empty by default.
	tolerate:  bit_set[Tolerance; u8],
}

// A rule a caller lets a text break. The walk stops faulting on it. The tolerance shows in the value a cell decodes to
// or in the record width check.
Tolerance :: enum u8 {
	// Ill-formed UTF-8 in a cell is not a fault. Each maximal subpart of an ill-formed sequence decodes as U+FFFD.
	Invalid_Utf8,
	// A record with fewer cells than the first is not a fault, and its missing columns are absent. With no header a
	// record may hold any number of cells. With a header a cell past the header's last still faults.
	Ragged,
	// A quote inside an unquoted cell (CSV) is a cell byte, and the block's quotes pair up without it.
	Bare_Quote,
}

// The `core.Fault.detail` values a delimited text's faults use.
Detail :: enum u8 {
	None,
	Field_Count, // `Bad_Structure`, at the delimiter past the width of a wide record or the line end of a narrow one
	Bare_Quote, // `Bad_Char`, a quote inside an unquoted CSV cell
}

// A delimited text's rules, indexed by `Detail`. Every fault the walk returns points to this table.
@(rodata)
RULES := core.Rules{"dsv", {{}, {"field_count", "Record has the wrong number of fields"}, {"bare_quote", "Quote in an unquoted cell"}}}

// The delimiter a walk of `S` reads. `opts.delimiter` 0 selects the spec's own, `,` for CSV and Plain and a tab for
// TSV. The pass reads it once into a register and compares each block against it.
@(private)
delimiter_of :: #force_inline proc "contextless" ($S: Spec, opts: Options) -> byte {
	if opts.delimiter != 0 {
		return opts.delimiter
	}
	when S == .Tsv {
		return '\t'
	} else {
		return ','
	}
}

// Whether `S` can read the delimiter and comment byte in `opts`. A delimiter is refused when it is CR, LF, non-ASCII
// or, under CSV, a quote, and under TSV also a backslash or one of `t`, `n`, `r`, `0`. A comment byte is refused when
// it is CR, LF, the delimiter, non-ASCII or, under CSV, a quote, and under TSV also a backslash.
@(private)
options_ok :: #force_inline proc "contextless" ($S: Spec, opts: Options) -> bool {
	delim := delimiter_of(S, opts)
	if delim == '\r' || delim == '\n' || delim >= 0x80 {
		return false
	}
	when S == .Csv {
		if delim == '"' {
			return false
		}
	}
	when S == .Tsv {
		if delim == '\\' || delim == 't' || delim == 'n' || delim == 'r' || delim == '0' {
			return false
		}
	}
	if c := opts.comment; c != 0 {
		if c == '\r' || c == '\n' || c == delim || c >= 0x80 {
			return false
		}
		when S == .Csv {
			if c == '"' {
				return false
			}
		}
		when S == .Tsv {
			if c == '\\' {
				return false
			}
		}
	}
	return true
}

// The `.Bad_Option` fault at byte 0 for options `S` cannot read, or nil.
@(private)
option_fault :: #force_inline proc "contextless" ($S: Spec, opts: Options) -> Maybe(core.Fault) {
	if options_ok(S, opts) {
		return nil
	}
	return core.Fault{at = 0, rules = &RULES, kind = .Bad_Option}
}

// Reads a text of spec `S` from `lo`, past one BOM at its first byte, with hook `on`. Returns `hi`, one past the last
// byte read, or the fault. A BOM at a later byte is a cell byte. A `lo` past `len(src)` reads an empty text. When the
// hook stops the walk, `hi` is one past the token it stopped on and the text past it is unread, so `hi` is no document
// boundary.
// The tokens are an `Array` for the text, then for each record a `Map` (an `Array` when `opts.no_header`), each cell as
// its column's header cell (`Plain`, role `Key`) and the cell itself (`Plain`, role `Value`), and an `End` over the
// record's line end, 1 byte for LF and 2 for CR LF. The text's `End` is at its end, with `n` 0. A cell's span keeps its
// quotes and leaves out the CR of a CR LF. The header makes no tokens, and an empty line or a line holding only a CR is
// no record.
// A caller that holds a buffer of one token per header cell passes it as `keys`, and the walk writes the header's cells
// there and allocates none. With nil, the walk allocates the buffer.
walk :: proc "contextless" (src: []u8, lo: u64, $S: Spec, opts: Options, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), keys: []core.Token = nil) -> (hi: u64, fault: Maybe(core.Fault)) {
	if f, bad := option_fault(S, opts).?; bad {
		return 0, f
	}
	// With no `keys` buffer and a header, allocates one 16-byte token per header cell for the walk to write the
	// header's cells into. Data cells read their column's key from it by index. The buffer is scratch freed before
	// the walk returns, so it comes from the default heap, which keeps the walk callable from a hook. If the
	// allocation fails the walk returns `No_Memory` before reading a byte. `validate` allocates nothing.
	context = runtime.default_context()
	from := min(lo, u64(len(src)))
	key_buf := keys
	owned: []core.Token
	if key_buf == nil && !opts.no_header {
		err: runtime.Allocator_Error
		key_buf, err = make([]core.Token, header_cells(src, int(core.text_start(src, from)), S, opts))
		if err != nil {
			return 0, core.fault_of(core.fault_at(0, .No_Memory), &RULES)
		}
		owned = key_buf
	}
	defer delete(owned)
	r := run(src, from, S, opts, h, regs, on, true, key_buf)
	return r >> 16, core.fault_of(r, &RULES)
}

// The walk's verdict on `src` for spec `S`, with no hook and after one leading BOM. Whether the first record is a
// header changes the verdict only under `.Ragged`.
validate :: proc "contextless" (src: []u8, $S: Spec, opts := Options{}) -> Maybe(core.Fault) {
	if f, bad := option_fault(S, opts).?; bad {
		return f
	}
	return core.fault_of(judge(src, 0, S, opts), &RULES)
}

// The walk's verdict on the text from `lo`, with no hook. A cell can exceed `Token.n` only in a text longer than
// `max(u32)` bytes, and only the hooked lane checks cell width, so such a text runs with `$EMIT` true and
// `core.no_hook`. A shorter text runs with `$EMIT` false. `field_count_fault` then places a width fault.
@(private)
judge :: proc "contextless" (src: []u8, lo: u64, $S: Spec, opts: Options) -> u64 {
	h: core.No_Hooks
	regs: core.Hook_Regs
	r: u64
	if u64(len(src)) - lo > u64(max(u32)) {
		r = run(src, lo, S, opts, &h, &regs, core.no_hook, true, nil)
	} else {
		r = run(src, lo, S, opts, &h, &regs, core.no_hook, false, nil)
	}
	return field_count_fault(src, lo, S, opts, r)
}

// The position of a width fault is the delimiter that opens the cell past the width in a wide record, or the line end's
// first byte in a narrow one. A width fault at or before a byte fault wins. A walk with no fault returns `r` unchanged,
// and a faulting one rescans the records with `scan_record`.
@(private, cold)
field_count_fault :: #force_no_inline proc "contextless" (src: []u8, lo: u64, $S: Spec, opts: Options, r: u64) -> u64 {
	kind := core.Fault_Kind(r & 0xff)
	if kind == .None {
		return r
	}
	at, detail := r >> 16, u8(r >> 8)
	end := len(src)
	pos := record_start(src, int(core.text_start(src, min(lo, u64(end)))), opts.comment)
	if pos >= end {
		return r
	}
	delim := delimiter_of(S, opts)
	width := header_cells(src, pos, S, opts) if !opts.no_header else scan_record(src, pos, 0, S, delim).cells
	for pos < end {
		if at < u64(pos) {
			return r
		}
		s := scan_record(src, pos, width, S, delim)
		if at <= u64(s.line_end) {
			if s.fault_at >= 0 {
				if detail == u8(Detail.Field_Count) || u64(s.fault_at) < at {
					return core.fault_at(u64(s.fault_at), .Bad_Structure, u8(Detail.Field_Count))
				}
			} else if detail == u8(Detail.Field_Count) && s.cells < width {
				return core.fault_at(u64(s.line_end_lo), .Bad_Structure, u8(Detail.Field_Count))
			}
			return r
		}
		pos = record_start(src, s.line_end + 1, opts.comment)
	}
	return r
}

// Runs the pass for the CPU's vector tier (`kernel.tier()`), or for the tier `-define:WALK_TIER=<n>` forces in a test
// build.
@(private)
run :: #force_inline proc "contextless" (src: []u8, lo: u64, $S: Spec, opts: Options, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), $EMIT: bool, keys: []core.Token) -> u64 {
	when ODIN_ARCH == .amd64 {
		// A text with no comment byte runs the pass instance with `$COMMENTS` false, which holds no comment code.
		if opts.comment != 0 {
			switch kernel.tier() {
			case .V4:
				return pass_v4(src, lo, S, opts, h, regs, on, EMIT, true, keys)
			case .V3:
				return pass_v3(src, lo, S, opts, h, regs, on, EMIT, true, keys)
			case .V2:
				return pass_v2(src, lo, S, opts, h, regs, on, EMIT, true, keys)
			}
			unreachable()
		}
		switch kernel.tier() {
		case .V4:
			return pass_v4(src, lo, S, opts, h, regs, on, EMIT, false, keys)
		case .V3:
			return pass_v3(src, lo, S, opts, h, regs, on, EMIT, false, keys)
		case .V2:
			return pass_v2(src, lo, S, opts, h, regs, on, EMIT, false, keys)
		}
		unreachable()
	} else {
		if opts.comment != 0 {
			return pass_base(src, lo, S, opts, h, regs, on, EMIT, true, keys)
		}
		return pass_base(src, lo, S, opts, h, regs, on, EMIT, false, keys)
	}
}

// A pass procedure per vector tier, each with its tier's target features and its own copy of the loop, as kernel.md
// asks. A loop that calls a kernel generic over `$T` is instantiated per tier, so a v4 build holds v4 compares and a v2
// build holds SSE ones. `#force_no_inline` keeps each a separate procedure.
when ODIN_ARCH == .amd64 {
	@(private, enable_target_feature = kernel.FEATURES[.V2])
	pass_v2 :: #force_no_inline proc "contextless" (src: []u8, lo: u64, $S: Spec, opts: Options, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), $EMIT: bool, $COMMENTS: bool, keys: []core.Token) -> u64 {
		return pass(.V2, S, EMIT, COMMENTS, src, lo, opts, h, regs, on, keys)
	}
	@(private, enable_target_feature = kernel.FEATURES[.V3])
	pass_v3 :: #force_no_inline proc "contextless" (src: []u8, lo: u64, $S: Spec, opts: Options, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), $EMIT: bool, $COMMENTS: bool, keys: []core.Token) -> u64 {
		return pass(.V3, S, EMIT, COMMENTS, src, lo, opts, h, regs, on, keys)
	}
	@(private, enable_target_feature = kernel.FEATURES[.V4])
	pass_v4 :: #force_no_inline proc "contextless" (src: []u8, lo: u64, $S: Spec, opts: Options, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), $EMIT: bool, $COMMENTS: bool, keys: []core.Token) -> u64 {
		return pass(.V4, S, EMIT, COMMENTS, src, lo, opts, h, regs, on, keys)
	}
} else {
	@(private)
	pass_base :: #force_no_inline proc "contextless" (src: []u8, lo: u64, $S: Spec, opts: Options, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), $EMIT: bool, $COMMENTS: bool, keys: []core.Token) -> u64 {
		return pass(.Base, S, EMIT, COMMENTS, src, lo, opts, h, regs, on, keys)
	}
}

// Passes a token to the hook and stores the returned registers in `hs`. The token is built here from the call's words,
// so a call site gives no `Token` an address or a second copy.
@(private)
emit :: #force_inline proc "contextless" (h: ^$H, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), hs: ^core.Hook_Regs, lo: u64, n: u32, kind: core.Kind, role: core.Role, spelling: u16) -> core.Action {
	a: core.Action
	hs^, a = on(h, hs^, core.Token{lo, n, kind, role, spelling})
	return a
}

// The walk's result when the hook stopped on the token at `lo` of `n` bytes. Its position is `lo + n`, its kind 0, and
// its detail `STOPPED`.
@(private)
stopped :: #force_inline proc "contextless" (lo: u64, n: u32) -> u64 {
	return core.fault_at(lo + u64(n), .None, core.STOPPED)
}
